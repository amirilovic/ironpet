import AppKit
import SwiftUI

/// The one ironpet window: chat, agents, alerts, tasks, transcripts, actions and automations in a floating
/// panel with a sidebar, opened next to the pet. On Chat it behaves like a chat window: it stays open when you switch
/// apps, Esc stops a running turn first, ⌘V pastes an image and ⌘F finds. On the other sections it closes on Esc,
/// when ironpet stops being the active app, or when the meeting panel takes over; its own sheets, popovers, alerts
/// and open panels keep it open.
final class IronPetPanel: NSPanel {
    static let title = "ironpet"
    static let minimumSize = CGSize(width: 720, height: 480)
    private static let sizeKey = "ironpetWindowSize"
    var onVisibilityChange: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    /// Whether `window.autoHide` is on. Read each time ironpet loses focus, so a change applies without a restart.
    var autoHideEnabled: () -> Bool = { false }
    /// ironpet's own window or region capture is running.
    var isCapturing: () -> Bool = { false }
    /// The window was hidden because another app became active, and comes back when ironpet is activated again.
    private(set) var autoHidden = false
    private let model: IronPetWindowModel
    private let session: ChatViewModel?
    /// Whether the window has a Voice page, so ⌘N counts its row.
    var hasVoice = false
    private var observers: [NSObjectProtocol] = []

    init<Content: View>(model: IronPetWindowModel, session: ChatViewModel?, content: Content) {
        self.model = model
        self.session = session
        // A titled window with a transparent, title-less bar: native resizing from every edge and corner, and the
        // standard close, minimize and zoom buttons over the sidebar.
        super.init(contentRect: CGRect(origin: .zero, size: Self.savedSize),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        title = Self.title
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .windowBackgroundColor
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        hasShadow = true
        minSize = Self.minimumSize
        let host = NSHostingController(rootView: content.ignoresSafeArea())
        host.sizingOptions = []
        contentViewController = host
        setContentSize(Self.savedSize)
        centerWindowButtons()
        let center = NotificationCenter.default
        observers = [
            // AppKit puts the title bar back to its normal height on resize and on becoming key.
            center.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.centerWindowButtons() } // queue: .main
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.centerWindowButtons() } // queue: .main
            },
            // Minimizing hides the window without closing it; tell the pet, as close() does.
            center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onVisibilityChange?(false) }
            },
            center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onVisibilityChange?(true) }
            },
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let size = self?.frame.size else { return }
                    UserDefaults.standard.set(NSStringFromSize(size), forKey: Self.sizeKey)
                }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appResignedActive() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appBecameActive() }
            },
        ]
    }

    /// Another app became active. With auto-hide on the window hides on every section; otherwise it closes off Chat only.
    private func appResignedActive() {
        guard isVisible else { return }
        if autoHideEnabled() {
            if Self.shouldAutoHide(self, dragging: session?.fileDragActive == true, capturing: isCapturing(),
                                   voiceBusy: session?.voiceBusy == true) { autoHide() }
            return
        }
        if !onChat { close() }
    }

    /// Hides the window like Esc does, keeping its section, chat, draft and frame, and remembers to bring it back.
    private func autoHide() {
        close()
        autoHidden = true
    }

    /// ironpet is the active app again: bring back a window that auto-hide hid, where it was. A window closed with
    /// Esc or a close button is not brought back.
    private func appBecameActive() {
        guard autoHidden, !isCapturing() else { return }
        show(near: .zero)
    }

    /// Whether losing focus to another app should hide the window now. A sheet or modal panel of ironpet's own
    /// (alert, open panel, approval), a file drag onto the chat, a running capture and a busy voice controller
    /// (recording, or transcribing until the text lands in the composer) keep it open.
    static func shouldAutoHide(_ panel: NSWindow, dragging: Bool, capturing: Bool, voiceBusy: Bool = false) -> Bool {
        if dragging || capturing || voiceBusy { return false }
        if panel.attachedSheet != nil || NSApp.modalWindow != nil { return false }
        return !(panel.childWindows ?? []).contains { $0.isVisible }
    }

    /// Resizes the title bar so the close, minimize and zoom buttons sit in the middle of the section headers. AppKit
    /// keeps the buttons a fixed distance above the bottom of the bar, so the bar is as tall as the header's half
    /// height plus that distance. The buttons' own frames are not touched.
    func centerWindowButtons() {
        guard let button = standardWindowButton(.closeButton), let bar = button.superview?.superview,
              let host = bar.superview else { return }
        let height = PageHeaderMetrics.height / 2 + button.convert(button.bounds, to: bar).midY
        let frame = CGRect(x: bar.frame.minX, y: host.bounds.height - height, width: bar.frame.width, height: height)
        if bar.frame != frame { bar.frame = frame }
    }

    private static var savedSize: CGSize {
        guard let saved = UserDefaults.standard.string(forKey: sizeKey) else { return CGSize(width: 820, height: 600) }
        let size = NSSizeFromString(saved)
        return CGSize(width: max(size.width, minimumSize.width), height: max(size.height, minimumSize.height))
    }

    /// The rows the sidebar shows; ⌘1 to ⌘9 index into this list.
    private var sidebarSections: [IronPetSection] {
        IronPetSection.shown(chat: session != nil, voice: hasVoice, transcripts: true, automations: true, today: model.todayShown)
    }

    private var onChat: Bool { session != nil && model.section == .chat }

    override var canBecomeKey: Bool { true }

    /// The new key window is only known once AppKit has finished moving focus.
    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { [weak self] in
            guard let self, isVisible else { return }
            if !NSApp.isActive, autoHideEnabled() {
                appResignedActive()
                return
            }
            guard Self.shouldClose(self, onChat: onChat, appActive: NSApp.isActive, newKey: NSApp.keyWindow) else { return }
            close()
        }
    }

    /// On Chat the window stays until closed, like the chat panel it replaced: Wispr Flow and screenshots work while
    /// another app is in front. Elsewhere it closes when ironpet is no longer active or the meeting panel became key.
    /// Anything the window opened itself (a sheet, a popover, an alert, an open panel) keeps it open.
    static func shouldClose(_ panel: NSWindow, onChat: Bool, appActive: Bool, newKey: NSWindow?) -> Bool {
        if onChat { return false }
        guard appActive else { return true }
        guard let newKey, newKey !== panel else { return false }
        if newKey.sheetParent === panel || newKey.parent === panel { return false }
        return newKey is MeetingPanel
    }

    /// Intercepts ⌘V when the pasteboard holds an image or text over the paste limit; other text paste stays with the field.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "v", attachPaste() { return true }
        if onChat, flags == .command, event.charactersIgnoringModifiers == "f", isKeyWindow {
            revealFind()
            return true
        }
        if isKeyWindow, runSidebarShortcut(flags: flags, characters: event.charactersIgnoringModifiers) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Attaches what the general pasteboard holds when it must not reach the text field. Also used by Edit > Paste.
    @discardableResult
    func attachPaste() -> Bool {
        guard onChat, let session else { return false }
        let saved = PasteIntake.importPaste(.general)
        guard !saved.isEmpty else { return false }
        session.attach(saved)
        return true
    }

    /// ⌃⌘S collapses or expands the sidebar; ⌘1 to ⌘9 select the Nth row, in either state. Returns whether it handled the key.
    func runSidebarShortcut(flags: NSEvent.ModifierFlags, characters: String?) -> Bool {
        if flags == [.command, .control], characters == "s" {
            model.toggleSidebar()
            return true
        }
        if flags == .command, let target = IronPetSection.forShortcut(characters, in: sidebarSections) {
            model.section = target
            return true
        }
        return false
    }

    /// On Chat, Esc stops a running turn first, like the stop button; only an idle chat closes.
    override func cancelOperation(_ sender: Any?) {
        guard onChat, let session else { return close() }
        if session.dismissSlash() { return }
        if session.findOpen {
            dismissFind()
            return
        }
        if session.isSpeaking {
            session.stopSpeech()
            return
        }
        if session.isRunning { session.stop() } else { close() }
    }

    override func close() {
        autoHidden = false
        let wasVisible = isVisible
        super.close()
        guard wasVisible else { return }
        onVisibilityChange?(false)
        onClose?()
    }

    /// Below the pet when there is room, otherwise above it; always clamped to the pet's screen, and no larger than it
    /// (a size saved on a bigger display would push the sidebar off the left edge). Stays where it is when already open.
    func show(near anchor: CGRect) {
        // Coming back from an auto-hide keeps the frame; opening it any other way places it next to the pet.
        let keepFrame = autoHidden
        autoHidden = false
        if !isVisible, !keepFrame {
            let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let size = Self.fitted(frame.size, in: screen)
            var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 4)
            if origin.y < screen.minY { origin.y = anchor.maxY + 4 }
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
            setFrame(CGRect(origin: origin, size: size), display: true)
        }
        makeKeyAndOrderFront(nil)
        onVisibilityChange?(true)
    }

    static func fitted(_ size: CGSize, in screen: CGRect) -> CGSize {
        CGSize(width: max(minimumSize.width, min(size.width, screen.width - 16)),
               height: max(minimumSize.height, min(size.height, screen.height - 16)))
    }

    /// Draws the window's own contents to a PNG, for tests; needs no screen-recording permission.
    func snapshot(to url: URL) -> Bool {
        guard let view = contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    // MARK: Chat focus

    /// Opens the find bar and moves focus into its field. Cmd-F calls this; tests call it directly because a
    /// test process has no key window.
    func revealFind() {
        guard let session else { return }
        session.findOpen = true
        session.findFocusTick += 1
        focusFind()
    }

    /// Closes the find bar and returns focus to the composer. Esc and the bar's close button both come here.
    /// The bar leaves the view tree on the next update, and that can hand focus to the window, so retry
    /// until the composer holds it.
    func dismissFind() {
        session?.findOpen = false
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
            guard let self, self.session?.findOpen == false else { return }
            self.refocusInput(attempt: attempt + 1)
        }
    }

    /// SwiftUI's FocusState only applies on first appearance; the window is reused, so focus the text view directly.
    func focusInput() {
        guard let field = contentView.flatMap(Self.firstTextInput) else { return }
        makeFirstResponder(field)
    }

    /// Moves focus to the find field and selects its text. The bar enters the view tree on the next SwiftUI update,
    /// so retry briefly until the field exists. `FocusState` alone loses to the composer, which keeps first responder.
    private func focusFind(attempt: Int = 0) {
        // Esc during the retries closes the bar; do not pull focus back to a field that is going away.
        guard session?.findOpen == true else { return }
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
