import Foundation

/// What happened in a time window, grouped for a summary: one item per kind of event, most urgent first, with the
/// place each item opens. Built from activity log events alone, so it works for any window, including a past day.
/// The welcome back summary also passes the live state, so items the user already dealt with drop out.
struct ActivityDigest: Equatable {
    /// Where clicking an item goes.
    enum Target: Equatable {
        case session(id: String, workspace: String?, app: String?, iterm: String?)
        case agents
        case url(URL)
        case alerts
        case tasks
        case file(URL)
        case chat
        case automations
    }

    struct Item: Equatable {
        var kind: ActivityEvent.Kind
        /// One event per ref, the latest for that ref, newest first.
        var events: [ActivityEvent]

        var count: Int { events.count }

        /// Something that wants the user now: an agent waiting or failed, or a failing alert.
        var isUrgent: Bool {
            switch kind {
            case .sessionNeedsInput, .sessionFailed: return true
            case .alertOpened: return events.contains { $0.extra[ActivityEvent.AlertKey.mood] == PetMood.failed.rawValue }
            default: return false
            }
        }

        /// One event opens what it is about; several open the list they are in. Nil for a kind this type does not know
        /// and that has nothing to open.
        var target: Target? {
            let single = events.count == 1 ? events.first : nil
            switch kind {
            case .sessionNeedsInput, .sessionFailed, .sessionDone:
                guard let event = single else { return .agents }
                typealias Key = ActivityEvent.SessionKey
                return .session(id: event.ref, workspace: event.extra[Key.workspace], app: event.extra[Key.app], iterm: event.extra[Key.iterm])
            case .alertOpened, .alertResolved:
                return single?.url.map(Target.url) ?? .alerts
            case .taskSuggested, .taskDue:
                return .tasks
            case .meetingSummary:
                return single?.url.map(Target.file) ?? nil
            case .chatFinished:
                return .chat
            case .automationBubble:
                return single?.url.map(Target.url) ?? .automations
            default:
                return single?.url.map(Target.url)
            }
        }
    }

    /// What is true now, at the end of the window. Each set holds refs.
    struct LiveState: Equatable {
        /// Session id to the kind of its current status (`session.done` for a session that is still done).
        var sessions: [String: ActivityEvent.Kind] = [:]
        /// Sessions the store turned idle after a long time without events, with the time of their last event. One that
        /// needed input and heard nothing since is still waiting; one that was answered has a later last event.
        var idleSince: [String: Date] = [:]
        var openAlerts: Set<String> = []
        var waitingSuggestions: Set<String> = []
        /// Open tasks that are due now or overdue.
        var dueTasks: Set<String> = []
        /// Kinds the caller shows some other way, such as the task due bubble that is still on screen.
        var excluded: Set<ActivityEvent.Kind> = []
    }

    var window: DateInterval
    var items: [Item]

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.reduce(0) { $0 + $1.count } }

    /// Most urgent first. Kinds not listed come after these, in name order.
    static let order: [ActivityEvent.Kind] = [
        .sessionNeedsInput, .sessionFailed, .alertOpened, .sessionDone, .taskDue, .taskSuggested, .meetingSummary,
        .chatFinished, .automationBubble, .alertResolved,
    ]

    /// Groups the events of `window` by kind, keeps the latest event for each ref, and with `live` drops what is no longer
    /// so: a session that was acknowledged or moved on, an alert that closed, a suggestion added or skipped, a task done.
    static func build(events: [ActivityEvent], window: DateInterval, live: LiveState? = nil) -> ActivityDigest {
        var latest: [ActivityEvent.Kind: [String: ActivityEvent]] = [:]
        for event in events where event.at >= window.start && event.at < window.end {
            if let kept = latest[event.kind]?[event.ref], kept.at > event.at { continue }
            latest[event.kind, default: [:]][event.ref] = event
        }
        var items: [Item] = []
        for (kind, byRef) in latest {
            if let live, live.excluded.contains(kind) { continue }
            let kept = byRef.values.filter { event in live.map { isCurrent(event, in: $0) } ?? true }
            guard !kept.isEmpty else { continue }
            items.append(Item(kind: kind, events: kept.sorted { ($0.at, $0.ref) > ($1.at, $1.ref) }))
        }
        items.sort { rank($0.kind) != rank($1.kind) ? rank($0.kind) < rank($1.kind) : $0.kind < $1.kind }
        return ActivityDigest(window: window, items: items)
    }

    private static func rank(_ kind: ActivityEvent.Kind) -> Int {
        order.firstIndex(of: kind) ?? order.count
    }

    private static func isCurrent(_ event: ActivityEvent, in live: LiveState) -> Bool {
        if event.kind == .sessionNeedsInput, live.sessions[event.ref] == nil,
           let lastEvent = live.idleSince[event.ref] {
            // The needs-input event is recorded just after the session's last event; the slack covers the stored time's rounding.
            return lastEvent <= event.at.addingTimeInterval(1)
        }
        if event.kind.isSession { return live.sessions[event.ref] == event.kind }
        switch event.kind {
        case .alertOpened: return live.openAlerts.contains(event.ref)
        case .taskSuggested: return live.waitingSuggestions.contains(event.ref)
        case .taskDue: return live.dueTasks.contains(event.ref)
        default: return true
        }
    }
}
