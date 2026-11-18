import XCTest
@testable import IronPet

final class TaskDetailTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func labels(_ detail: TaskDetail) -> [String] { detail.fields.map(\.label) }

    func testFullTaskShowsEveryField() {
        let task = TaskItem(id: "t", title: "Ship", notes: "See **this** https://example.com", status: .needsYou, source: .agent,
                            due: now.addingTimeInterval(86_400), links: [TaskLink(kind: .url, ref: "https://example.com", label: "Docs")],
                            created: now, updated: now, closed: nil, waitingOn: "Ana",
                            sourceRef: #"{"ref":"session 3","reason":"CI failed"}"#)
        let events = [TaskEvent(at: now, by: "agent:mcp", kind: .created, detail: "created")]
        let detail = TaskDetail(task: task, history: events, now: now)
        XCTAssertEqual(labels(detail), ["Status", "Waiting", "Due", "Origin", "Origin ref", "Origin reason", "Created", "Updated"])
        XCTAssertEqual(detail.fields.first { $0.label == "Origin reason" }?.value, "CI failed")
        XCTAssertEqual(detail.fields.first { $0.label == "Waiting" }?.value, "Waiting on Ana")
        XCTAssertEqual(detail.notes, "See **this** https://example.com")
        XCTAssertEqual(detail.links.count, 1)
        XCTAssertEqual(detail.history, events)
    }

    func testMinimalTaskOmitsMissingFields() {
        let task = TaskItem(id: "t", title: "Ship", notes: "  \n", status: .backlog, source: .user, due: nil, links: [],
                            created: now, updated: now, closed: nil)
        let detail = TaskDetail(task: task, history: [], now: now)
        XCTAssertEqual(labels(detail), ["Status", "Origin", "Created", "Updated"])
        XCTAssertEqual(detail.notes, "")
        XCTAssertTrue(detail.links.isEmpty)
        XCTAssertTrue(detail.history.isEmpty)
    }

    func testSuggestionShowsNotesUrlDueAndOrigin() {
        let suggestion = TaskSuggestion(id: "s", title: "Reply", due: "2026-11-20", notes: "Details", url: URL(string: "https://example.com/x"),
                                        origin: .automation(id: "a", name: "PR watcher"), created: now,
                                        sourceRef: #"{"ref":"pr 4","reason":"new review"}"#)
        let detail = TaskDetail(suggestion: suggestion)
        XCTAssertEqual(labels(detail), ["Due", "Origin", "Origin name", "Origin ref", "Origin reason", "Created"])
        XCTAssertEqual(detail.fields.first { $0.label == "Origin" }?.value, "automation")
        XCTAssertEqual(detail.notes, "Details")
        XCTAssertEqual(detail.links, [TaskLink(kind: .url, ref: "https://example.com/x", label: nil)])
    }

    func testPlainTextOriginRefIsKept() {
        XCTAssertEqual(TaskDetail.originFields("not json"), [.init(label: "Origin ref", value: "not json")])
        XCTAssertEqual(TaskDetail.originFields(nil), [])
    }
}
