import XCTest
@testable import IronPet

@MainActor
final class TaskDueTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        return c
    }()
    private var database: Database!
    private var store: TaskStore!
    private var reminders: TaskDueReminders!
    private var clock = Date()
    private var settings = TaskDueReminders.Settings(enabled: true, paused: false)
    private var shown: [(ids: [String], isNew: Bool)] = []
    private var showing = false
    private var hidden = 0

    /// 2026-11-16 14:00 in Helsinki.
    private var start: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 14))! }

    override func setUp() async throws {
        database = Database.open(path: nil, migrations: AppMigrations.all).database
        clock = start
        settings = .init(enabled: true, paused: false)
        shown = []
        showing = false
        hidden = 0
        store = TaskStore(database: database, now: { [unowned self] in clock }, keepDoneDays: { 30 })
        reminders = makeReminders()
    }

    override func tearDown() async throws {
        reminders = nil
        store = nil
        database = nil
    }

    private func makeReminders() -> TaskDueReminders {
        let r = TaskDueReminders(store: store, now: { [unowned self] in clock }, calendar: calendar, settings: { [unowned self] in settings })
        r.show = { [unowned self] tasks, isNew in shown.append((tasks.map(\.id), isNew)); showing = true }
        r.hide = { [unowned self] in hidden += 1; showing = false }
        r.isShowing = { [unowned self] in showing }
        return r
    }

    private func day(_ offset: Int, hour: Int = 0, minute: Int = 0) -> Date {
        let first = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: start))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: first)!
    }

    private func task(_ id: String = "t", due: Date?, status: TaskStatus = .backlog) -> TaskItem {
        TaskItem(id: id, title: id, notes: "", status: status, source: .chat, due: due, links: [], created: start, updated: start, closed: nil)
    }

    @discardableResult
    private func add(_ title: String, due: Date?, status: TaskStatus = .backlog) throws -> TaskItem {
        try store.create(title: title, status: status, source: .chat, due: due, by: "agent:mcp")
    }

    // MARK: The rule

    func testDueTodayAndOverdueArePendingButFutureAndDoneAreNot() {
        let tasks = [task("today", due: day(0)), task("overdue", due: day(-2)), task("earlier", due: day(0, hour: 9)),
                     task("later", due: day(0, hour: 18)), task("tomorrow", due: day(1)), task("none", due: nil),
                     task("done", due: day(-1), status: .done)]
        XCTAssertEqual(TaskDue.pending(tasks, marks: [:], now: start).map(\.id), ["overdue", "today", "earlier"])
    }

    func testATaskWaitingOnSomeoneElseIsStillReminded() {
        var item = task(due: day(0))
        item.waitingOn = "Ana"
        XCTAssertEqual(TaskDue.pending([item], marks: [:], now: start).map(\.id), ["t"], "so the user can follow up")
    }

    func testATimeIsPendingOnceItPasses() {
        let item = task(due: day(0, hour: 14, minute: 30))
        XCTAssertTrue(TaskDue.pending([item], marks: [:], now: start).isEmpty)
        XCTAssertEqual(TaskDue.pending([item], marks: [:], now: start.addingTimeInterval(30 * 60)).map(\.id), ["t"])
    }

    func testAMarkHoldsOnlyItsOwnDueDate() {
        let item = task(due: day(-1))
        XCTAssertTrue(TaskDue.pending([item], marks: ["t": .init(due: day(-1))], now: start).isEmpty)
        XCTAssertEqual(TaskDue.pending([item], marks: ["t": .init(due: day(-3))], now: start).map(\.id), ["t"])
    }

    func testASnoozeHoldsUntilItEnds() {
        let item = task(due: day(-1))
        let marks = ["t": TaskDueMark(due: day(-1), snoozedUntil: start.addingTimeInterval(3600))]
        XCTAssertTrue(TaskDue.pending([item], marks: marks, now: start).isEmpty)
        XCTAssertEqual(TaskDue.pending([item], marks: marks, now: start.addingTimeInterval(3600)).map(\.id), ["t"])
    }

    func testKind() {
        XCTAssertEqual(TaskDue.kind(task(due: day(0)), now: start, calendar: calendar), .today)
        XCTAssertEqual(TaskDue.kind(task(due: day(-1)), now: start, calendar: calendar), .overdue)
        XCTAssertEqual(TaskDue.kind(task(due: day(0, hour: 13, minute: 30)), now: start, calendar: calendar), .now)
        XCTAssertEqual(TaskDue.kind(task(due: day(0, hour: 9)), now: start, calendar: calendar), .overdue)
    }

    func testSnoozeIsAnHourOrTomorrowMorningForPlainDates() {
        XCTAssertEqual(TaskDue.snoozeEnd(for: [task(due: day(0, hour: 13))], now: start, calendar: calendar), start.addingTimeInterval(3600))
        XCTAssertEqual(TaskDue.snoozeEnd(for: [task(due: day(0))], now: start, calendar: calendar), day(1, hour: 9))
        XCTAssertEqual(TaskDue.snoozeEnd(for: [task("a", due: day(0)), task("b", due: day(0, hour: 13))], now: start, calendar: calendar),
                       start.addingTimeInterval(3600))
    }

    // MARK: Reminders

    func testAnnouncesOncePerDueDate() throws {
        let item = try add("Send the deck", due: day(0))
        reminders.check()
        XCTAssertEqual(shown.map(\.ids), [[item.id]])
        XCTAssertTrue(shown[0].isNew)
        showing = false
        clock = start.addingTimeInterval(86_400)
        reminders.check()
        XCTAssertEqual(shown.count, 1, "overdue the next day is the same due date")

        try store.update(item.id, due: .some(day(1, hour: 10)), by: "agent:mcp")
        reminders.check()
        XCTAssertEqual(shown.map(\.ids), [[item.id], [item.id]], "a new due date is announced again")
    }

    func testSeveralDueTasksShareOneBubble() throws {
        let a = try add("Send the deck", due: day(-1))
        let b = try add("Call the bank", due: day(0))
        try add("Later", due: day(2))
        reminders.check()
        XCTAssertEqual(shown.map(\.ids), [[a.id, b.id]])

        clock = day(2, hour: 1)
        let c = try XCTUnwrap(store.task("later"))
        reminders.check()
        XCTAssertEqual(shown.last?.ids, [a.id, b.id, c.id], "a task that comes due joins the open bubble")
        XCTAssertEqual(shown.last?.isNew, true)
    }

    func testClosingATaskDropsItFromTheBubbleQuietly() throws {
        let a = try add("Send the deck", due: day(-1))
        let b = try add("Call the bank", due: day(0))
        reminders.check()
        try store.close(a.id, by: "agent:mcp")
        reminders.check()
        XCTAssertEqual(shown.last?.ids, [b.id])
        XCTAssertEqual(shown.last?.isNew, false)
        try store.close(b.id, by: "agent:mcp")
        reminders.check()
        XCTAssertEqual(hidden, 1)
        XCTAssertEqual(reminders.listed, [])
    }

    func testDoneClosesTheListedTasks() throws {
        let a = try add("Send the deck", due: day(-1))
        let b = try add("Call the bank", due: day(0))
        reminders.check()
        reminders.done([a.id, b.id])
        XCTAssertEqual(store.task(a.id)?.status, .done)
        XCTAssertEqual(store.task(b.id)?.status, .done)
        XCTAssertEqual(store.history(a.id).last?.by, "user")
        XCTAssertEqual(reminders.listed, [])
    }

    func testSnoozeAnnouncesAgainAfterAnHour() throws {
        let item = try add("Send the deck", due: day(0, hour: 13))
        reminders.check()
        reminders.snooze([item.id])
        showing = false
        clock = start.addingTimeInterval(59 * 60)
        reminders.check()
        XCTAssertEqual(shown.count, 1)
        clock = start.addingTimeInterval(60 * 60)
        reminders.check()
        XCTAssertEqual(shown.count, 2)
        clock = start.addingTimeInterval(3 * 3600)
        showing = false
        reminders.check()
        XCTAssertEqual(shown.count, 2, "once the snooze has been announced it is done")
    }

    func testAnnouncedAndSnoozedSurviveARelaunch() throws {
        let announced = try add("Send the deck", due: day(-1))
        let snoozed = try add("Call the bank", due: day(0))
        reminders.check()
        reminders.snooze([snoozed.id])
        XCTAssertEqual(store.dueMarks()[announced.id], TaskDueMark(due: day(-1)))

        store = TaskStore(database: database, now: { [unowned self] in clock }, keepDoneDays: { 30 })
        reminders = makeReminders()
        shown = []
        showing = false
        reminders.check()
        XCTAssertTrue(shown.isEmpty)
        clock = day(1, hour: 9)
        reminders.check()
        XCTAssertEqual(shown.map(\.ids), [[snoozed.id]])
    }

    func testSwitchOffAndPauseAnnounceNothing() throws {
        let item = try add("Send the deck", due: day(-1))
        settings.enabled = false
        reminders.check()
        settings = .init(enabled: true, paused: true)
        reminders.check()
        XCTAssertTrue(shown.isEmpty)
        XCTAssertTrue(store.dueMarks().isEmpty, "nothing counts as announced while off or paused")
        settings.paused = false
        reminders.check()
        XCTAssertEqual(shown.map(\.ids), [[item.id]])
        settings.enabled = false
        reminders.check()
        XCTAssertEqual(hidden, 1, "turning it off closes the bubble")
    }

    func testDeletingATaskForgetsItsMark() throws {
        let item = try add("Send the deck", due: day(-1))
        reminders.check()
        try store.delete(item.id, by: "user")
        XCTAssertNil(store.dueMarks()[item.id])
    }

    // MARK: Bubble

    func testBubbleText() {
        let noop = {}
        let one = Announcer.tasksDueBubble([task("Send the deck", due: day(0))], now: start, calendar: calendar,
                                           done: noop, snooze: noop, open: noop)
        XCTAssertEqual(one.title, "Due today: Send the deck")
        XCTAssertEqual(one.actions.map(\.title), ["Done", "Remind tomorrow", "Open"])
        XCTAssertNil(one.expires)

        let late = Announcer.tasksDueBubble([task("Send the deck", due: day(-1))], now: start, calendar: calendar,
                                            done: noop, snooze: noop, open: noop)
        XCTAssertEqual(late.title, "Overdue: Send the deck")
        XCTAssertEqual(late.subtitle, "Overdue since yesterday")

        let several = Announcer.tasksDueBubble((1...5).map { task("Task \($0)", due: day(0, hour: 13, minute: 30)) }, now: start,
                                               calendar: calendar, done: noop, snooze: noop, open: noop)
        XCTAssertEqual(several.id, Announcer.tasksDueID)
        XCTAssertEqual(several.title, "5 tasks due")
        XCTAssertEqual(several.body?.components(separatedBy: "\n").count, 4)
        XCTAssertEqual(several.body?.components(separatedBy: "\n").first, "• Task 1 · now")
        XCTAssertEqual(several.body?.components(separatedBy: "\n").last, "and 2 more")
        XCTAssertEqual(several.actions.map(\.title), ["All done", "Snooze 1 h", "Open"])
    }
}
