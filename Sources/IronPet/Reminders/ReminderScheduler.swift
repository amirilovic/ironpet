import AppKit
import CoreGraphics

/// Water, stretch and eye-break nudges. Time only counts while the user is at the keyboard, and a
/// break of `idleResetMinutes` or longer resets every timer. A reminder is due after its interval; while an
/// agent is working it may go out up to a quarter of the interval early, and everything close to due
/// rides along in the same notification. Nothing is sent while the user is answering Ghost.
@MainActor
final class ReminderScheduler: NSObject {
    enum Kind: String, CaseIterable {
        case water, stretch, eyes

        var configPath: WritableKeyPath<Config.Reminders, Config.Reminders.Item> {
            switch self {
            case .water: return \.water
            case .stretch: return \.stretch
            case .eyes: return \.eyes
            }
        }

        var name: String {
            switch self {
            case .water: return "Drink water"
            case .stretch: return "Stretch"
            case .eyes: return "Eye break"
            }
        }

        var title: String {
            switch self {
            case .water: return "Drink some water"
            case .stretch: return "Stretch a bit"
            case .eyes: return "Rest your eyes"
            }
        }

        var body: String {
            switch self {
            case .water: return "Have a glass of water."
            case .stretch: return "Stand up, roll your shoulders, stretch your back."
            case .eyes: return "Look at something 6 m away for 20 seconds."
            }
        }

        var symbol: String {
            switch self {
            case .water: return "drop.fill"
            case .stretch: return "figure.flexibility"
            case .eyes: return "eye.fill"
            }
        }

        /// What Ghost does when the reminder goes out.
        var mood: PetMood {
            switch self {
            case .water: return .drinking
            case .stretch: return .stretching
            case .eyes: return .listening
            }
        }
    }


    /// Seconds of keyboard time since each reminder last went out.
    private var active: [Kind: TimeInterval] = [:]
    private var lastTick = Date()

    /// An agent or a Ghost chat is running, a good moment to step away.
    var isAgentWorking: () -> Bool = { false }
    /// The user is mid-conversation with Ghost or an agent is waiting on them.
    var isBusy: () -> Bool = { false }
    var onDeliver: ((_ kinds: [Kind], _ agentWorking: Bool) -> Void)?

    private var settings: Config.Reminders { ConfigStore.shared.config.reminders }

    func isEnabled(_ kind: Kind) -> Bool { settings[keyPath: kind.configPath].enabled }

    func interval(_ kind: Kind) -> TimeInterval { settings[keyPath: kind.configPath].minutes * 60 }

    func tick(now: Date = Date()) {
        let elapsed = now.timeIntervalSince(lastTick)
        lastTick = now
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        // A long gap between ticks means the Mac was asleep.
        let breakReset = settings.idleResetMinutes * 60
        if idle >= breakReset || elapsed >= breakReset {
            active = [:]
            return
        }
        guard !settings.paused else { return }
        let kinds = Kind.allCases.filter(isEnabled)
        for kind in kinds { active[kind, default: 0] += elapsed }

        let working = isAgentWorking()
        let ready = kinds.filter { active[$0, default: 0] >= interval($0) * (working ? 0.75 : 1) }
        guard !ready.isEmpty, !isBusy() else { return }
        let batch = kinds.filter { active[$0, default: 0] >= interval($0) * 0.75 }
        for kind in batch { active[kind] = 0 }
        onDeliver?(batch, working)
    }

    func snooze(_ kinds: [Kind]) {
        for kind in kinds { active[kind] = max(0, interval(kind) - settings.snoozeMinutes * 60) }
    }

    func menuItem() -> NSMenuItem {
        let submenu = NSMenu()
        for kind in Kind.allCases {
            let item = NSMenuItem(title: "\(kind.name) (\(Int(settings[keyPath: kind.configPath].minutes)) min)", action: #selector(toggleKind(_:)), keyEquivalent: "")
            item.representedObject = kind.rawValue
            item.state = isEnabled(kind) ? .on : .off
            item.target = self
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let pause = NSMenuItem(title: "Pause reminders", action: #selector(togglePause), keyEquivalent: "")
        pause.state = settings.paused ? .on : .off
        pause.target = self
        submenu.addItem(pause)
        let item = NSMenuItem(title: "Reminders", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func toggleKind(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = Kind(rawValue: raw) else { return }
        ConfigStore.shared.update { $0.reminders[keyPath: kind.configPath].enabled.toggle() }
        active[kind] = 0
    }

    @objc private func togglePause() {
        ConfigStore.shared.update { $0.reminders.paused.toggle() }
        active = [:]
    }
}
