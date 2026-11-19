import Combine
import Foundation

struct BriefRequest: Codable, Equatable {
    var kind: Brief.Kind
    /// The weekdays the brief runs on, so Monday's brief reaches back to Friday's meetings.
    var weekdays: [String]?
    /// The recap's day. Nil is today.
    var day: Date?
}

/// The morning brief and the day's recap, built from tasks, agent sessions, alerts and meetings.
@MainActor
final class TodayAPI {
    private let source: BriefSource

    init(tasks: TasksAPI, sessions: SessionStore, signals: SignalStore, meetingsRoot: URL = Paths.meetings) {
        source = BriefSource(tasks: tasks, sessions: sessions, signals: signals, meetingsRoot: meetingsRoot)
    }

    /// Wraps a source built elsewhere, for previews and tests.
    init(source: BriefSource) { self.source = source }

    /// What happened today, from the activity log. Without it the recap's agent turns come from the sessions still held.
    var activity: BriefActivitySource? {
        get { source.activity }
        set { source.activity = newValue }
    }
    var now: () -> Date {
        get { source.now }
        set { source.now = newValue }
    }
    var calendar: Calendar {
        get { source.calendar }
        set { source.calendar = newValue }
    }

    /// Fires when anything a brief reads may have changed.
    var changes: AnyPublisher<Void, Never> { source.changes }

    func brief(_ request: BriefRequest) -> Brief { source.build(request.kind, weekdays: request.weekdays, day: request.day) }
}
