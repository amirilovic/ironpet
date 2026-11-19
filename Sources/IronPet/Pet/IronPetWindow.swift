import AppKit
import SwiftUI

/// A page of the ironpet window, in sidebar order.
enum IronPetSection: String, CaseIterable, Identifiable {
    case chat, agents, alerts, tasks, transcripts, screen, actions, automations, today

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .agents: return "Agents"
        case .alerts: return "Alerts"
        case .tasks: return "Tasks"
        case .transcripts: return "Transcripts"
        case .screen: return "Screen"
        case .actions: return "Actions"
        case .automations: return "Automations"
        case .today: return "Today"
        }
    }

    var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .agents: return "person.2"
        case .alerts: return "bell"
        case .tasks: return "checklist"
        case .transcripts: return "waveform"
        case .screen: return "rectangle.dashed.badge.record"
        case .actions: return "sparkles"
        case .automations: return "clock.badge.checkmark"
        case .today: return "sun.horizon"
        }
    }

    /// The sections the sidebar lists, in order. Chat, Transcripts and Automations need their backing object. Today is
    /// listed only while a brief or recap automation is on, and comes last so the other rows keep their ⌘N.
    static func shown(chat: Bool, transcripts: Bool, automations: Bool, today: Bool = false) -> [IronPetSection] {
        allCases.filter { ($0 != .chat || chat) && ($0 != .transcripts || transcripts) && ($0 != .automations || automations) && ($0 != .today || today) }
    }

    /// The section ⌘1 to ⌘9 select: the Nth row of `sections`. Nil for ⌘0, any other key, or a digit past the last row.
    static func forShortcut(_ characters: String?, in sections: [IronPetSection]) -> IronPetSection? {
        guard let characters, characters.count == 1, let digit = Int(characters), (1...9).contains(digit),
              digit <= sections.count else { return nil }
        return sections[digit - 1]
    }

    /// The shortcut that selects this section, such as "⌘4"; nil past the ninth row.
    func shortcutLabel(in sections: [IronPetSection]) -> String? {
        guard let index = sections.firstIndex(of: self), index < 9 else { return nil }
        return "⌘\(index + 1)"
    }

    /// The tooltip of a sidebar row or rail icon: the name and its ⌘N shortcut.
    func hint(in sections: [IronPetSection]) -> String {
        guard let shortcut = shortcutLabel(in: sections) else { return title }
        return "\(title) (\(shortcut))"
    }

    /// The sections that show what a bubble would announce, so bubbles wait while one is open. The others leave them
    /// visible, so an approval is not missed while reading a transcript or editing an automation.
    var hidesBubbles: Bool { [.chat, .agents, .alerts, .tasks, .actions, .today].contains(self) }

    /// Agents that need the user win; otherwise alerts when there are some and no agent is working, then tasks that
    /// wait on the user or on Add / Skip.
    @MainActor static func needingAttention(store: SessionStore, signals: SignalStore, tasks: TaskStore) -> IronPetSection {
        if store.ordered.contains(where: { $0.status == .needsInput || $0.status == .failed }) { return .agents }
        let idle = store.ordered.allSatisfy { $0.status != .running }
        if !signals.signals.isEmpty, idle { return .alerts }
        if idle, !tasks.suggestions.isEmpty || tasks.tasks.contains(where: \.needsUser) { return .tasks }
        return .agents
    }
}

@MainActor
final class IronPetWindowModel: ObservableObject {
    static let sidebarCollapsedKey = "ironpetSidebarCollapsed"
    static let sidebarWidthKey = "ironpetSidebarWidth"
    /// The expanded sidebar is 156 to 300 pt wide, 156 by default. At 156 the longest row ("Transcripts" or
    /// "Automations") fits with a badge.
    static let minSidebarWidth: CGFloat = 156
    static let maxSidebarWidth: CGFloat = 300
    /// The rail is as wide as the row of traffic lights: they span x 9 to 69, so it keeps the same 9 pt on the right.
    static let railWidth: CGFloat = 78
    /// Dragging the sidebar's edge below this width collapses it to the rail (halfway between rail and minimum);
    /// dragging a rail past it expands the sidebar.
    static let snapWidth: CGFloat = (railWidth + minSidebarWidth) / 2

    /// The width the sidebar has while the edge is dragged: where the pointer is, between the rail and the maximum.
    static func dragWidth(start: CGFloat, delta: CGFloat) -> CGFloat {
        min(max(start + delta, railWidth), maxSidebarWidth)
    }

    /// Whether a sidebar of this width shows the rail instead of the rows.
    static func showsRail(atWidth width: CGFloat) -> Bool { width < snapWidth }

    @Published var section: IronPetSection = .chat
    /// Whether the Today row is listed: a brief or recap automation is on. Leaving it hidden moves off the page.
    @Published var todayShown = false {
        didSet { if !todayShown, section == .today { section = .chat } }
    }
    /// The page Today shows: the morning brief or the recap.
    @Published var briefKind: Brief.Kind = .brief
    /// A task or meeting a Today row opened. The Tasks and Transcripts pages show it, then clear it.
    @Published var focusTask: String?
    @Published var focusMeeting: String?
    /// True when the sidebar shows only the section icons. Saved, so it survives closing the window and restarting.
    @Published var sidebarCollapsed: Bool {
        didSet {
            defaults.set(sidebarCollapsed, forKey: Self.sidebarCollapsedKey)
            clearRailTip()
        }
    }
    /// Width of the expanded sidebar; what the user last dragged it to. Saved.
    @Published var sidebarWidth: CGFloat {
        didSet { defaults.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey) }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sidebarCollapsed = defaults.bool(forKey: Self.sidebarCollapsedKey)
        let saved = defaults.double(forKey: Self.sidebarWidthKey)
        sidebarWidth = saved == 0 ? Self.minSidebarWidth : min(max(CGFloat(saved), Self.minSidebarWidth), Self.maxSidebarWidth)
    }

    func toggleSidebar() { sidebarCollapsed.toggle() }

    /// The width of the column as it is now: the rail's, or the sidebar's own.
    var columnWidth: CGFloat { sidebarCollapsed ? Self.railWidth : sidebarWidth }

    /// The drag ended with the edge at `width`: collapse to the rail below the snap width, otherwise expand to it.
    func endDrag(atWidth width: CGFloat) {
        if Self.showsRail(atWidth: width) {
            sidebarCollapsed = true
        } else {
            sidebarWidth = min(max(width, Self.minSidebarWidth), Self.maxSidebarWidth)
            sidebarCollapsed = false
        }
    }

    // MARK: Rail labels

    /// How long the pointer rests on a rail icon before its label shows.
    static var railTipDelay: Duration = .milliseconds(400)
    /// The label to draw beside a rail icon, or nil. A native `.help` tooltip does not show while ironpet is not the
    /// active app, which is the usual state of this floating window, so the rail draws its own label.
    @Published private(set) var railTip: RailTip?
    private var railTipTask: Task<Void, Never>?

    /// The pointer entered or left a rail icon. Entering shows the label after `railTipDelay`; leaving hides it.
    func hoverRail(_ tip: RailTip, hovering: Bool) {
        railTipTask?.cancel()
        guard hovering else {
            railTip = nil
            return
        }
        railTipTask = Task { [weak self] in
            try? await Task.sleep(for: Self.railTipDelay)
            guard !Task.isCancelled else { return }
            self?.railTip = tip
        }
    }

    /// Hides the label and cancels one that is still waiting: a click, or the sidebar changing state.
    func clearRailTip() {
        railTipTask?.cancel()
        railTip = nil
    }
}

/// The text of a rail label and where its icon is, in the window's coordinates.
struct RailTip: Equatable {
    let name: String
    let shortcut: String?
    let frame: CGRect
}

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
    private let session: ChatSession?
    private var observers: [NSObjectProtocol] = []

    init<Content: View>(model: IronPetWindowModel, session: ChatSession?, content: Content) {
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
                                   voiceBusy: session?.voice.isBusy == true) { autoHide() }
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
        IronPetSection.shown(chat: session != nil, transcripts: true, automations: true, today: model.todayShown)
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
        if session.speech.isSpeaking {
            session.speech.stop()
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

struct IronPetWindowView: View {
    @ObservedObject var model: IronPetWindowModel
    @ObservedObject var store: SessionStore
    @ObservedObject var signals: SignalStore
    @ObservedObject var tasks: TaskStore
    /// Nil in previews and tests that do not show it; its row is hidden then.
    var chat: ChatSession?
    var meetings: MeetingLibrary?
    /// Nil in previews, which cannot build the Automations section; its row is hidden then.
    var settings: SettingsModel?
    /// The Today page's content. Nil in tests that do not show it.
    var brief: BriefModel?
    let actions: SessionActions
    @ObservedObject private var config = ConfigStore.shared

    var body: some View {
        // One background under the sidebar and the page; the sidebar is glass over it.
        ZStack {
            ChatBackdrop()
            HStack(spacing: 0) {
                sidebarColumn
                // The edge is a drag handle, wider than the line it sits on.
                Divider().overlay {
                    SidebarResizeHandle(
                        onBegin: { dragStart = liveWidth ?? model.columnWidth; model.clearRailTip() },
                        onDrag: { delta in
                            guard let start = dragStart else { return }
                            liveWidth = IronPetWindowModel.dragWidth(start: start, delta: delta)
                        },
                        onEnd: {
                            if let width = liveWidth { model.endDrag(atWidth: width) }
                            liveWidth = nil
                            dragStart = nil
                        })
                    .frame(width: 9)
                }
                .zIndex(1) // above the detail view, so the handle's wider hit area is not covered
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .coordinateSpace(name: RailHover.space)
        // Over the page, outside the rail, which clips its own content.
        .overlay(alignment: .topLeading) {
            if collapsed, let tip = model.railTip {
                RailLabel(tip: tip)
                    .offset(x: IronPetWindowModel.railWidth - 2, y: tip.frame.minY)
                    .frame(height: tip.frame.height, alignment: .leading)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.railTip)
    }

    private var shown: [IronPetSection] {
        IronPetSection.shown(chat: chat != nil, transcripts: meetings != nil, automations: settings != nil, today: model.todayShown)
    }

    private var collapsed: Bool { model.sidebarCollapsed }
    /// The column's width while its edge is being dragged; nil otherwise.
    @State private var liveWidth: CGFloat?
    @State private var dragStart: CGFloat?
    /// Whether the column shows the rail: while dragging, whichever side of the snap width the edge is on.
    private var showsRail: Bool { liveWidth.map(IronPetWindowModel.showsRail(atWidth:)) ?? collapsed }

    /// While dragging, the rows never render narrower than their minimum; the rail shows below the snap width.
    private var columnWidth: CGFloat {
        guard let live = liveWidth else { return model.columnWidth }
        return showsRail ? live : max(live, IronPetWindowModel.minSidebarWidth)
    }

    /// The full sidebar or the icon rail, one glass column whose width animates between the two.
    private var sidebarColumn: some View {
        ZStack {
            if showsRail { rail.transition(.opacity) } else { sidebar.transition(.opacity) }
        }
        .frame(width: columnWidth)
        .clipped()
        // The whole column, insets included, is glass over the window background: a half-strength material, so the pattern stays visible through it.
        .background { Rectangle().fill(.ultraThinMaterial).opacity(IronPetGlass.strength) }
        .animation(.easeInOut(duration: 0.2), value: showsRail)
        .animation(.easeInOut(duration: 0.2), value: model.sidebarWidth)
    }

    private var sidebar: some View {
        List(selection: Binding(get: { model.section }, set: { if let section = $0 { model.section = section } })) {
            ForEach(shown) { row($0) }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            // Room for the traffic lights, which the window draws over this strip.
            Color.clear.frame(height: PageHeaderMetrics.height)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: actions.onSettings) {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.ironPetSidebar)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .help("Open ironpet Settings (⌘,)")
        }
    }

    /// Only the section icons, in the sidebar's order, under the traffic lights.
    private var rail: some View {
        VStack(spacing: 4) {
            ForEach(shown) { section in
                Button { model.clearRailTip(); model.section = section } label: {
                    Image(systemName: section.symbol)
                        .font(.system(size: 21))
                        .frame(width: 40, height: 38)
                        .background {
                            if model.section == section {
                                RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.28))
                            }
                        }
                        .overlay(alignment: .topTrailing) { railBadge(count(section)) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.section == section ? Color.accentColor : Color.primary)
                .railHover(model, name: section.title, shortcut: section.shortcutLabel(in: shown))
                .accessibilityLabel(section.title)
            }
            Spacer(minLength: 0)
            Button(action: { model.clearRailTip(); actions.onSettings() }) {
                Image(systemName: "gearshape").font(.system(size: 21)).frame(width: 40, height: 38).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .railHover(model, name: "Settings", shortcut: "⌘,")
            .accessibilityLabel("Settings")
            .padding(.bottom, 10)
        }
        .padding(.top, PageHeaderMetrics.height + 4)
    }

    @ViewBuilder private func railBadge(_ count: Int) -> some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 14, minHeight: 14)
                .background(Capsule().fill(Color.accentColor))
                .offset(x: 2, y: -2)
        }
    }

    private func row(_ section: IronPetSection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .labelStyle(.ironPetSidebar)
            .badge(count(section))
            .tag(section)
            .help(shortcutHint(section))
    }

    private func shortcutHint(_ section: IronPetSection) -> String { section.hint(in: shown) }

    private func count(_ section: IronPetSection) -> Int {
        switch section {
        case .agents: return store.ordered.count
        case .alerts: return signals.signals.count
        case .tasks: return tasks.activeCount + tasks.suggestions.count
        default: return 0
        }
    }

    @ViewBuilder private var detail: some View {
        if model.section == .chat, let chat {
            // The chat draws its own floating header up to the top edge.
            ChatView(session: chat)
        } else {
            VStack(spacing: 0) {
                switch model.section {
                case .chat: EmptyView()
                case .agents: AgentsSection(store: store, onJump: actions.onJump)
                case .alerts: AlertsSection(signals: signals, onAsk: actions.onAsk)
                case .tasks:
                    TaskListView(tasks: tasks, onTellGhost: actions.onTellGhost, onOpenThread: actions.onOpenThread,
                                 onOpenSession: actions.onOpenSession, focus: $model.focusTask)
                        .pageHeader(IronPetSection.tasks.title)
                case .transcripts:
                    if let meetings {
                        TranscriptsView(library: meetings, activeFolder: actions.meetingInProgress, onAsk: actions.onAskMeeting,
                                        focus: $model.focusMeeting)
                    }
                case .screen:
                    if let service = settings?.capture {
                        ScreenSection(model: service.model, store: service.store, onOpenSettings: actions.onScreenSettings,
                                      onAppear: { service.refreshModel() })
                    } else {
                        ScreenSection(model: CaptureStatusModel(), onOpenSettings: actions.onScreenSettings)
                    }
                case .actions: ActionsSection(onTrick: actions.onTrick)
                case .automations:
                    if let settings {
                        AutomationsSettings(model: settings).frame(maxHeight: .infinity)
                            .pageHeader(IronPetSection.automations.title)
                    }
                case .today:
                    if let brief {
                        TodayView(model: brief, kind: $model.briefKind, onOpen: actions.onBriefOpen)
                    }
                }
            }
            // A photo behind unfilled rows would hide their text; the built-in patterns are faint enough without it.
            .background { if config.config.chat.background == ChatBackground.customID { Rectangle().fill(.thinMaterial) } }
        }
    }
}

/// What the rows and buttons in the window's sections do.
struct SessionActions {
    var onJump: (AgentSession) -> Void
    var onAsk: (String) -> Void
    var onTrick: (PetController.Trick) -> Void
    var onTellGhost: (String) -> Void
    var onOpenThread: (String) -> Void
    var onOpenSession: (String) -> Void
    var onAskMeeting: ([URL]) -> Void = { _ in }
    /// The folder of the meeting being recorded or summarized, if any.
    var meetingInProgress: () -> URL? = { nil }
    var onSettings: () -> Void = {}
    /// Opens Settings on the Screen tab.
    var onScreenSettings: () -> Void = {}
    /// A row of the Today page.
    var onBriefOpen: (Brief.Target) -> Void = { _ in }

    static let none = SessionActions(onJump: { _ in }, onAsk: { _ in }, onTrick: { _ in }, onTellGhost: { _ in },
                                     onOpenThread: { _ in }, onOpenSession: { _ in })
}

/// Size of every section header and where its title sits. 52 pt is the height of a macOS unified toolbar (it was 30).
/// The window moves the traffic lights down to the middle of this band (`IronPetPanel.centerWindowButtons`), so the
/// title and the traffic lights share one center line.
enum PageHeaderMetrics {
    static let height: CGFloat = 52
}

/// The title of a section, with the actions that apply to all of it on the right. Every section, and the chat, uses it,
/// so the height and the title's position are the same everywhere. `leading` goes just before the title (the chat's avatar).
struct PageHeader<Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading()
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .background(FrameReader(role: .title))
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(height: PageHeaderMetrics.height)
        .background(FrameReader(role: .header))
    }
}

/// Reports where a header and its title were laid out, in window coordinates, so a test can compare sections.
struct PageHeaderFrames: PreferenceKey, Equatable {
    var header: CGRect?
    var title: CGRect?
    static let defaultValue = PageHeaderFrames()
    static func reduce(value: inout PageHeaderFrames, nextValue: () -> PageHeaderFrames) {
        let next = nextValue()
        value.header = value.header ?? next.header
        value.title = value.title ?? next.title
    }
}

private struct FrameReader: View {
    enum Role { case header, title }
    let role: Role

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear.preference(key: PageHeaderFrames.self,
                                   value: role == .header ? PageHeaderFrames(header: frame) : PageHeaderFrames(title: frame))
        }
    }
}

extension PageHeader where Leading == EmptyView {
    init(title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, leading: { EmptyView() }, trailing: trailing)
    }
}

extension View {
    /// Puts a glass panel at the top of a section, the width of the section, with the window background showing
    /// through it. The section scrolls under the panel. The panel starts at the top of the window, under the
    /// transparent title bar, and is `PageHeaderMetrics.height` tall.
    func pageHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            GlassPanel { PageHeader(title: title, trailing: trailing) }
        }
    }
}

/// How much of the material the sidebar and the headers use: half, so the pattern behind the window shows through the
/// glass instead of blurring away.
enum IronPetGlass {
    static let strength = 0.5
}

/// The glass strip used by every section's header and by the chat header: a material with a hairline below it.
struct GlassPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity)
            .background { Rectangle().fill(.ultraThinMaterial).opacity(IronPetGlass.strength) }
            .overlay(alignment: .bottom) {
                // An explicit line: a Divider takes its direction from the container it lands in and turned vertical in the chat's bar.
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            }
    }
}

/// Reports a rail icon's hover and position to the model, which shows the label.
private struct RailHover: ViewModifier {
    static let space = "ironpetWindow"
    let model: IronPetWindowModel
    let name: String
    let shortcut: String?
    @State private var frame = CGRect.zero

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { frame = proxy.frame(in: .named(Self.space)) }
                        .onChange(of: proxy.frame(in: .named(Self.space))) { _, new in frame = new }
                }
            }
            .onHover { hovering in
                model.hoverRail(RailTip(name: name, shortcut: shortcut, frame: frame), hovering: hovering)
            }
    }
}

private extension View {
    func railHover(_ model: IronPetWindowModel, name: String, shortcut: String?) -> some View {
        modifier(RailHover(model: model, name: name, shortcut: shortcut))
    }
}

/// The small rounded label beside a collapsed rail icon: the name, then its shortcut.
struct RailLabel: View {
    let tip: RailTip

    var body: some View {
        HStack(spacing: 8) {
            Text(tip.name).font(.system(size: 13, weight: .medium))
            if let shortcut = tip.shortcut {
                Text(shortcut).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1) }
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}

/// The sidebar's draggable edge. An AppKit view, not a SwiftUI gesture: the window moves when dragged by its background,
/// and this view says a press on it must not.
struct SidebarResizeHandle: NSViewRepresentable {
    var onBegin: () -> Void
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onEnd = onEnd
    }

    final class HandleView: NSView {
        var onBegin: () -> Void = {}
        var onDrag: (CGFloat) -> Void = { _ in }
        var onEnd: () -> Void = {}
        private var startX: CGFloat = 0

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
        }

        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
            onBegin()
        }

        override func mouseDragged(with event: NSEvent) { onDrag(event.locationInWindow.x - startX) }
        override func mouseUp(with event: NSEvent) { onEnd() }
    }
}
