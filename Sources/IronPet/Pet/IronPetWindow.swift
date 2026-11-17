import AppKit
import SwiftUI

/// A page of the ironpet window, in sidebar order.
enum IronPetSection: String, CaseIterable, Identifiable {
    case chat, agents, alerts, tasks, transcripts, actions, automations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .agents: return "Agents"
        case .alerts: return "Alerts"
        case .tasks: return "Tasks"
        case .transcripts: return "Transcripts"
        case .actions: return "Actions"
        case .automations: return "Automations"
        }
    }

    var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .agents: return "person.2"
        case .alerts: return "bell"
        case .tasks: return "checklist"
        case .transcripts: return "waveform"
        case .actions: return "sparkles"
        case .automations: return "clock.badge.checkmark"
        }
    }

    /// The sections the sidebar lists, in order. Chat, Transcripts and Automations need their backing object.
    static func shown(chat: Bool, transcripts: Bool, automations: Bool) -> [IronPetSection] {
        allCases.filter { ($0 != .chat || chat) && ($0 != .transcripts || transcripts) && ($0 != .automations || automations) }
    }

    /// The section ⌘1 to ⌘9 select: the Nth row of `sections`. Nil for ⌘0, any other key, or a digit past the last row.
    static func forShortcut(_ characters: String?, in sections: [IronPetSection]) -> IronPetSection? {
        guard let characters, characters.count == 1, let digit = Int(characters), (1...9).contains(digit),
              digit <= sections.count else { return nil }
        return sections[digit - 1]
    }

    /// The tooltip of a sidebar row or rail icon: the name and its ⌘N shortcut.
    func hint(in sections: [IronPetSection]) -> String {
        guard let index = sections.firstIndex(of: self), index < 9 else { return title }
        return "\(title) (⌘\(index + 1))"
    }

    /// The sections that show what a bubble would announce, so bubbles wait while one is open. The others leave them
    /// visible, so an approval is not missed while reading a transcript or editing an automation.
    var hidesBubbles: Bool { [.chat, .agents, .alerts, .tasks, .actions].contains(self) }

    /// Agents that need the user win; otherwise alerts when there are some and no agent is working, then tasks that
    /// wait on the user or on Add / Skip.
    @MainActor static func needingAttention(store: SessionStore, signals: SignalStore, tasks: TaskStore) -> IronPetSection {
        if store.ordered.contains(where: { $0.status == .needsInput || $0.status == .failed }) { return .agents }
        let idle = store.ordered.allSatisfy { $0.status != .running }
        if !signals.signals.isEmpty, idle { return .alerts }
        if idle, !tasks.suggestions.isEmpty || tasks.tasks.contains(where: { $0.status == .needsYou }) { return .tasks }
        return .agents
    }
}

@MainActor
final class IronPetWindowModel: ObservableObject {
    static let sidebarCollapsedKey = "ironpetSidebarCollapsed"
    /// Width of the full sidebar and of the icon rail. The rail is as wide as the traffic lights above it.
    static let sidebarWidth: CGFloat = 190
    static let railWidth: CGFloat = 72

    @Published var section: IronPetSection = .chat
    /// True when the sidebar shows only the section icons. Saved, so it survives closing the window and restarting.
    @Published var sidebarCollapsed: Bool {
        didSet { defaults.set(sidebarCollapsed, forKey: Self.sidebarCollapsedKey) }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sidebarCollapsed = defaults.bool(forKey: Self.sidebarCollapsedKey)
    }

    func toggleSidebar() { sidebarCollapsed.toggle() }
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
        let center = NotificationCenter.default
        observers = [
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
                MainActor.assumeIsolated {
                    guard let self, self.isVisible, !self.onChat else { return }
                    self.close()
                }
            },
        ]
    }

    private static var savedSize: CGSize {
        guard let saved = UserDefaults.standard.string(forKey: sizeKey) else { return CGSize(width: 820, height: 600) }
        let size = NSSizeFromString(saved)
        return CGSize(width: max(size.width, minimumSize.width), height: max(size.height, minimumSize.height))
    }

    /// The rows the sidebar shows; ⌘1 to ⌘9 index into this list.
    private var sidebarSections: [IronPetSection] {
        IronPetSection.shown(chat: session != nil, transcripts: true, automations: true)
    }

    private var onChat: Bool { session != nil && model.section == .chat }

    override var canBecomeKey: Bool { true }

    /// The new key window is only known once AppKit has finished moving focus.
    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { [weak self] in
            guard let self, isVisible,
                  Self.shouldClose(self, onChat: onChat, appActive: NSApp.isActive, newKey: NSApp.keyWindow) else { return }
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

    /// Intercepts ⌘V only when the pasteboard holds an image and no text; text paste stays with the field.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if onChat, let session, flags == .command, event.charactersIgnoringModifiers == "v", ImageIntake.decide(.general) != .text {
            let saved = ImageIntake.importPaste(.general)
            if !saved.isEmpty {
                saved.forEach(session.attach)
                return true
            }
        }
        if onChat, flags == .command, event.charactersIgnoringModifiers == "f", isKeyWindow {
            revealFind()
            return true
        }
        if isKeyWindow, runSidebarShortcut(flags: flags, characters: event.charactersIgnoringModifiers) { return true }
        return super.performKeyEquivalent(with: event)
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
        if session.isRunning { session.stop() } else { close() }
    }

    override func close() {
        let wasVisible = isVisible
        super.close()
        guard wasVisible else { return }
        onVisibilityChange?(false)
        onClose?()
    }

    /// Below the pet when there is room, otherwise above it; always clamped to the pet's screen, and no larger than it
    /// (a size saved on a bigger display would push the sidebar off the left edge). Stays where it is when already open.
    func show(near anchor: CGRect) {
        if !isVisible {
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
    let actions: SessionActions
    @ObservedObject private var config = ConfigStore.shared

    var body: some View {
        // One background under the sidebar and the page; the sidebar is glass over it.
        ZStack {
            ChatBackdrop()
            HStack(spacing: 0) {
                sidebarColumn
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var shown: [IronPetSection] {
        IronPetSection.shown(chat: chat != nil, transcripts: meetings != nil, automations: settings != nil)
    }

    private var collapsed: Bool { model.sidebarCollapsed }

    /// The full sidebar or the icon rail, one glass column whose width animates between the two.
    private var sidebarColumn: some View {
        ZStack {
            if collapsed { rail.transition(.opacity) } else { sidebar.transition(.opacity) }
        }
        .frame(width: collapsed ? IronPetWindowModel.railWidth : IronPetWindowModel.sidebarWidth)
        .clipped()
        // The whole column, insets included, is glass over the window background: a half-strength material, so the pattern stays visible through it.
        .background { Rectangle().fill(.ultraThinMaterial).opacity(IronPetGlass.strength) }
        .animation(.easeInOut(duration: 0.2), value: collapsed)
    }

    private var toggleButton: some View {
        Button { model.toggleSidebar() } label: {
            Image(systemName: "sidebar.left").font(.system(size: 14)).frame(width: 28, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(collapsed ? "Show sidebar (⌃⌘S)" : "Hide sidebar (⌃⌘S)")
        .accessibilityLabel(collapsed ? "Show sidebar" : "Hide sidebar")
    }

    private var sidebar: some View {
        List(selection: Binding(get: { model.section }, set: { if let section = $0 { model.section = section } })) {
            ForEach(shown) { row($0) }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            // The traffic lights sit at the left of this strip, the toggle at the right.
            HStack { Spacer(); toggleButton }.padding(.horizontal, 10).frame(height: 28, alignment: .top)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: actions.onSettings) {
                Label("Settings", systemImage: "gearshape")
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
            toggleButton.padding(.top, 28)
            ForEach(shown) { section in
                Button { model.section = section } label: {
                    Image(systemName: section.symbol)
                        .font(.system(size: 16))
                        .frame(width: 44, height: 34)
                        .background {
                            if model.section == section {
                                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.28))
                            }
                        }
                        .overlay(alignment: .topTrailing) { railBadge(count(section)) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.section == section ? Color.accentColor : Color.primary)
                .help(shortcutHint(section))
                .accessibilityLabel(section.title)
            }
            Spacer(minLength: 0)
            Button(action: actions.onSettings) {
                Image(systemName: "gearshape").font(.system(size: 16)).frame(width: 44, height: 34).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open ironpet Settings (⌘,)")
            .accessibilityLabel("Settings")
            .padding(.bottom, 10)
        }
        .padding(.top, 4)
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
                                 onOpenSession: actions.onOpenSession)
                        .pageHeader(IronPetSection.tasks.title)
                case .transcripts:
                    if let meetings {
                        TranscriptsView(library: meetings, activeFolder: actions.meetingInProgress, onAsk: actions.onAskMeeting)
                    }
                case .actions: ActionsSection(onTrick: actions.onTrick)
                case .automations:
                    if let settings {
                        AutomationsSettings(model: settings).frame(maxHeight: .infinity)
                            .pageHeader(IronPetSection.automations.title)
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

    static let none = SessionActions(onJump: { _ in }, onAsk: { _ in }, onTrick: { _ in }, onTellGhost: { _ in },
                                     onOpenThread: { _ in }, onOpenSession: { _ in })
}

/// Size of every section header and where its title sits. The height puts the title's vertical center level with the
/// traffic lights, which sit about 15 pt below the top of the window.
enum PageHeaderMetrics {
    static let height: CGFloat = 30
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
