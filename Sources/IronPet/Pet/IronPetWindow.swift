import AppKit
import SwiftUI

/// A page of the ironpet window. The settings cases keep the Settings tab tags, which `/test/settings` takes.
enum IronPetSection: String, CaseIterable, Identifiable {
    case agents, alerts, tasks, actions, automations
    case general, integrations, voice, meetings, usage

    var id: String { rawValue }
    static let main: [IronPetSection] = [.agents, .alerts, .tasks, .actions, .automations]
    static let settings: [IronPetSection] = [.general, .integrations, .voice, .meetings, .usage]

    var title: String {
        switch self {
        case .agents: return "Agents"
        case .alerts: return "Alerts"
        case .tasks: return "Tasks"
        case .actions: return "Actions"
        case .automations: return "Automations"
        case .general: return "General"
        case .integrations: return "Integrations"
        case .voice: return "Voice"
        case .meetings: return "Meetings"
        case .usage: return "Usage"
        }
    }

    var symbol: String {
        switch self {
        case .agents: return "person.2"
        case .alerts: return "bell"
        case .tasks: return "checklist"
        case .actions: return "sparkles"
        case .automations: return "clock.badge.checkmark"
        case .general: return "gearshape"
        case .integrations: return "puzzlepiece.extension"
        case .voice: return "mic"
        case .meetings: return "person.2.wave.2"
        case .usage: return "chart.bar"
        }
    }

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
    @Published var section: IronPetSection = .agents
}

/// Agents, alerts, tasks, actions, automations and settings in one floating panel with a sidebar. Opens next to the
/// pet, and closes on Esc, when ironpet stops being the active app, or when the chat or
/// meeting panel takes over. Its own sheets, popovers, alerts and open panels keep it open.
final class IronPetPanel: NSPanel {
    static let title = "ironpet"
    static let minimumSize = CGSize(width: 700, height: 480)
    private static let sizeKey = "ironpetWindowSize"
    var onVisibilityChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init<Content: View>(content: Content) {
        super.init(contentRect: CGRect(origin: .zero, size: Self.savedSize),
                   styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        title = Self.title
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        hideStandardWindowButtons()
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
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let size = self?.frame.size else { return }
                    UserDefaults.standard.set(NSStringFromSize(size), forKey: Self.sizeKey)
                }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            },
        ]
    }

    private static var savedSize: CGSize {
        guard let saved = UserDefaults.standard.string(forKey: sizeKey) else { return CGSize(width: 780, height: 560) }
        let size = NSSizeFromString(saved)
        return CGSize(width: max(size.width, minimumSize.width), height: max(size.height, minimumSize.height))
    }

    override var canBecomeKey: Bool { true }

    /// AppKit re-shows the buttons on layout, key and appearance changes. Hide them again each pass.
    override func update() {
        super.update()
        hideStandardWindowButtons()
    }

    override func cancelOperation(_ sender: Any?) { close() }

    /// The new key window is only known once AppKit has finished moving focus.
    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { [weak self] in
            guard let self, isVisible, Self.shouldClose(self, appActive: NSApp.isActive, newKey: NSApp.keyWindow) else { return }
            close()
        }
    }

    /// Closes when ironpet is no longer active or another of its panels (the chat, the meeting) became key. Anything
    /// the window opened itself (a sheet, a popover, an alert, an open panel) keeps it open.
    static func shouldClose(_ panel: NSWindow, appActive: Bool, newKey: NSWindow?) -> Bool {
        guard appActive else { return true }
        guard let newKey, newKey !== panel else { return false }
        if newKey.sheetParent === panel || newKey.parent === panel { return false }
        return newKey is ChatPanel || newKey is MeetingPanel
    }

    override func close() {
        let wasVisible = isVisible
        super.close()
        if wasVisible { onVisibilityChange?(false) }
    }

    /// Below the pet when there is room, otherwise above it; always clamped to the pet's screen, and no larger than it
    /// (a size saved on a bigger display would push the sidebar off the left edge).
    func show(near anchor: CGRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = Self.fitted(frame.size, in: screen)
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 4)
        if origin.y < screen.minY { origin.y = anchor.maxY + 4 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        if !isVisible { setFrame(CGRect(origin: origin, size: size), display: true) }
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
}

struct IronPetWindowView: View {
    @ObservedObject var model: IronPetWindowModel
    @ObservedObject var store: SessionStore
    @ObservedObject var signals: SignalStore
    @ObservedObject var tasks: TaskStore
    /// Nil in previews that only show the main sections; the Settings rows are hidden then.
    var settings: SettingsModel?
    let actions: SessionActions

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 10)
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { model.section }, set: { if let section = $0 { model.section = section } })) {
            Section {
                ForEach(IronPetSection.main) { row($0) }
            }
            if settings != nil {
                Section("Settings") {
                    ForEach(IronPetSection.settings) { row($0) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 22) }
        .frame(width: 190)
    }

    private func row(_ section: IronPetSection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(count(section))
            .tag(section)
    }

    private func count(_ section: IronPetSection) -> Int {
        switch section {
        case .agents: return store.ordered.count
        case .alerts: return signals.signals.count
        case .tasks: return tasks.activeCount + tasks.suggestions.count
        default: return 0
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            switch model.section {
            case .agents: AgentsSection(store: store, onJump: actions.onJump)
            case .alerts: AlertsSection(signals: signals, onAsk: actions.onAsk)
            case .tasks:
                PageHeader(title: IronPetSection.tasks.title) { EmptyView() }
                TaskListView(tasks: tasks, onTellGhost: actions.onTellGhost, onOpenThread: actions.onOpenThread,
                             onOpenSession: actions.onOpenSession)
            case .actions: ActionsSection(onTrick: actions.onTrick)
            case .automations, .general, .integrations, .voice, .meetings, .usage:
                if let settings { SettingsPage(section: model.section, model: settings) }
            }
        }
    }
}

/// What the rows in the agents, alerts, tasks and actions sections do.
struct SessionActions {
    var onJump: (AgentSession) -> Void
    var onAsk: (String) -> Void
    var onTrick: (PetController.Trick) -> Void
    var onTellGhost: (String) -> Void
    var onOpenThread: (String) -> Void
    var onOpenSession: (String) -> Void

    static let none = SessionActions(onJump: { _ in }, onAsk: { _ in }, onTrick: { _ in }, onTellGhost: { _ in },
                                     onOpenThread: { _ in }, onOpenSession: { _ in })
}

/// The title of a section, with the actions that apply to all of it on the right.
struct PageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                trailing()
            }
            .padding(.horizontal, 16)
            .frame(height: 32)
            Divider()
        }
    }
}

