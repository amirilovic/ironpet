import Foundation

/// One thing ironpet saw happen or told the user about, as stored in `activity_events`: an agent turn that finished, an
/// alert that opened or that its watcher cleared, a bubble from an automation. The welcome back summary and the daily
/// brief read these back for a time window, so they can say what happened while nobody was looking or after a restart.
struct ActivityEvent: Equatable {
    /// Open-ended on purpose: a feature can record its own kind (`task.handoff.done`) without changing this file, and
    /// readers ignore kinds they do not know.
    struct Kind: RawRepresentable, Hashable, Comparable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }
        init(_ rawValue: String) { self.rawValue = rawValue }

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        static let sessionNeedsInput = Kind("session.needsInput")
        static let sessionFailed = Kind("session.failed")
        static let sessionDone = Kind("session.done")
        static let alertOpened = Kind("alert.opened")
        /// Cleared by the automation that raised it, not dismissed by the user.
        static let alertResolved = Kind("alert.resolved")
        static let automationBubble = Kind("automation.bubble")
        static let taskSuggested = Kind("task.suggested")
        static let taskDue = Kind("task.due")
        static let meetingSummary = Kind("meeting.summary")
        static let chatFinished = Kind("chat.finished")

        var isSession: Bool { rawValue.hasPrefix("session.") }
    }

    static let detailLimit = 300
    static let summaryLimit = 140

    var at: Date
    var kind: Kind
    /// What the event is about, so readers can fold repeats: a session id, an alert id, a task id, a file path.
    var ref: String
    var title: String
    var detail: String
    var url: URL?
    /// Small string facts a reader may need later, such as how to reopen a session that has ended.
    var extra: [String: String]

    init(at: Date = Date(), kind: Kind, ref: String, title: String, detail: String = "", url: URL? = nil, extra: [String: String] = [:]) {
        self.at = at
        self.kind = kind
        self.ref = ref
        self.title = title
        self.detail = Self.clamp(detail, Self.detailLimit)
        self.url = url
        self.extra = extra
    }

    static func clamp(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

// MARK: From what the app announces

extension ActivityEvent {
    /// Extra keys for a session, enough to jump to it after the session store has forgotten it.
    enum SessionKey {
        static let workspace = "workspace", agent = "agent", app = "app", iterm = "iterm"
    }

    /// An agent session that started needing input, failed or finished. Nil for any other status.
    static func session(_ session: AgentSession, at: Date = Date()) -> ActivityEvent? {
        let kind: Kind
        switch session.status {
        case .needsInput: kind = .sessionNeedsInput
        case .failed: kind = .sessionFailed
        case .done: kind = .sessionDone
        default: return nil
        }
        var extra = [SessionKey.agent: session.source.rawValue]
        extra[SessionKey.workspace] = session.origin.workspace
        extra[SessionKey.app] = session.origin.ownerBundleID
        extra[SessionKey.iterm] = session.isInIterm ? session.origin.itermSessionID : nil
        let detail = session.status == .needsInput ? (session.detail ?? session.prompt) : (session.summary ?? session.prompt)
        return ActivityEvent(at: at, kind: kind, ref: session.id, title: session.workspaceName,
                             detail: clamp(detail ?? "", summaryLimit), extra: extra)
    }

    enum AlertKey {
        static let label = "label", mood = "mood", symbol = "symbol"
    }

    /// An alert the user was told about: new, or changed since it was last shown.
    static func alertOpened(_ signal: Signal, at: Date = Date()) -> ActivityEvent {
        alert(signal, kind: .alertOpened, at: at)
    }

    /// An alert its automation cleared. Read the signal before it leaves the store, since the row has the title and url.
    static func alertResolved(_ signal: Signal, at: Date = Date()) -> ActivityEvent {
        alert(signal, kind: .alertResolved, at: at)
    }

    private static func alert(_ signal: Signal, kind: Kind, at: Date) -> ActivityEvent {
        ActivityEvent(at: at, kind: kind, ref: signal.id, title: signal.title, detail: signal.subtitle, url: signal.url,
                      extra: [AlertKey.label: signal.label, AlertKey.mood: signal.mood.rawValue, AlertKey.symbol: signal.symbol])
    }

    enum AutomationKey {
        static let automation = "automation", tint = "tint"
    }

    /// A bubble from a scheduled job, poll or script. Nil for what is not news after a break: break reminders (`isReminder`),
    /// questions that wait for an answer (no expiry) and bubbles that belong to no automation.
    static func automationNotice(_ notice: AutomationNotice, isReminder: Bool, at: Date = Date()) -> ActivityEvent? {
        guard !isReminder, notice.expires != nil, let automation = notice.automationIDs.first else { return nil }
        let tint: String
        switch notice.tint {
        case .info: tint = "info"
        case .good: tint = "good"
        case .bad: tint = "bad"
        case .warn: tint = "warn"
        }
        return ActivityEvent(at: at, kind: .automationBubble, ref: notice.id, title: notice.title,
                             detail: clamp(notice.body ?? notice.subtitle ?? "", 200), url: notice.url,
                             extra: [AutomationKey.automation: automation, AutomationKey.tint: tint])
    }

    static func taskSuggested(_ suggestion: TaskSuggestion, at: Date = Date()) -> ActivityEvent {
        ActivityEvent(at: at, kind: .taskSuggested, ref: suggestion.id, title: suggestion.title, detail: suggestion.originLabel)
    }

    static func taskDue(_ task: TaskItem, at: Date = Date()) -> ActivityEvent {
        ActivityEvent(at: at, kind: .taskDue, ref: task.id, title: task.title,
                      extra: task.due.map { ["due": ISO8601DateFormatter().string(from: $0)] } ?? [:])
    }

    static func meetingSummary(_ summary: URL, at: Date = Date()) -> ActivityEvent {
        ActivityEvent(at: at, kind: .meetingSummary, ref: summary.path, title: summary.deletingLastPathComponent().lastPathComponent, url: summary)
    }

    /// A Ghost chat turn that ended while the chat was hidden. `title` is what the bubble said.
    static func chatFinished(_ title: String, at: Date = Date()) -> ActivityEvent {
        ActivityEvent(at: at, kind: .chatFinished, ref: "chat", title: title)
    }
}
