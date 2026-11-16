import XCTest
@testable import IronPet

@MainActor
final class TaskStoreTests: XCTestCase {
    private var database: Database!
    private var store: TaskStore!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var keepDays = 30
    private var changes: [String?] = []
    private let meeting = URL(fileURLWithPath: "/tmp/ironpet-meetings/2026-11-16 1000")

    override func setUp() async throws {
        database = Database.open(path: nil, migrations: AppMigrations.all).database
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        keepDays = 30
        changes = []
        store = makeStore()
    }

    override func tearDown() async throws {
        store = nil
        database = nil
    }

    private func makeStore() -> TaskStore {
        let store = TaskStore(database: database, now: { [unowned self] in clock }, keepDoneDays: { [unowned self] in keepDays })
        store.onChange = { [unowned self] in changes.append($0) }
        return store
    }

    private func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

    private func day(_ text: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: text)!
    }

    private func call(_ op: String, _ args: [String: Any] = [:], by: String = "agent:mcp",
                      file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        switch store.call(op, args, by: by) {
        case .success(let value): return try XCTUnwrap(value as? [String: Any], file: file, line: line)
        case .failure(let error):
            XCTFail("\(op) failed: \(error.message)", file: file, line: line)
            throw error
        }
    }

    private func callError(_ op: String, _ args: [String: Any] = [:]) -> String? {
        if case .failure(let error) = store.call(op, args, by: "agent:mcp") { return error.message }
        return nil
    }

    private func ids(_ result: [String: Any]) -> [String] {
        (result["tasks"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    private func linkRows(_ id: String) throws -> Int64 {
        try XCTUnwrap(database.read { try $0.rows("SELECT COUNT(*) FROM task_links WHERE task = ?", [id]) }.first?.first as? Int64)
    }

    // MARK: Create and update

    func testCreateGivesSlugIDAndHistory() throws {
        let item = try store.create(title: "  Write the Q4 report!  ", source: .chat, by: "agent:mcp")
        XCTAssertEqual(item.id, "write-the-q4-report")
        XCTAssertEqual(item.title, "Write the Q4 report!")
        XCTAssertEqual(item.status, .backlog)
        XCTAssertEqual(item.created, clock)
        XCTAssertEqual(item.updated, clock)
        XCTAssertNil(item.closed)
        XCTAssertEqual(store.tasks, [item])
        XCTAssertEqual(changes, ["write-the-q4-report"])
        XCTAssertEqual(store.history(item.id), [TaskEvent(at: clock, by: "agent:mcp", kind: .created, detail: "backlog: Write the Q4 report!")])

        XCTAssertEqual(try store.create(title: "Write the Q4 report", source: .chat, by: "user").id, "write-the-q4-report-2")
    }

    func testCreateDoneIsClosedAtOnce() throws {
        let item = try store.create(title: "Already did it", status: .done, source: .user, by: "user")
        XCTAssertEqual(item.closed, clock)
    }

    func testUpdateRecordsEachChangeAndTheNote() throws {
        let id = try store.create(title: "Draft", source: .chat, by: "agent:mcp").id
        advance(60)
        let due = day("2026-11-20")
        let link = TaskLink(kind: .url, ref: "https://github.com/acme/app/pull/1", label: "PR")
        let item = try store.update(id, title: "Draft the plan", notes: "Two pages", status: .inProgress, due: due, links: [link],
                                    note: "Started after the standup", by: "agent:mcp")
        XCTAssertEqual(item.id, id, "renaming keeps the id")
        XCTAssertEqual(item.title, "Draft the plan")
        XCTAssertEqual(item.notes, "Two pages")
        XCTAssertEqual(item.status, .inProgress)
        XCTAssertEqual(item.due, due)
        XCTAssertEqual(item.links, [link])
        XCTAssertEqual(item.updated, clock)
        XCTAssertEqual(store.task(id), item)

        let history = store.history(id)
        XCTAssertEqual(history.map(\.kind), [.created, .edited, .edited, .edited, .edited, .status, .note])
        XCTAssertEqual(history.dropFirst().map(\.detail), [
            "title: Draft the plan", "notes", "due: \(ISO8601DateFormatter().string(from: due))", "links: 1",
            "backlog → in_progress", "Started after the standup",
        ])
        XCTAssertTrue(history.dropFirst().allSatisfy { $0.at == clock && $0.by == "agent:mcp" })

        try store.update(id, due: .some(nil), by: "user")
        XCTAssertNil(store.task(id)?.due)
        XCTAssertEqual(store.history(id).last?.detail, "due: none")
    }

    func testNoOpUpdateWritesNothing() throws {
        let item = try store.create(title: "Same", notes: "n", source: .chat, by: "user")
        changes = []
        advance(60)
        let after = try store.update(item.id, title: " Same ", notes: "n", status: .backlog, links: [], note: "", by: "agent:mcp")
        XCTAssertEqual(after, item)
        XCTAssertEqual(store.task(item.id)?.updated, item.created)
        XCTAssertEqual(store.history(item.id).count, 1)
        XCTAssertEqual(changes, [])
    }

    func testDoneSetsClosedAndReopeningClearsIt() throws {
        let id = try store.create(title: "Ship", source: .chat, by: "user").id
        advance(60)
        try store.update(id, status: .done, by: "user")
        XCTAssertEqual(store.task(id)?.closed, clock)
        XCTAssertEqual(store.history(id).last, TaskEvent(at: clock, by: "user", kind: .closed, detail: "backlog → done"))

        advance(60)
        try store.update(id, status: .backlog, by: "agent:mcp")
        XCTAssertNil(store.task(id)?.closed)
        XCTAssertEqual(store.history(id).last, TaskEvent(at: clock, by: "agent:mcp", kind: .status, detail: "done → backlog"))
    }

    func testCloseWithNote() throws {
        let id = try store.create(title: "Review PR", status: .inProgress, source: .chat, by: "agent:mcp").id
        let item = try store.close(id, note: "Merged", by: "agent:mcp")
        XCTAssertEqual(item.status, .done)
        XCTAssertEqual(store.history(id).map(\.kind), [.created, .closed, .note])
        XCTAssertEqual(store.history(id).last?.detail, "Merged")
    }

    func testDeleteKeepsHistoryAndNeverReusesTheID() throws {
        let link = TaskLink(kind: .file, ref: "/tmp/notes.md", label: nil)
        let id = try store.create(title: "Old idea", source: .chat, links: [link], by: "agent:mcp").id
        XCTAssertEqual(try linkRows(id), 1)
        try store.delete(id, by: "user")
        XCTAssertNil(store.task(id))
        XCTAssertEqual(try linkRows(id), 0)
        XCTAssertEqual(store.history(id).map(\.kind), [.created, .deleted])
        XCTAssertEqual(store.history(id).last?.detail, "Old idea")

        let again = try store.create(title: "Old idea", source: .chat, by: "agent:mcp")
        XCTAssertEqual(again.id, "old-idea-2")
        XCTAssertEqual(store.history(again.id).count, 1)
        XCTAssertThrowsError(try store.delete(id, by: "user"))
    }

    func testUnknownIDThrows() {
        XCTAssertThrowsError(try store.update("nope", title: "x", by: "user")) { XCTAssertEqual($0 as? TaskError, TaskError(message: "no task with id \"nope\"")) }
        XCTAssertThrowsError(try store.close("nope", by: "user"))
    }

    // MARK: Validation

    func testValidation() throws {
        XCTAssertThrowsError(try store.create(title: "   ", source: .chat, by: "user")) { XCTAssertEqual(($0 as? TaskError)?.message, "title is empty") }
        XCTAssertThrowsError(try store.create(title: String(repeating: "a", count: 201), source: .chat, by: "user"))
        XCTAssertNoThrow(try store.create(title: String(repeating: "a", count: 200), source: .chat, by: "user"))
        XCTAssertThrowsError(try store.create(title: "Big notes", notes: String(repeating: "é", count: 2049), source: .chat, by: "user"),
                             "the limit is in bytes, not characters")
        XCTAssertNoThrow(try TaskValidator.notes(String(repeating: "a", count: 4096)))
        XCTAssertEqual(try TaskValidator.title("one\ntwo"), "one two")
        XCTAssertThrowsError(try TaskValidator.title(42))

        XCTAssertThrowsError(try TaskValidator.status("finished"))
        XCTAssertThrowsError(try TaskValidator.due("next Tuesday"))
        XCTAssertThrowsError(try TaskValidator.due(20261120))
        XCTAssertEqual(try TaskValidator.due("2026-11-20T15:30:00+01:00"), ISO8601DateFormatter().date(from: "2026-11-20T15:30:00+01:00"))
        XCTAssertNil(try TaskValidator.due(NSNull()))

        for ref in ["ftp://example.com/file", "javascript:alert(1)", "file:///etc/passwd", "example.com"] {
            XCTAssertThrowsError(try TaskValidator.links([["kind": "url", "ref": ref]]), ref)
        }
        XCTAssertNoThrow(try TaskValidator.links([["kind": "url", "ref": "HTTPS://example.com"]]))
        XCTAssertThrowsError(try TaskValidator.links([["kind": "email", "ref": "a@b.c"]]))
        XCTAssertThrowsError(try TaskValidator.links([["kind": "file", "ref": "  "]]))
        let eleven = Array(repeating: ["kind": "file", "ref": "/tmp/a"], count: 11)
        XCTAssertThrowsError(try TaskValidator.links(eleven)) { XCTAssertEqual(($0 as? TaskError)?.message, "at most 10 links") }
        XCTAssertEqual(try TaskValidator.links(Array(eleven.prefix(10))).count, 10)

        XCTAssertEqual(store.tasks.count, 1, "only the valid create was stored")
    }

    // MARK: call

    func testListHidesDoneUnlessAsked() throws {
        let a = try store.create(title: "A", source: .chat, by: "user").id
        let b = try store.create(title: "B", status: .needsYou, source: .chat, by: "user").id
        let c = try store.create(title: "C", status: .done, source: .chat, by: "user").id

        let list = try call("list")
        XCTAssertEqual(ids(list), [b, a])
        XCTAssertNotNil(list["note"] as? String)
        XCTAssertEqual(ids(try call("list", ["status": "done"])), [c])
        XCTAssertEqual(ids(try call("list", ["status": ["backlog", "done"]])), [a, c])
        XCTAssertEqual(ids(try call("list", ["status": NSNull()])), [b, a])
        XCTAssertEqual(Set(ids(try call("list", ["include_done": true]))), [a, b, c])
        XCTAssertNotNil(callError("list", ["status": "finished"]))
    }

    func testGetIncludesHistory() throws {
        let id = try store.create(title: "Look", source: .chat, by: "agent:mcp").id
        let got = try call("get", ["id": id])
        XCTAssertEqual(got["title"] as? String, "Look")
        let history = try XCTUnwrap(got["history"] as? [[String: Any]])
        XCTAssertEqual(history.map { $0["kind"] as? String }, ["created"])
        XCTAssertEqual(history.first?["by"] as? String, "agent:mcp")
    }

    func testCreateThroughCall() throws {
        let created = try call("create", [
            "title": "Ship it", "notes": "Soon", "status": "needs_you", "due": "2026-11-20",
            "links": [["kind": "url", "ref": "https://example.com/pr/1", "label": "PR"]],
        ])
        let id = try XCTUnwrap(created["id"] as? String)
        XCTAssertEqual(created["status"] as? String, "needs_you")
        XCTAssertEqual(created["source"] as? String, "chat")
        XCTAssertEqual(created["notes"] as? String, "Soon")
        XCTAssertEqual((created["links"] as? [[String: Any]])?.first?["label"] as? String, "PR")
        XCTAssertEqual(store.task(id)?.due, day("2026-11-20"))

        XCTAssertEqual(try call("create", ["title": "From the terminal"], by: "agent:cli")["source"] as? String, "cli")
        XCTAssertEqual(try call("create", ["title": "From Telegram", "source": "telegram"])["source"] as? String, "telegram")
        XCTAssertEqual(try call("create", ["title": "Plain", "status": NSNull()])["status"] as? String, "backlog")

        XCTAssertNotNil(callError("create", [:]))
        XCTAssertNotNil(callError("create", ["title": "x", "status": "finished"]))
        XCTAssertNotNil(callError("create", ["title": "x", "due": "next Tuesday"]))
        XCTAssertNotNil(callError("create", ["title": "x", "source": "email"]))
        XCTAssertNotNil(callError("create", ["title": "x", "links": [["kind": "url", "ref": "ftp://x"]]]))
        XCTAssertEqual(store.tasks.count, 4)
    }

    func testUpdateCloseAndDeleteThroughCall() throws {
        let id = try store.create(title: "Plan", source: .chat, due: day("2026-11-20"), by: "user").id

        let updated = try call("update", ["id": id, "changes": ["status": "in_progress", "due": NSNull()], "note": "Picked up"])
        XCTAssertEqual(updated["status"] as? String, "in_progress")
        XCTAssertNil(updated["due"])
        XCTAssertEqual(store.history(id).last?.detail, "Picked up")

        let flat = try call("update", ["id": id, "title": "Plan v2"])
        XCTAssertEqual(flat["title"] as? String, "Plan v2", "fields can also sit next to the id")
        XCTAssertEqual(store.task(id)?.status, .inProgress, "absent fields stay as they were")

        let closed = try call("close", ["id": id, "note": "Done and dusted"])
        XCTAssertEqual(closed["status"] as? String, "done")
        XCTAssertNotNil(closed["closed"] as? String)
        XCTAssertEqual(store.history(id).last?.detail, "Done and dusted")

        XCTAssertEqual(try call("delete", ["id": id])["deleted"] as? String, id)
        XCTAssertNil(store.task(id))
        XCTAssertEqual(store.history(id).last?.by, "agent:mcp")
    }

    func testCallErrors() {
        XCTAssertEqual(callError("archive"), "unknown operation \"archive\"")
        for op in ["get", "update", "close", "delete"] {
            XCTAssertEqual(callError(op), "id is required", op)
            XCTAssertEqual(callError(op, ["id": "ghost"]), "no task with id \"ghost\"", op)
        }
    }

    // MARK: Prune

    func testPruneDeletesOldDoneTasksOnly() throws {
        let old = try store.create(title: "Old done", source: .chat, links: [TaskLink(kind: .file, ref: "/tmp/a", label: nil)], by: "user").id
        try store.close(old, by: "user")
        let open = try store.create(title: "Old open", source: .chat, by: "user").id
        advance(20 * 86_400)
        let recent = try store.create(title: "Recent done", source: .chat, by: "user").id
        try store.close(recent, by: "user")

        advance(15 * 86_400)
        store.reload()
        XCTAssertNil(store.task(old), "closed 35 days ago")
        XCTAssertEqual(try linkRows(old), 0)
        XCTAssertEqual(store.history(old), [], "its history goes with it")
        XCTAssertNotNil(store.task(recent), "closed 15 days ago")
        XCTAssertNotNil(store.task(open), "open tasks are never pruned")

        keepDays = 10
        advance(3600)
        store.reload()
        XCTAssertNotNil(store.task(recent), "prune runs at most daily")

        advance(86_400)
        store.reload()
        XCTAssertNil(store.task(recent))
        XCTAssertNotNil(store.task(open))
    }

    func testNewStorePrunesAtLaunch() throws {
        let id = try store.create(title: "Done long ago", status: .done, source: .chat, by: "user").id
        advance(31 * 86_400)
        store = makeStore()
        XCTAssertNil(store.task(id))
    }

    // MARK: Suggestions

    func testSuggestSkipsTasksAndDuplicates() throws {
        try store.create(title: "Send the deck", source: .chat, by: "user")
        changes = []
        let added = store.suggest([("Send the deck", nil), ("send the DECK", nil), ("Book the room", "2026-11-20"),
                                   ("book the room", nil), ("Email Sam", "next Tuesday"), ("   ", nil)], meeting: meeting)
        XCTAssertEqual(added.map(\.title), ["Book the room", "Email Sam"])
        XCTAssertEqual(added.map(\.id), ["book-the-room", "email-sam"])
        XCTAssertEqual(store.suggestions, added)
        XCTAssertEqual(store.suggestions.first?.meeting, meeting)
        XCTAssertEqual(changes, [nil])

        XCTAssertEqual(store.suggest([("BOOK THE ROOM", nil), ("Order lunch", nil)], meeting: meeting).map(\.title), ["Order lunch"])
        XCTAssertEqual(store.suggest([("Order lunch", nil)], meeting: meeting), [])
        XCTAssertEqual(store.suggestions.count, 3)
        XCTAssertEqual(makeStore().suggestions, store.suggestions, "suggestions survive a restart")
    }

    func testAcceptMakesAMeetingTask() throws {
        store.suggest([("Book the room", "2026-11-20"), ("Email Sam", "next Tuesday")], meeting: meeting)

        let booked = try store.accept("book-the-room")
        XCTAssertEqual(booked.title, "Book the room")
        XCTAssertEqual(booked.status, .backlog)
        XCTAssertEqual(booked.source, .meeting)
        XCTAssertEqual(booked.due, day("2026-11-20"))
        XCTAssertEqual(booked.notes, "")
        XCTAssertEqual(booked.links, [TaskLink(kind: .file, ref: meeting.path, label: "Meeting")])
        XCTAssertEqual(store.history(booked.id).first?.by, "user")
        XCTAssertEqual(store.suggestions.map(\.id), ["email-sam"])

        let email = try store.accept("email-sam")
        XCTAssertNil(email.due)
        XCTAssertEqual(email.notes, "Due (from the meeting): next Tuesday")
        XCTAssertEqual(store.suggestions, [])
        XCTAssertThrowsError(try store.accept("email-sam"))
    }

    func testSkipAndAcceptAll() throws {
        store.suggest([("One", nil), ("Two", nil), ("Three", nil)], meeting: meeting)
        store.skip("two")
        XCTAssertEqual(store.suggestions.map(\.id), ["one", "three"])
        XCTAssertEqual(store.tasks, [])

        store.acceptAll()
        XCTAssertEqual(store.suggestions, [])
        XCTAssertEqual(Set(store.tasks.map(\.title)), ["One", "Three"])
        XCTAssertTrue(store.tasks.allSatisfy { $0.source == .meeting })
    }

    // MARK: Ordering

    func testOrderedAndActiveCount() throws {
        let a = try store.create(title: "A", source: .chat, by: "user").id
        advance(1)
        let b = try store.create(title: "B", status: .inProgress, source: .chat, by: "user").id
        advance(1)
        let c = try store.create(title: "C", status: .needsYou, source: .chat, by: "user").id
        advance(1)
        let d = try store.create(title: "D", status: .done, source: .chat, by: "user").id
        advance(1)
        let e = try store.create(title: "E", status: .done, source: .chat, by: "user").id
        advance(1)
        let f = try store.create(title: "F", source: .chat, by: "user").id

        XCTAssertEqual(store.ordered.map(\.id), [c, b, f, a, e, d])
        XCTAssertEqual(store.activeCount, 2)

        advance(1)
        try store.update(a, notes: "touched", by: "user")
        XCTAssertEqual(store.ordered.map(\.id), [c, b, a, f, e, d], "a recent update moves a task up within its status")
    }
}
