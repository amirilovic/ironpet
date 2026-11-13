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
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
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
        return super.performKeyEquivalent(with: event)
    }

    /// Esc stops a running turn first, like the stop button; only an idle chat closes.
    override func cancelOperation(_ sender: Any?) {
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

    /// SwiftUI's FocusState only applies on first appearance; the panel is reused, so focus the text view directly.
    func focusInput() {
        guard let field = contentView.flatMap(Self.firstTextInput) else { return }
        makeFirstResponder(field)
    }

    private static func firstTextInput(in view: NSView) -> NSView? {
        if let text = view as? NSTextView, text.isEditable { return text }
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let found = firstTextInput(in: sub) { return found } }
        return nil
    }
}
