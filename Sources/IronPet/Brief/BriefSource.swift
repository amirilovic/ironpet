import Combine
import Foundation

/// Gathers a brief's input from the app's stores and `~/.ironpet/meetings`, and builds it.
@MainActor
final class BriefSource {
    private let tasks: TaskStore
    private let sessions: SessionStore
    private let signals: SignalStore
    private let meetingsRoot: URL
    /// What happened today: the activity log. Without it (no database yet, previews) the recap's agent turns come from the
    /// sessions still in the store.
    var activity: BriefActivitySource?
    var now: () -> Date = Date.init
    var calendar: Calendar = .autoupdatingCurrent
    /// Each summary's open action items, keyed by folder, kept until the file changes.
    private var summaries: [String: (modified: Date, items: [String])] = [:]

    init(tasks: TaskStore, sessions: SessionStore, signals: SignalStore, meetingsRoot: URL = Paths.meetings,
         activity: BriefActivitySource? = nil) {
        self.tasks = tasks
        self.sessions = sessions
        self.signals = signals
        self.meetingsRoot = meetingsRoot
        self.activity = activity
    }

    /// Fires when anything the brief reads may have changed.
    var changes: AnyPublisher<Void, Never> {
        Publishers.Merge3(tasks.objectWillChange, sessions.objectWillChange, signals.objectWillChange).eraseToAnyPublisher()
    }

    /// `weekdays` are the brief trigger's, so Monday's brief reaches back to Friday's meetings. `day` is the recap's day,
    /// today when nil.
    func build(_ kind: Brief.Kind, weekdays: [String]? = nil, day: Date? = nil) -> Brief {
        let now = now()
        let since = BriefBuilder.meetingsSince(weekdays: weekdays, now: now, calendar: calendar)
        let today = DateInterval(start: min(calendar.startOfDay(for: day ?? now), now), end: now)
        let live = Array(sessions.sessions.values)
        let input = BriefInput(now: now, calendar: calendar, day: day, tasks: tasks.tasks, sessions: live, alerts: signals.signals,
                               meetings: meetings(since: min(since, today.start), until: now),
                               activity: activity?.briefActivity(in: today) ?? Self.finishedSessions(live, in: today))
        return BriefBuilder.build(kind, input, meetingsSince: since)
    }

    /// The done and failed sessions the store still holds, as recap activity. Turns that ended earlier and were dismissed
    /// are missing; the activity log keeps those.
    nonisolated static func finishedSessions(_ sessions: [AgentSession], in window: DateInterval) -> [BriefActivity] {
        sessions.filter { ($0.status == .done || $0.status == .failed) && window.contains($0.updatedAt) }.map { s in
            BriefActivity(kind: s.status == .failed ? .sessionFailed : .sessionDone, at: s.updatedAt, ref: s.id,
                          title: s.workspaceName, detail: s.summary, agent: s.source.displayName,
                          workspace: s.origin.workspace, bundleID: s.origin.ownerBundleID)
        }
    }

    private func meetings(since: Date, until: Date) -> [BriefMeeting] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: meetingsRoot, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> BriefMeeting? in
            guard let date = MeetingLibrary.date(folderName: folder.lastPathComponent), date >= since, date <= until,
                  let record = MeetingLibrary.record(folder) else { return nil }
            return BriefMeeting(id: record.id, date: date, preview: record.preview,
                                openItems: record.hasSummary ? openItems(record) : [])
        }
    }

    private func openItems(_ record: MeetingRecord) -> [String] {
        let modified = (try? record.summaryURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let cached = summaries[record.id], cached.modified == modified { return cached.items }
        let text = (try? String(contentsOf: record.summaryURL, encoding: .utf8)) ?? ""
        let items = ActionItems.openItems(text).map(\.title)
        summaries[record.id] = (modified, items)
        return items
    }
}

/// The recap's turns and resolved alerts, from the shared activity log, which outlives the sessions in memory and a restart.
extension ActivityLog: BriefActivitySource {
    func briefActivity(in window: DateInterval) -> [BriefActivity] {
        events(in: window, kinds: [.sessionDone, .sessionFailed, .alertResolved]).compactMap(BriefActivity.init)
    }
}

extension BriefActivity {
    init?(_ event: ActivityEvent) {
        typealias Session = ActivityEvent.SessionKey
        switch event.kind {
        case .sessionDone, .sessionFailed:
            let agent = event.extra[Session.agent]
            self.init(kind: event.kind == .sessionFailed ? .sessionFailed : .sessionDone, at: event.at, ref: event.ref,
                      title: event.title, detail: event.detail.isEmpty ? nil : event.detail,
                      agent: agent.map { AgentSource(rawValue: $0)?.displayName ?? $0 },
                      workspace: event.extra[Session.workspace], bundleID: event.extra[Session.app], iterm: event.extra[Session.iterm])
        case .alertResolved:
            self.init(kind: .alertResolved, at: event.at, ref: event.ref, title: event.title,
                      detail: event.extra[ActivityEvent.AlertKey.label], agent: nil, workspace: nil, bundleID: nil)
        default:
            return nil
        }
    }
}

/// The Today page's content. Rebuilt when the page appears and, while it is on screen, when the stores change.
@MainActor
final class BriefModel: ObservableObject {
    @Published private(set) var briefs: [Brief.Kind: Brief] = [:]
    private let source: BriefSource?
    /// The brief automation's weekdays.
    var weekdays: () -> [String]? = { nil }
    private var visible = false
    private var cancellable: AnyCancellable?

    init(source: BriefSource) {
        self.source = source
        cancellable = source.changes
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self, visible else { return }
                refresh()
            }
    }

    /// Fixed content for previews and tests.
    init(briefs: [Brief]) {
        source = nil
        self.briefs = Dictionary(briefs.map { ($0.kind, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// The day the recap shows, from the bubble that opened the page, so a recap caught up after midnight still opens on
    /// its day. Nil is today. Cleared when the user picks a kind on the page, leaves Today, or the window closes or
    /// minimizes (`PetController` calls `setVisible(false)` from the panel's visibility change).
    private(set) var recapDay: Date?

    func refresh() {
        guard let source else { return }
        let weekdays = weekdays()
        briefs = Dictionary(uniqueKeysWithValues: Brief.Kind.allCases.map {
            ($0, source.build($0, weekdays: weekdays, day: $0 == .recap ? recapDay : nil))
        })
    }

    func show(recapDay: Date?) {
        self.recapDay = recapDay
        if visible { refresh() }
    }

    /// The user picked a kind on the page, so the recap goes back to today.
    func picked() {
        guard recapDay != nil else { return }
        show(recapDay: nil)
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        if visible { refresh() } else { recapDay = nil }
    }
}
