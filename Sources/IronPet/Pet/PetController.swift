import AppKit
import Combine
import SwiftUI

/// Owns the floating panel and maps session state to the pet's mood.
@MainActor
final class PetController: NSObject {
    static let scale: CGFloat = 0.6
    static let sleepAfter: TimeInterval = 10 * 60
    private static let originKey = "petOrigin"

    let panel: NSPanel
    private let view: PetView
    private let store: SessionStore
    private let signals: SignalStore
    private let agentsPanel = AgentsPanel()
    private var lastActivity = Date()
    private var lastTick = Date()
    private var nudge: (mood: PetMood, until: Date)?
    private var nudgeGeneration = 0
    private var cancellables: Set<AnyCancellable> = []

    var extraMenuItems: () -> [NSMenuItem] = { [] }
    var onRefresh: ((PetMood) -> Void)?
    var chatMood: () -> PetMood? = { nil }
    var onChatToggle: (() -> Void)?
    /// "Ask Ghost" on an alert: open the chat with this prompt ready to send.
    var onAsk: ((String) -> Void)?
    var onCapture: ((_ region: Bool) -> Void)?

    init(store: SessionStore, signals: SignalStore) {
        self.store = store
        self.signals = signals
        let size = CGSize(width: Atlas.cell.width * Self.scale, height: Atlas.cell.height * Self.scale)
        let view = PetView(atlas: Atlas.loadDefault(), size: size)
        let panel = NSPanel(contentRect: CGRect(origin: Self.savedOrigin(size: size), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.contentView = view
        self.view = view
        self.panel = panel
        super.init()

        view.onClick = { [weak self] in self?.handleClick() }
        view.onDragEnded = { [weak self] in self?.saveOrigin() }
        view.contextMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }

        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.lastActivity = Date()
                self?.refreshMood()
            }
            .store(in: &cancellables)
        signals.$signals
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMood() }
            .store(in: &cancellables)
    }

    func show() {
        panel.orderFrontRegardless()
        refreshMood()
    }

    func tick() {
        let now = Date()
        view.tick(now.timeIntervalSince(lastTick))
        lastTick = now
        if view.mood == .idle, now.timeIntervalSince(lastActivity) > Self.sleepAfter { refreshMood() }
    }

    var isAgentsVisible: Bool { agentsPanel.isVisible }

    func jump(to session: AgentSession) {
        agentsPanel.close()
        SourceJumper.jump(to: session)
        store.acknowledge(session.id)
    }

    /// Plays moods one after another over the current one (drinking, stretching, a "done" jump).
    func nudge(_ moods: [PetMood], each duration: TimeInterval = 4) {
        nudgeGeneration += 1
        playNudge(moods[...], each: duration, generation: nudgeGeneration)
    }

    private func playNudge(_ moods: ArraySlice<PetMood>, each duration: TimeInterval, generation: Int) {
        guard generation == nudgeGeneration else { return }
        guard let first = moods.first else { nudge = nil; return refreshMood() }
        nudge = (first, Date().addingTimeInterval(duration))
        lastActivity = Date()
        refreshMood()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.playNudge(moods.dropFirst(), each: duration, generation: generation)
        }
    }

    func refreshMood() {
        if let nudge, nudge.until > Date() {
            view.show(nudge.mood, badge: 0)
            onRefresh?(view.mood)
            return
        }
        nudge = nil
        let summary = store.summary
        let watched: PetMood? = summary.status == .idle ? nil : summary.status.mood
        let alerts = signals.summary
        let chat = chatMood()
        if chat != nil { lastActivity = Date() }
        if let mood = [watched, alerts?.mood, chat].compactMap({ $0 }).max(by: { Self.urgency($0) < Self.urgency($1) }) {
            let badge = (mood == watched ? summary.count : 0) + (mood == alerts?.mood ? alerts?.count ?? 0 : 0)
            view.show(mood, badge: badge)
        } else {
            let sleepy = Date().timeIntervalSince(lastActivity) > Self.sleepAfter
            view.show(sleepy ? .sleeping : .idle, badge: 0)
        }
        onRefresh?(view.mood)
    }

    private static func urgency(_ mood: PetMood) -> Int {
        [.idle, .sleeping, .listening, .working, .done, .failed, .needsInput].firstIndex(of: mood) ?? 0
    }

    /// Watched agents or alerts that need attention take the click; otherwise it opens the chat.
    private func handleClick() {
        lastActivity = Date()
        if [.needsInput, .failed, .done].contains(store.summary.status) || !signals.signals.isEmpty || onChatToggle == nil {
            togglePopover()
        } else {
            onChatToggle?()
        }
    }

    private func togglePopover() {
        lastActivity = Date()
        if agentsPanel.isVisible {
            agentsPanel.close()
        } else {
            NSApp.activate()
            agentsPanel.show(SessionListView(
                store: store, signals: signals,
                onJump: { [weak self] session in self?.jump(to: session) },
                onAsk: { [weak self] prompt in
                    self?.agentsPanel.close()
                    self?.onAsk?(prompt)
                },
                onTrick: { [weak self] trick in
                    // Bubbles are hidden while this window is open.
                    if trick == .speak { self?.agentsPanel.close() }
                    self?.perform(trick)
                }
            ), near: panel.frame)
        }
        refreshMood()
    }

    /// Reloads the sprite sheet after `pet.sprite` changes.
    func reloadAtlas() {
        view.setAtlas(Atlas.loadDefault())
    }

    @objc private func showAgents(_ sender: Any?) { togglePopover() }
    @objc private func showChat(_ sender: Any?) { onChatToggle?() }
    @objc private func captureWindow(_ sender: Any?) { onCapture?(false) }
    @objc private func captureRegion(_ sender: Any?) { onCapture?(true) }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let config = ConfigStore.shared.config
        for (title, shortcut, action) in [("Chat with \(config.pet.name)", config.hotkeys.chat, #selector(showChat(_:))),
                                          ("Ask about front window", config.hotkeys.captureWindow, #selector(captureWindow(_:))),
                                          ("Ask about a region", config.hotkeys.captureRegion, #selector(captureRegion(_:)))] {
            let label = Shortcut.display(shortcut).map { "\(title)  \($0)" } ?? title
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        let agents = NSMenuItem(title: "Show agents", action: #selector(showAgents(_:)), keyEquivalent: "")
        agents.target = self
        menu.addItem(agents)
        menu.addItem(tricksMenuItem())
        menu.addItem(.separator())
        extraMenuItems().forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ironpet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    // MARK: Tricks

    /// Things Ghost does on request, from the right-click "Actions" menu.
    enum Trick: String, CaseIterable {
        case wave = "Wave", jump = "Jump", dance = "Dance", zoomies = "Zoomies"
        case stretch = "Stretch", drink = "Drink water", code = "Write some code"
        case ask = "Look curious", sulk = "Sulk", nap = "Take a nap", speak = "Say something"

        var symbol: String {
            switch self {
            case .wave: return "hand.wave.fill"
            case .jump: return "arrow.up.circle.fill"
            case .dance: return "music.note"
            case .zoomies: return "hare.fill"
            case .stretch: return "figure.flexibility"
            case .drink: return "drop.fill"
            case .code: return "laptopcomputer"
            case .ask: return "questionmark.circle.fill"
            case .sulk: return "cloud.rain.fill"
            case .nap: return "moon.zzz.fill"
            case .speak: return "text.bubble.fill"
            }
        }
    }

    private static let sayings = [
        "Winter is coming. So is your deploy.",
        "The night is dark and full of merge conflicts.",
        "I've been watching your agents. They're fine. Mostly.",
        "A direwolf never forgets a failing test.",
        "Did you drink water? I did.",
        "Ship it.",
        "Have you tried turning it off and on again?",
        "Your code looks great today.",
        "I like it up here, on top of all your windows.",
        "Need a hand? Click me and I'm all ears.",
        "My watch has ended. Just kidding, it never ends.",
        "Awoo.",
    ]

    /// Shows a bubble from Ghost.
    var onSay: ((String) -> Void)?

    private func tricksMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        for trick in Trick.allCases {
            if trick == .stretch || trick == .speak { submenu.addItem(.separator()) }
            let item = NSMenuItem(title: trick.rawValue, action: #selector(performTrick(_:)), keyEquivalent: "")
            item.representedObject = trick.rawValue
            item.target = self
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func performTrick(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let trick = Trick(rawValue: raw) else { return }
        perform(trick)
    }

    func perform(_ trick: Trick) {
        switch trick {
        case .wave: nudge([.listening], each: 2)
        case .jump: nudge([.done], each: 2.5)
        case .dance: nudge([.done, .listening, .done, .stretching, .done], each: 1.4)
        case .zoomies: zoomies()
        case .stretch: nudge([.stretching], each: 4)
        case .drink: nudge([.drinking], each: 3.5)
        case .code: nudge([.working], each: 5)
        case .ask: nudge([.needsInput], each: 4)
        case .sulk: nudge([.failed], each: 4)
        case .nap: nudge([.sleeping], each: 6)
        case .speak:
            nudge([.listening], each: 2)
            onSay?(Self.sayings.randomElement()!)
        }
    }

    private var zoomTimer: Timer?
    private var zoomHome = CGPoint.zero
    private var zoomLegs: [CGFloat] = []

    /// Runs out toward the roomier side and back a couple of times, then lands where he started.
    private func zoomies() {
        if zoomTimer == nil { zoomHome = panel.frame.origin }
        let screen = panel.screen?.visibleFrame ?? .zero
        let roomLeft = zoomHome.x - screen.minX, roomRight = screen.maxX - (zoomHome.x + panel.frame.width)
        let side: CGFloat = roomLeft > roomRight ? -1 : 1
        let reach = min(220, max(roomLeft, roomRight) - 10)
        zoomLegs = [side * reach, 0, side * reach * 0.6, 0]
        lastActivity = Date()
        zoomTimer?.invalidate()
        zoomTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.zoomStep() }
        }
    }

    private func zoomStep() {
        guard let leg = zoomLegs.first else {
            zoomTimer?.invalidate()
            zoomTimer = nil
            panel.setFrameOrigin(zoomHome)
            nudge([.done], each: 2)
            return
        }
        let x = panel.frame.origin.x, target = zoomHome.x + leg
        if abs(target - x) < 1 {
            zoomLegs.removeFirst()
            return
        }
        let step = max(-7, min(7, target - x))
        panel.setFrameOrigin(CGPoint(x: x + step, y: zoomHome.y))
        view.run(direction: step > 0 ? 1 : -1)
    }

    private func saveOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
    }

    private static func savedOrigin(size: CGSize) -> CGPoint {
        if let saved = UserDefaults.standard.string(forKey: originKey) {
            let point = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -size.width / 2, dy: -size.height / 2).contains(point) }) {
                return point
            }
        }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: screen.maxX - size.width - 40, y: screen.minY + 40)
    }
}