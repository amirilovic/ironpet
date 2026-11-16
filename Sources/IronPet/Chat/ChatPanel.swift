import AppKit
import SwiftUI

/// Borderless floating chat panel. The app must be frontmost while it is open: dictation tools
/// like Wispr Flow look up the focused text field of the frontmost app via Accessibility.
final class ChatPanel: NSPanel {
    var onClose: (() -> Void)?
    private static let sizeKey = "chatPanelSize"
    static let minimumSize = CGSize(width: 360, height: 320)

    private let session: ChatSession

    init(session: ChatSession) {
        self.session = session
        // A titled window with a hidden title bar: native resizing from every edge and corner.
        super.init(contentRect: CGRect(x: 0, y: 0, width: 440, height: 560),
                   styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        hideStandardWindowButtons()
        backgroundColor = .windowBackgroundColor
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        minSize = Self.minimumSize
        let host = NSHostingController(rootView: ChatView(session: session, close: { [weak self] in self?.close() }))
        host.sizingOptions = []
        contentViewController = host
        setContentSize(Self.savedSize)
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: self, queue: .main) { [weak self] _ in
            guard let size = self?.frame.size else { return }
            UserDefaults.standard.set(NSStringFromSize(size), forKey: Self.sizeKey)
        }
    }

    private static var savedSize: CGSize {
        guard let saved = UserDefaults.standard.string(forKey: sizeKey) else { return CGSize(width: 440, height: 560) }
        let size = NSSizeFromString(saved)
        return CGSize(width: max(size.width, minimumSize.width), height: max(size.height, minimumSize.height))
    }

    override var canBecomeKey: Bool { true }

    /// AppKit re-shows the buttons on layout, key and appearance changes. Hide them again each pass.
    override func update() {
        super.update()
        hideStandardWindowButtons()
    }

    /// Intercepts ⌘V only when the pasteboard holds an image and no text; text paste stays with the field.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "v", ImageIntake.decide(.general) != .text {
            let saved = ImageIntake.importPaste(.general)
            if !saved.isEmpty {
                saved.forEach(session.attach)
                return true
            }
        }
        if flags == .command, event.charactersIgnoringModifiers == "f", isKeyWindow {
            revealFind()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Opens the find bar and moves focus into its field. Cmd-F calls this; tests call it directly because a
    /// test process has no key window.
    func revealFind() {
        session.findOpen = true
        session.findFocusTick += 1
        focusFind()
    }

    /// Esc stops a running turn first, like the stop button; only an idle chat closes.
    override func cancelOperation(_ sender: Any?) {
        if session.dismissSlash() { return }
        if session.findOpen {
            dismissFind()
            return
        }
        if session.isRunning { session.stop() } else { close() }
    }

    override func close() {
        super.close()
        onClose?()
    }

    /// Places the panel above the pet, or below it when there is no room.
    func show(near anchor: CGRect) {
        let size = frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 6)
        if origin.y + size.height > screen.maxY { origin.y = anchor.minY - size.height - 6 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        setFrame(CGRect(origin: origin, size: size), display: true)
        makeKeyAndOrderFront(nil)
        focusInput()
    }

    /// Closes the find bar and returns focus to the composer. Esc and the bar's close button both come here.
    /// The bar leaves the view tree on the next update, and that can hand focus to the window, so retry
    /// until the composer holds it.
    func dismissFind() {
        session.findOpen = false
        refocusInput()
    }

    private var composerHasFocus: Bool {
        guard let field = contentView.flatMap(Self.firstTextInput), let responder = firstResponder else { return false }
        return responder === field || (field as? NSTextField)?.currentEditor() === responder
    }

    private func refocusInput(attempt: Int = 0) {
        guard isKeyWindow || attempt == 0 else { return }
        if !composerHasFocus { focusInput() }
        guard attempt < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, !self.session.findOpen else { return }
            self.refocusInput(attempt: attempt + 1)
        }
    }

    /// SwiftUI's FocusState only applies on first appearance; the panel is reused, so focus the text view directly.
    func focusInput() {
        guard let field = contentView.flatMap(Self.firstTextInput) else { return }
        makeFirstResponder(field)
    }

    /// Moves focus to the find field and selects its text. The bar enters the view tree on the next SwiftUI update,
    /// so retry briefly until the field exists. `FocusState` alone loses to the composer, which keeps first responder.
    private func focusFind(attempt: Int = 0) {
        // Esc during the retries closes the bar; do not pull focus back to a field that is going away.
        guard session.findOpen else { return }
        if let field = contentView.flatMap({ Self.findField(in: $0) }) {
            makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        } else if attempt < 30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.focusFind(attempt: attempt + 1) }
        }
    }

    private static func findField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, !field.isHidden, field.placeholderString == FindBar.placeholder { return field }
        for sub in view.subviews { if let found = findField(in: sub) { return found } }
        return nil
    }

    private static func firstTextInput(in view: NSView) -> NSView? {
        if let text = view as? NSTextView, text.isEditable, !text.isFieldEditor { return text }
        if let field = view as? NSTextField, field.isEditable, field.placeholderString != FindBar.placeholder { return field }
        for sub in view.subviews { if let found = firstTextInput(in: sub) { return found } }
        return nil
    }
}
