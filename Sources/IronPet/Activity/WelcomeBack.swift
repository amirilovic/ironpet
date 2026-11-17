import CoreGraphics
import Foundation

/// When the user comes back after being away, sums up what happened meanwhile in one bubble and folds away the short-lived
/// bubbles it covers. Reads only the activity log and the live stores; nothing runs or leaves the Mac.
@MainActor
final class WelcomeBack {
    struct Environment {
        var now: () -> Date = { Date() }
        /// Seconds since the last keyboard or mouse event, the same source as the automation clock.
        var idleSeconds: () -> TimeInterval = {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        }
        var isScreenLocked: () -> Bool = {
            (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        }
        /// A meeting is being recorded or a call is on: the user is at the Mac even without typing.
        var isPresent: () -> Bool = { false }
        var isEnabled: () -> Bool = { true }
        /// How long without input counts as away. The app passes `reminders.idleResetMinutes`.
        var threshold: () -> TimeInterval = { 5 * 60 }
    }

    static let bubbleID = "welcome-back"
    /// The daily brief's bubbles. A brief already says what is going on, so a summary right after it would repeat it.
    static let digestPrefix = "digest:"
    static let digestQuiet: TimeInterval = 30 * 60

    var env: Environment
    /// What is true now, so items the user already dealt with drop out.
    var live: () -> ActivityDigest.LiveState = { .init() }
    /// Shows the summary: the digest and how long the user was away.
    var show: (_ digest: ActivityDigest, _ away: TimeInterval) -> Void = { _, _ in }

    private let log: ActivityLog
    let bubbles: BubbleStore
    private(set) var tracker = AwayTracker()
    /// A return seen while the screen was still locked, shown once it unlocks.
    private(set) var pendingSince: Date?
    private(set) var lastDigest: ActivityDigest?

    init(log: ActivityLog, bubbles: BubbleStore, env: Environment = Environment()) {
        self.log = log
        self.bubbles = bubbles
        self.env = env
    }

    /// Call every couple of seconds.
    func tick() {
        let now = env.now()
        let transition = tracker.sample(now: now, idleSeconds: env.idleSeconds(), threshold: env.threshold(), present: env.isPresent())
        if case .returned(let since, _) = transition { pendingSince = min(pendingSince ?? since, since) }
        guard let since = pendingSince, !env.isScreenLocked() else { return }
        pendingSince = nil
        summarize(DateInterval(start: since, end: max(since, now)))
    }

    /// Builds the summary of `window` and shows it, unless there is nothing to say or it would only repeat what is on screen.
    func summarize(_ window: DateInterval) {
        guard env.isEnabled() else { return }
        let now = env.now()
        if bubbles.bubbles.contains(where: { $0.id.hasPrefix(Self.digestPrefix) })
            || bubbles.lastShown(prefix: Self.digestPrefix).map({ now.timeIntervalSince($0) < Self.digestQuiet }) == true { return }
        let events = log.events(in: window)
        var state = live()
        // A task due bubble waits for Done or Snooze, so it keeps its own place.
        if bubbles.bubbles.contains(where: { $0.id == Announcer.tasksDueID }) { state.excluded.insert(.taskDue) }
        let digest = ActivityDigest.build(events: events, window: window, live: state)
        lastDigest = digest
        guard !digest.isEmpty else { return }
        if digest.count == 1, let only = digest.items.first?.events.first,
           bubbles.bubbles.contains(where: { $0.id == Self.bubbleID(for: only) }) { return }
        let covered = Set(events.map(Self.bubbleID(for:)))
        for bubble in bubbles.bubbles where bubble.expires != nil && covered.contains(bubble.id)
            && (bubbles.shownAt[bubble.id] ?? .distantPast) >= window.start {
            bubbles.dismiss(bubble.id)
        }
        show(digest, window.duration)
    }

    /// The bubble the app showed for an event, by the ids `Announcer` and the automation service use.
    static func bubbleID(for event: ActivityEvent) -> String {
        switch event.kind {
        case .sessionNeedsInput, .sessionFailed, .sessionDone: return "session:\(event.ref)"
        case .alertOpened: return "signal:\(event.ref)"
        case .taskSuggested: return "task-suggestions"
        case .taskDue: return Announcer.tasksDueID
        case .meetingSummary: return "meeting-summary"
        case .chatFinished: return "chat"
        default: return event.ref
        }
    }

    /// The live state from the app's stores at `now`.
    static func liveState(sessions: [AgentSession], signals: [Signal], tasks: [TaskItem], suggestions: [TaskSuggestion], now: Date) -> ActivityDigest.LiveState {
        var sessionKinds: [String: ActivityEvent.Kind] = [:]
        for session in sessions {
            switch session.status {
            case .needsInput: sessionKinds[session.id] = .sessionNeedsInput
            case .failed: sessionKinds[session.id] = .sessionFailed
            case .done: sessionKinds[session.id] = .sessionDone
            default: break
            }
        }
        return ActivityDigest.LiveState(sessions: sessionKinds, openAlerts: Set(signals.map(\.id)),
                                        waitingSuggestions: Set(suggestions.map(\.id)),
                                        dueTasks: Set(tasks.filter { TaskDue.hasCome($0, now: now) }.map(\.id)))
    }
}
