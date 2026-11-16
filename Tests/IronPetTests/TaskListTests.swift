import XCTest
@testable import IronPet

final class TaskListTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        return c
    }()

    /// 2026-11-16 14:00 in Helsinki.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 14))! }

    private func task(due: Date?, status: TaskStatus = .inProgress) -> TaskItem {
        TaskItem(id: "t", title: "T", notes: "", status: status, source: .chat, due: due, links: [],
                 created: now, updated: now, closed: nil)
    }

    private func day(_ offset: Int, hour: Int = 0, minute: Int = 0) -> Date {
        let start = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start)!
    }

    func testNoDueDateHasNoLabel() {
        XCTAssertNil(task(due: nil).dueLabel(now: now, calendar: calendar))
        XCTAssertFalse(task(due: nil).isOverdue(now: now, calendar: calendar))
    }

    func testAPlainDateLastsTheWholeDay() {
        let item = task(due: day(0))
        XCTAssertFalse(item.isOverdue(now: now, calendar: calendar))
        XCTAssertEqual(item.dueLabel(now: now, calendar: calendar), "Due today")
    }

    func testAPlainDateBeforeTodayIsOverdue() {
        let item = task(due: day(-1))
        XCTAssertTrue(item.isOverdue(now: now, calendar: calendar))
        XCTAssertEqual(item.dueLabel(now: now, calendar: calendar), "Overdue since yesterday")
    }

    func testATimeEarlierTodayIsOverdueAndShowsOnlyTheTime() throws {
        let item = task(due: day(0, hour: 9, minute: 30))
        XCTAssertTrue(item.isOverdue(now: now, calendar: calendar))
        let label = try XCTUnwrap(item.dueLabel(now: now, calendar: calendar))
        XCTAssertTrue(label.hasPrefix("Overdue since "), label)
        XCTAssertFalse(label.contains("today"), label)
    }

    func testATimeLaterIsDueWithItsTime() throws {
        let item = task(due: day(1, hour: 17))
        XCTAssertFalse(item.isOverdue(now: now, calendar: calendar))
        let label = try XCTUnwrap(item.dueLabel(now: now, calendar: calendar))
        XCTAssertTrue(label.hasPrefix("Due tomorrow at "), label)
    }

    func testDoneTasksAreNeverOverdue() {
        let item = task(due: day(-3), status: .done)
        XCTAssertFalse(item.isOverdue(now: now, calendar: calendar))
        XCTAssertTrue(item.dueLabel(now: now, calendar: calendar)?.hasPrefix("Due ") == true)
    }

    func testLinkHelpNamesWhatOpens() {
        XCTAssertEqual(TaskLink(kind: .url, ref: "https://github.com/you/app/pull/1", label: nil).help, "Open github.com")
        XCTAssertEqual(TaskLink(kind: .url, ref: "https://x.dev", label: "PR #1").help, "Open PR #1")
        XCTAssertEqual(TaskLink(kind: .file, ref: "/tmp/notes.md", label: nil).help, "Show notes.md in Finder")
        XCTAssertEqual(TaskLink(kind: .thread, ref: "t1", label: " ").help, "Open chat thread")
    }
}
