import XCTest
@testable import IronPet

final class ActivityLogTests: XCTestCase {
    private var dir: URL!
    private let start = Date(timeIntervalSince1970: 1_774_008_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func memoryLog(now: @escaping () -> Date = Date.init) throws -> ActivityLog {
        ActivityLog(database: try Database(path: nil, migrations: AppMigrations.all), now: now)
    }

    // MARK: Storage

    func testMigrationAddsTheTableToAFileFromTheVersionBefore() throws {
        let file = dir.appendingPathComponent("ironpet.db")
        let before = AppMigrations.all.filter { $0.version < 400 }
        XCTAssertEqual(try Database(path: file, migrations: before).schemaVersion, before.map(\.version).max())
        let database = try Database(path: file, migrations: AppMigrations.all)
        XCTAssertEqual(database.schemaVersion, 400)
        let log = ActivityLog(database: database)
        log.record(ActivityEvent(at: Date(), kind: .sessionDone, ref: "claude:1", title: "demo-app"))
        XCTAssertEqual(log.events(in: DateInterval(start: Date().addingTimeInterval(-60), duration: 120)).count, 1)
    }

    func testRecordedEventsReadBackInTheirWindowWithEveryField() throws {
        let log = try memoryLog()
        let url = URL(string: "https://github.com/irtaza/ironpet/pull/84")!
        log.record(ActivityEvent(at: start, kind: .alertOpened, ref: "a", title: "Fix login", detail: "irtaza/ironpet #84", url: url,
                                 extra: ["label": "CI failed", "mood": "failed"]))
        log.record(ActivityEvent(at: start.addingTimeInterval(60), kind: .sessionDone, ref: "s", title: "demo-app"))
        log.record(ActivityEvent(at: start.addingTimeInterval(120), kind: .init("task.handoff.done"), ref: "t", title: "Later kind"))

        let all = log.events(in: DateInterval(start: start, duration: 121))
        XCTAssertEqual(all.map(\.ref), ["a", "s", "t"])
        XCTAssertEqual(all[0], ActivityEvent(at: start, kind: .alertOpened, ref: "a", title: "Fix login", detail: "irtaza/ironpet #84", url: url,
                                             extra: ["label": "CI failed", "mood": "failed"]))
        XCTAssertEqual(all[2].kind.rawValue, "task.handoff.done")
        XCTAssertEqual(log.events(in: DateInterval(start: start, duration: 120)).map(\.ref), ["a", "s"], "the end is not included")
        XCTAssertEqual(log.events(in: DateInterval(start: start.addingTimeInterval(1), duration: 300)).map(\.ref), ["s", "t"])
        XCTAssertEqual(log.events(in: DateInterval(start: start, duration: 300), kinds: [.sessionDone]).map(\.ref), ["s"])
    }

    func testDetailIsCutAtThreeHundredCharacters() throws {
        let log = try memoryLog()
        log.record(ActivityEvent(at: start, kind: .automationBubble, ref: "x", title: "Long", detail: String(repeating: "a", count: 500)))
        let detail = try XCTUnwrap(log.events(in: DateInterval(start: start, duration: 1)).first?.detail)
        XCTAssertEqual(detail.count, ActivityEvent.detailLimit)
        XCTAssertTrue(detail.hasSuffix("…"))
    }

    func testPruneDropsOnlyEventsOlderThanThirtyDays() throws {
        var now = start
        let log = try memoryLog(now: { now })
        log.record(ActivityEvent(at: start.addingTimeInterval(-31 * 86_400), kind: .sessionDone, ref: "old", title: "old"))
        log.record(ActivityEvent(at: start.addingTimeInterval(-29 * 86_400), kind: .sessionDone, ref: "recent", title: "recent"))
        log.prune()
        let everything = DateInterval(start: start.addingTimeInterval(-40 * 86_400), end: start)
        XCTAssertEqual(log.events(in: everything).map(\.ref), ["recent"])
        now = start.addingTimeInterval(2 * 86_400)
        log.prune()
        XCTAssertEqual(log.events(in: everything).map(\.ref), [])
    }

    func testAnUnavailableDatabaseSaysWhyAndStillAnswers() throws {
        let blocker = dir.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: blocker)
        let database = Database.open(path: blocker.appendingPathComponent("ironpet.db"), migrations: AppMigrations.all).database
        let log = ActivityLog(database: database)
        XCTAssertNotNil(log.unavailable)
        log.record(ActivityEvent(at: start, kind: .sessionDone, ref: "s", title: "demo-app"))
        XCTAssertEqual(log.events(in: DateInterval(start: start, duration: 1)).count, 1, "kept in memory for this run")
    }

    // MARK: Events from announcements

    func testSessionEventsCarryWhatItTakesToReopenThem() throws {
        var session = AgentSession(id: "claude:abc", source: .claude)
        session.origin = SessionOrigin(workspace: "/Users/me/demo-app", termProgram: "iTerm.app", itermSessionID: "w0t0p0:XYZ", pid: 1,
                                       ownerBundleID: "com.googlecode.iterm2")
        session.lastResponse = "Fixed the flaky login test. Then more."
        session.editedFiles = ["/a.swift", "/b.swift"]
        session.status = .done
        let done = try XCTUnwrap(ActivityEvent.session(session, at: start))
        XCTAssertEqual(done.kind, .sessionDone)
        XCTAssertEqual(done.ref, "claude:abc")
        XCTAssertEqual(done.title, "demo-app")
        XCTAssertEqual(done.detail, "Edited 2 files · Fixed the flaky login test.")
        XCTAssertEqual(done.extra, ["workspace": "/Users/me/demo-app", "agent": "claude", "app": "com.googlecode.iterm2", "iterm": "w0t0p0:XYZ"])

        session.status = .failed
        XCTAssertEqual(ActivityEvent.session(session)?.kind, .sessionFailed)
        session.status = .needsInput
        session.detail = "Wants to use Bash"
        XCTAssertEqual(ActivityEvent.session(session)?.detail, "Wants to use Bash")
        session.status = .running
        XCTAssertNil(ActivityEvent.session(session))
    }

    func testSessionSummaryIsCappedAtOneHundredFortyCharacters() throws {
        var session = AgentSession(id: "cursor:1", source: .cursor)
        session.status = .done
        session.lastResponse = String(repeating: "word ", count: 60)
        session.editedFiles = ["/a.swift", "/b.swift"]
        XCTAssertEqual(try XCTUnwrap(ActivityEvent.session(session)).detail.count, ActivityEvent.summaryLimit)
        session.status = .needsInput
        session.detail = String(repeating: "word ", count: 60)
        XCTAssertEqual(try XCTUnwrap(ActivityEvent.session(session)).detail.count, ActivityEvent.summaryLimit)
    }

    func testTheUsersPromptNeverLandsInTheLog() throws {
        let log = ActivityLog(database: try Database(path: nil, migrations: AppMigrations.all), now: { self.start })
        var session = AgentSession(id: "claude:secret", source: .claude)
        session.prompt = "my private prompt"
        for status in [AgentStatus.done, .failed, .needsInput] {
            session.status = status
            let event = try XCTUnwrap(ActivityEvent.session(session, at: start))
            XCTAssertEqual(event.detail, "", "\(status) with no summary or request stores nothing")
            log.record(event)
        }
        let stored = log.events(in: DateInterval(start: start, duration: 1))
        XCTAssertEqual(stored.count, 3)
        XCTAssertFalse(stored.contains { $0.title.contains("private") || $0.detail.contains("private") || $0.extra.values.contains { $0.contains("private") } })
    }

    func testAlertEventsKeepTitleUrlAndMood() {
        let signal = Signal(id: "automation:github-alerts:pr1:ci", title: "Fix login", subtitle: "irtaza/ironpet #84",
                            url: URL(string: "https://github.com/irtaza/ironpet/pull/84"), label: "CI failed", symbol: "xmark.octagon.fill", mood: .failed)
        let opened = ActivityEvent.alertOpened(signal, at: start)
        XCTAssertEqual(opened.kind, .alertOpened)
        XCTAssertEqual(opened.ref, signal.id)
        XCTAssertEqual(opened.title, "Fix login")
        XCTAssertEqual(opened.detail, "irtaza/ironpet #84")
        XCTAssertEqual(opened.url, signal.url)
        XCTAssertEqual(opened.extra, ["label": "CI failed", "mood": "failed", "symbol": "xmark.octagon.fill"])
        XCTAssertEqual(ActivityEvent.alertResolved(signal).kind, .alertResolved)
    }

    func testAutomationBubblesSkipRemindersQuestionsAndNoticesWithoutAnAutomation() throws {
        let url = URL(string: "https://example.com/pr/1")!
        let news = AutomationNotice(id: "automation:github-alerts:1234", symbol: "checkmark.seal.fill", tint: .good, title: "CI passed",
                                    body: "Fix login\nirtaza/ironpet #84", expires: 15, automationIDs: ["github-alerts"], url: url)
        let event = try XCTUnwrap(ActivityEvent.automationNotice(news, at: start))
        XCTAssertEqual(event.kind, .automationBubble)
        XCTAssertEqual(event.title, "CI passed")
        XCTAssertEqual(event.url, url)
        XCTAssertEqual(event.extra, ["automation": "github-alerts", "tint": "good"])

        var reminder = news
        reminder.isBreakReminder = true
        XCTAssertNil(ActivityEvent.automationNotice(reminder))
        var question = news
        question.expires = nil
        XCTAssertNil(ActivityEvent.automationNotice(question))
        var orphan = news
        orphan.automationIDs = []
        XCTAssertNil(ActivityEvent.automationNotice(orphan))
    }

    func testOnlyBubblesOnKeyboardTimeAreBreakReminders() {
        func automation(_ trigger: Automation.Trigger, _ action: String) -> Automation {
            Automation(id: "a", name: "a", trigger: trigger, action: Automation.Action(type: action))
        }
        let keyboard = Automation.Trigger(type: "interval", minutes: 45)
        var active = keyboard
        active.clock = "active"
        var wall = keyboard
        wall.clock = "wall"
        XCTAssertTrue(automation(keyboard, "bubble").isBreakReminder, "drink water")
        XCTAssertTrue(automation(active, "bubble").isBreakReminder)
        XCTAssertFalse(automation(wall, "bubble").isBreakReminder, "an hourly bubble on the clock is news")
        XCTAssertFalse(automation(keyboard, "shell").isBreakReminder, "a job on keyboard time is not dropped")
        XCTAssertFalse(automation(keyboard, "prompt").isBreakReminder)
        XCTAssertFalse(automation(Automation.Trigger(type: "poll", minutes: 5), "bubble").isBreakReminder)
        XCTAssertTrue(keyboard.countsKeyboardTime)
        XCTAssertFalse(wall.countsKeyboardTime)
    }

    func testTaskMeetingAndChatEvents() {
        let suggestion = TaskSuggestion(id: "send-invoice", title: "Send the invoice", origin: .automation(id: "mail", name: "Mail watcher"), created: start)
        XCTAssertEqual(ActivityEvent.taskSuggested(suggestion).ref, "send-invoice")
        XCTAssertEqual(ActivityEvent.taskSuggested(suggestion).detail, "From Mail watcher")
        let task = TaskItem(id: "renew", title: "Renew the domain", notes: "", status: .backlog, source: .chat, due: start, links: [],
                            created: start, updated: start, closed: nil)
        XCTAssertEqual(ActivityEvent.taskDue(task).ref, "renew")
        XCTAssertNotNil(ActivityEvent.taskDue(task).extra["due"])
        let summary = URL(fileURLWithPath: "/Users/me/.ironpet/meetings/2026-11-17 10-00 Standup/summary.md")
        let meeting = ActivityEvent.meetingSummary(summary)
        XCTAssertEqual(meeting.title, "2026-11-17 10-00 Standup")
        XCTAssertEqual(meeting.url, summary)
        XCTAssertEqual(ActivityEvent.chatFinished("Ghost finished your task").title, "Ghost finished your task")
    }
}
