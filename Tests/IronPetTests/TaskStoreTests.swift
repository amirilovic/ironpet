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
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-tasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        database = Database.open(path: nil, migrations: AppMigrations.all).database
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        keepDays = 30
        changes = []
        store = makeStore()
    }

    override func tearDown() async throws {
        store = nil
        database = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> TaskStore {
        let store = TaskStore(database: database, now: { [unowned self] in clock }, keepDoneDays: { [unowned self] in keepDays })
        store.onChange = { [unowned self] in changes.append($0) }
        return store
    }

    func testLabelEditsPublishTheNewUpdatedTime() throws {
        let id = try store.create(title: "Ship", source: .user, by: "user").id
        advance(30)
        _ = try store.update(id, addLabels: ["team": "core"], by: "user")
        XCTAssertEqual(store.task(id)?.updated, clock)
        advance(30)
        _ = try store.update(id, removeLabels: ["team"], by: "user")
        XCTAssertEqual(store.task(id)?.updated, clock)
        XCTAssertEqual(store.task(id)?.labels, [:])
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
        switch TaskJSON.call(TasksAPI(store: store), op, args, by: by) {
        case .success(let value): return try XCTUnwrap(value as? [String: Any], file: file, line: line)
        case .failure(let error):
            XCTFail("\(op) failed: \(error.message)", file: file, line: line)
            throw error
        }
    }

    private func callError(_ op: String, _ args: [String: Any] = [:]) -> String? {
        if case .failure(let error) = TaskJSON.call(TasksAPI(store: store), op, args, by: "agent:mcp") { return error.message }
        return nil
    }

    private func ids(_ result: [String: Any]) -> [String] {
        (result["tasks"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    private func linkRows(_ id: String) throws -> Int64 {
        try XCTUnwrap(database.read { try $0.rows("SELECT COUNT(*) FROM task_links WHERE task = ?", [id]) }.first?.first as? Int64)
    }

    // MARK: Labels

    private func labels(_ result: [String: Any]) -> [String: String] { result["labels"] as? [String: String] ?? [:] }

    private func createLabelled(_ title: String, _ labels: [String: Any]?) throws -> String {
        var args: [String: Any] = ["title": title, "origin": ["kind": "agent", "ref": "t", "reason": "test"]]
        if let labels { args["labels"] = labels }
        return try XCTUnwrap(try call("create", args)["id"] as? String)
    }

    func testCreateWithLabelsReturnsThemFromGet() throws {
        let id = try createLabelled("Ship it", ["merge": "auto"])
        XCTAssertEqual(labels(try call("get", ["id": id])), ["merge": "auto"])
        // Survives a reload from the database.
        store = makeStore()
        XCTAssertEqual(store.task(id)?.labels, ["merge": "auto"])
    }

    func testUpdateWithoutLabelsKeepsThem() throws {
        let id = try createLabelled("Ship it", ["merge": "auto", "repo": "band"])
        _ = try call("update", ["id": id, "changes": ["notes": "new notes", "title": "Ship it now"]])
        _ = try call("update", ["id": id, "changes": ["status": "in_progress"], "note": "started"])
        _ = try call("close", ["id": id, "note": "done"])
        XCTAssertEqual(labels(try call("get", ["id": id])), ["merge": "auto", "repo": "band"])
    }

    func testUpdateMergesAndRemovesLabels() throws {
        let id = try createLabelled("Ship it", ["a": "1", "b": "2"])
        _ = try call("update", ["id": id, "changes": ["labels": ["c": "3"], "remove_labels": ["a"]]])
        XCTAssertEqual(labels(try call("get", ["id": id])), ["b": "2", "c": "3"])
        _ = try call("update", ["id": id, "changes": ["labels": ["b": "9"]]])
        XCTAssertEqual(labels(try call("get", ["id": id])), ["b": "9", "c": "3"])
        let history = try XCTUnwrap(try call("get", ["id": id])["history"] as? [[String: Any]])
        XCTAssertTrue(history.contains { ($0["detail"] as? String)?.hasPrefix("labels:") == true })
    }

    func testListFiltersByLabel() throws {
        let auto = try createLabelled("Auto one", ["merge": "auto", "repo": "band"])
        _ = try createLabelled("Manual", ["merge": "manual"])
        _ = try createLabelled("Plain", nil)
        XCTAssertEqual(ids(try call("list", ["labels": ["merge": "auto"]])), [auto])
        XCTAssertEqual(ids(try call("list", ["labels": ["merge": "auto", "repo": "ironpet"]])), [])
        XCTAssertEqual(ids(try call("list", [:])).count, 3)
    }

    func testInvalidLabelKeysAreRefused() throws {
        for key in ["", "   ", "two words", "a=b", "a,b", "tab\there"] {
            let message = callError("create", ["title": "X \(key.count)", "origin": ["kind": "agent", "ref": "t", "reason": "r"], "labels": [key: "v"]])
            XCTAssertNotNil(message, "key \"\(key)\" was accepted")
        }
        XCTAssertTrue(try XCTUnwrap(callError("create", ["title": "Y", "origin": ["kind": "agent", "ref": "t", "reason": "r"], "labels": [" ": "v"]])).contains("label key is empty"))
        let id = try createLabelled("Z", ["a": "1"])
        XCTAssertNotNil(callError("update", ["id": id, "changes": ["labels": ["bad key": "v"]]]))
        XCTAssertNotNil(callError("update", ["id": id, "changes": ["remove_labels": [" "]]]))
        XCTAssertNotNil(callError("update", ["id": id, "changes": ["labels": ["a": ""]]]))
        XCTAssertEqual(store.task(id)?.labels, ["a": "1"])
    }

    func testDeleteRemovesLabelRows() throws {
        let id = try createLabelled("Gone", ["a": "1"])
        _ = try call("delete", ["id": id])
        let count = try XCTUnwrap(database.read { try $0.rows("SELECT COUNT(*) FROM task_labels WHERE task = ?", [id]) }.first?.first as? Int64)
        XCTAssertEqual(count, 0)
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
            "origin": ["kind": "chat", "ref": "chat-1", "reason": "test"],
        ])
        let id = try XCTUnwrap(created["id"] as? String)
        XCTAssertEqual(created["status"] as? String, "needs_you")
        XCTAssertEqual(created["source"] as? String, "chat")
        XCTAssertEqual(created["notes"] as? String, "Soon")
        XCTAssertEqual((created["links"] as? [[String: Any]])?.first?["label"] as? String, "PR")
        XCTAssertEqual(store.task(id)?.due, day("2026-11-20"))

        XCTAssertEqual(try call("create", ["title": "From the terminal", "origin": ["kind": "agent", "ref": "cli", "reason": "test"]],
                                by: "agent:cli")["source"] as? String, "agent")
        XCTAssertEqual(try call("create", ["title": "From a PR", "origin": ["kind": "pr", "ref": "u", "reason": "test"]])["source"] as? String, "pr")
        XCTAssertEqual(try call("create", ["title": "Plain", "status": NSNull(), "origin": ["kind": "chat", "ref": "chat-1", "reason": "test"]])["status"] as? String, "backlog")

        XCTAssertNotNil(callError("create", [:]))
        XCTAssertNotNil(callError("create", ["title": "x", "status": "finished", "origin": ["kind": "chat", "ref": "chat-1", "reason": "test"]]))
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
            XCTAssertEqual(callError(op, ["id": "ghost", "note": "n"]), "no task with id \"ghost\"", op)
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
        let added = store.suggest([("Send the deck", nil, nil), ("send the DECK", nil, nil), ("Book the room", "2026-11-20", nil),
                                   ("book the room", nil, nil), ("Email Sam", "next Tuesday", nil), ("   ", nil, nil)], meeting: meeting)
        XCTAssertEqual(added.map(\.title), ["Book the room", "Email Sam"])
        XCTAssertEqual(added.map(\.id), ["book-the-room", "email-sam"])
        XCTAssertEqual(store.suggestions, added)
        XCTAssertEqual(store.suggestions.first?.meeting, meeting)
        XCTAssertEqual(changes, [nil])

        XCTAssertEqual(store.suggest([("BOOK THE ROOM", nil, nil), ("Order lunch", nil, nil)], meeting: meeting).map(\.title), ["Order lunch"])
        XCTAssertEqual(store.suggest([("Order lunch", nil, nil)], meeting: meeting), [])
        XCTAssertEqual(store.suggestions.count, 3)
        XCTAssertEqual(makeStore().suggestions, store.suggestions, "suggestions survive a restart")
    }

    func testAcceptMakesAMeetingTask() throws {
        store.suggest([("Book the room", "2026-11-20", nil), ("Email Sam", "next Tuesday", nil)], meeting: meeting)

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
        store.suggest([("One", nil, nil), ("Two", nil, nil), ("Three", nil, nil)], meeting: meeting)
        store.skip("two")
        XCTAssertEqual(store.suggestions.map(\.id), ["one", "three"])
        XCTAssertEqual(store.tasks, [])

        store.acceptAll()
        XCTAssertEqual(store.suggestions, [])
        XCTAssertEqual(Set(store.tasks.map(\.title)), ["One", "Three"])
        XCTAssertTrue(store.tasks.allSatisfy { $0.source == .meeting })
    }

    // MARK: Suggestions from automations

    private func draft(_ key: String, _ title: String, url: URL? = nil) -> TaskSuggestion.Draft {
        TaskSuggestion.Draft(key: key, title: title, url: url)
    }

    func testDraftCleansAndClampsWatcherText() throws {
        let d = try TaskSuggestion.Draft(action: [
            "type": "suggest_task", "id": 42, "title": "  Reply\u{0007} to\n\tSam\u{202E}gnp.exe  ",
            "notes": "Line one\r\nLine two\u{0000}" + String(repeating: "x", count: 3000),
            "due": "2026-11-20", "url": "https://mail.example.com/m/1",
        ])
        XCTAssertEqual(d.key, "42")
        XCTAssertEqual(d.title, "Reply to Samgnp.exe")
        XCTAssertTrue(d.notes.hasPrefix("Line one \nLine two" + "xxx"), d.notes)
        XCTAssertEqual(d.notes.count, TaskSuggestion.Draft.maxNotes)
        XCTAssertEqual(d.due, "2026-11-20")
        XCTAssertEqual(d.url?.absoluteString, "https://mail.example.com/m/1")

        let long = try TaskSuggestion.Draft(action: ["id": "a", "title": String(repeating: "t", count: 500),
                                                     "notes": String(repeating: "é", count: 3000), "due": "next Friday",
                                                     "url": "javascript:alert(1)"])
        XCTAssertEqual(long.title.count, TaskSuggestion.Draft.maxTitle)
        XCTAssertLessThanOrEqual(long.notes.utf8.count, TaskValidator.maxNotes)
        XCTAssertNil(long.due, "only yyyy-MM-dd")
        XCTAssertNil(long.url, "only http and https")
        XCTAssertNil(try TaskSuggestion.Draft(action: ["id": "b", "title": "x", "url": "file:///etc/passwd", "due": "2026-11-20T10:00:00Z"]).url)

        XCTAssertThrowsError(try TaskSuggestion.Draft(action: ["title": "no id"]))
        XCTAssertThrowsError(try TaskSuggestion.Draft(action: ["id": "c", "title": " \u{0001}\n "]))
    }

    func testAgentSuggestionsShareTheScriptPathAndDedupePerOriginKind() throws {
        let origin: [String: Any] = ["kind": "email", "ref": "mail:1", "reason": "Ana asked"]
        func suggest(_ args: [String: Any], origin: [String: Any]? = nil) throws -> Any {
            var args = args
            args["origin"] = origin ?? self.suggestOrigin
            switch TaskJSON.call(TasksAPI(store: store), "suggest", args, by: "agent:cli") {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }
        suggestOrigin = origin
        let long = String(repeating: "x", count: 300)
        _ = try suggest(["id": "mail:1", "title": long + "\u{0007}", "notes": String(repeating: "n", count: 3000), "due": "soon", "url": "ftp://x"])
        let first = try XCTUnwrap(store.suggestions.first)
        XCTAssertEqual(first.title.count, 200)
        XCTAssertEqual(first.notes.count, 2000)
        XCTAssertNil(first.due)
        XCTAssertNil(first.url)
        XCTAssertEqual(store.tasks, [])
        XCTAssertEqual(first.origin, .automation(id: "agent:email", name: "email agent"))

        _ = try suggest(["id": "mail:1", "title": "Different"])
        XCTAssertEqual(store.suggestions.count, 1, "same id")
        try store.skip(first.id)
        _ = try suggest(["id": "mail:1", "title": long])
        XCTAssertEqual(store.suggestions.count, 0, "same id after a skip")
        let accepted = try suggest(["id": "mail:2", "title": "Book flights"])
        _ = accepted
        _ = try store.accept(try XCTUnwrap(store.suggestions.first).id)
        _ = try suggest(["id": "mail:3", "title": "book flights"])
        XCTAssertEqual(store.suggestions.count, 0, "a title that is already a task")
        _ = try suggest(["id": "mail:1", "title": "Other kind"], origin: ["kind": "pr", "ref": "r", "reason": "x"])
        XCTAssertEqual(store.suggestions.count, 1, "ids are kept per origin kind")
        _ = try suggest(["id": "mail:1", "title": "Another"], origin: origin)
        XCTAssertThrowsError(try suggest(["title": "No id"]))
        XCTAssertThrowsError(try suggest(["id": "z"]))
    }

    private var suggestOrigin: [String: Any] = [:]

    func testAutomationSuggestionsAreNotRepeatedAfterSkipOrAccept() throws {
        try store.create(title: "Pay the invoice", source: .chat, by: "user")
        let added = store.suggest([draft("m1", "Reply to Sam"), draft("m1", "Reply to Sam again"), draft("m2", "Book flights"),
                                   draft("m3", "pay the INVOICE")], automation: "gmail", name: "Gmail\nwatcher")
        XCTAssertEqual(added.map(\.title), ["Reply to Sam", "Book flights"], "same key once per call; a title that is a task is left out")
        XCTAssertEqual(added.first?.origin, .automation(id: "gmail", name: "Gmail watcher"))
        XCTAssertEqual(added.first?.originLabel, "From Gmail watcher")

        XCTAssertEqual(store.suggest([draft("m1", "Reply to Sam")], automation: "gmail", name: "Gmail"), [], "already waiting")
        store.skip("reply-to-sam")
        try store.accept("book-flights")
        XCTAssertEqual(store.suggest([draft("m1", "Reply to Sam"), draft("m2", "Book flights, renamed")], automation: "gmail", name: "Gmail"), [],
                       "skipped and accepted keys stay remembered")
        XCTAssertEqual(makeStore().suggest([draft("m1", "Reply to Sam")], automation: "gmail", name: "Gmail"), [], "also after a restart")
        XCTAssertEqual(store.suggest([draft("m1", "Reply to Sam")], automation: "slack", name: "Slack").map(\.title), ["Reply to Sam"],
                       "keys belong to one automation")
        XCTAssertEqual(store.suggest([draft("m3", "pay the invoice")], automation: "gmail", name: "Gmail"), [],
                       "m3 was never stored, and is still a task by title")
        XCTAssertEqual(store.suggest([draft("m9", "REPLY TO SAM")], automation: "gmail", name: "Gmail"), [], "same-title dedupe")
    }

    func testAutomationSuggestionsWaitingAreCapped() {
        let many = (1...60).map { draft("k\($0)", "Item \($0)") }
        XCTAssertEqual(store.suggest(many, automation: "w", name: "W").count, TaskStore.maxPendingPerAutomation)
        XCTAssertEqual(store.suggest([draft("k60", "Item 60")], automation: "w", name: "W"), [], "no room")
        store.skip("item-1")
        XCTAssertEqual(store.suggest([draft("k60", "Item 60")], automation: "w", name: "W").map(\.title), ["Item 60"],
                       "a capped one was not remembered, so it comes when there is room")
    }

    func testAcceptMakesAnAutomationTaskWithItsLink() throws {
        let url = URL(string: "https://github.com/acme/app/issues/9")!
        var d = draft("9", "Triage issue 9", url: url)
        d.due = "2026-11-20"
        d.notes = "Opened by a customer"
        store.suggest([d, draft("10", "No link")], automation: "gh", name: "GitHub")
        let item = try store.accept("triage-issue-9")
        XCTAssertEqual(item.source, .automation)
        XCTAssertEqual(item.status, .backlog)
        XCTAssertEqual(item.due, day("2026-11-20"))
        XCTAssertEqual(item.notes, "Opened by a customer")
        XCTAssertEqual(item.links, [TaskLink(kind: .url, ref: url.absoluteString, label: nil)])
        XCTAssertEqual(store.history(item.id).first?.by, "user")
        XCTAssertEqual(try store.accept("no-link").links, [])
        XCTAssertEqual(TaskSource.automation.symbol, "clock.badge.checkmark")
    }

    private func temporaryDatabasePath() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-tasks-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("ironpet.db")
    }

    func testMainDatabaseGetsTheLaterTaskMigrations() throws {
        let path = temporaryDatabasePath()
        do {
            let old = try Database(path: path, migrations: AppMigrations.all.filter { $0.version <= 200 })
            XCTAssertEqual(old.schemaVersion, 200)
            try old.write { db in
                try db.execute("INSERT INTO task_suggestions(id, title, due, meeting, created) VALUES(?, ?, ?, ?, ?)",
                               ["book-the-room", "Book the room", "Friday", meeting.path, clock.timeIntervalSince1970])
                try db.execute("""
                    INSERT INTO task_items(id, title, notes, status, source, created, updated) VALUES('reply-to-sam', 'Reply to Sam',
                    'From screen capture items 1', 'backlog', 'capture', ?, ?)
                    """, [clock.timeIntervalSince1970, clock.timeIntervalSince1970])
            }
        }
        let migrated = try Database(path: path, migrations: AppMigrations.all)
        XCTAssertEqual(migrated.schemaVersion, AppMigrations.all.map(\.version).max())
        let reopened = TaskStore(database: migrated, now: { [unowned self] in clock }, keepDoneDays: { 30 })
        XCTAssertEqual(reopened.suggestions, [TaskSuggestion(id: "book-the-room", title: "Book the room", due: "Friday",
                                                             origin: .meeting(meeting), created: clock)])
        XCTAssertEqual(reopened.task("reply-to-sam")?.source, .capture)
        XCTAssertEqual(reopened.dueMarks(), [:])

        let added = reopened.suggest([TaskSuggestion.Draft(key: "1", title: "Review PR 12", due: nil)], automation: "prs", name: "PRs")
        XCTAssertEqual(added.count, 1)
        let item = try reopened.accept("book-the-room")
        XCTAssertEqual(item.source, .meeting)
        XCTAssertEqual(item.notes, "Due (from the meeting): Friday")
        XCTAssertThrowsError(try migrated.write { db in
            try db.execute("INSERT INTO task_suggestions(id, title, created) VALUES('x', 'x', 0)")
        }, "a suggestion has exactly one origin")
    }

    /// A development build numbered the task migrations 201 to 203. Such a database then runs the renumbered ones, which must find their changes already there.
    func testDatabaseFromOldNumberingMigrates() throws {
        let path = temporaryDatabasePath()
        do {
            let old = try Database(path: path, migrations: AppMigrations.all.filter { $0.version <= 200 })
            try old.write { db in
                try db.script("""
                    CREATE TABLE task_suggestions_201(id TEXT PRIMARY KEY, title TEXT NOT NULL, due TEXT, notes TEXT NOT NULL DEFAULT '', url TEXT,
                                                      meeting TEXT, automation TEXT, automation_name TEXT, created REAL NOT NULL,
                                                      CHECK ((meeting IS NULL) <> (automation IS NULL))) WITHOUT ROWID;
                    INSERT INTO task_suggestions_201(id, title, due, meeting, created) SELECT id, title, due, meeting, created FROM task_suggestions;
                    DROP TABLE task_suggestions;
                    ALTER TABLE task_suggestions_201 RENAME TO task_suggestions;
                    CREATE TABLE task_suggestion_keys(automation TEXT NOT NULL, key TEXT NOT NULL, at REAL NOT NULL,
                                                      PRIMARY KEY(automation, key)) WITHOUT ROWID;
                    ALTER TABLE task_items ADD COLUMN waiting_on TEXT;
                    ALTER TABLE task_suggestions ADD COLUMN waiting_on TEXT;
                    CREATE TABLE task_due_marks(task TEXT PRIMARY KEY, due REAL NOT NULL, snoozed_until REAL) WITHOUT ROWID;
                    """)
                try db.execute("INSERT INTO task_due_marks(task, due, snoozed_until) VALUES('send-the-deck', ?, NULL)", [clock.timeIntervalSince1970])
                try db.execute("""
                    INSERT INTO task_items(id, title, notes, status, source, created, updated, waiting_on)
                    VALUES('send-the-deck', 'Send the deck', '', 'backlog', 'meeting', ?, ?, 'Ana')
                    """, [clock.timeIntervalSince1970, clock.timeIntervalSince1970])
                try db.execute("""
                    INSERT INTO task_suggestions(id, title, notes, url, automation, automation_name, created)
                    VALUES('review-pr-12', 'Review PR 12', 'From the watcher', 'https://example.com/pr/12', 'prs', 'PRs', ?)
                    """, [clock.timeIntervalSince1970])
                try db.execute("INSERT INTO task_suggestion_keys(automation, key, at) VALUES('prs', '12', ?)", [clock.timeIntervalSince1970])
                try db.script("PRAGMA user_version = 203")
            }
        }
        let migrated = try Database(path: path, migrations: AppMigrations.all)
        XCTAssertEqual(migrated.schemaVersion, AppMigrations.all.map(\.version).max())
        let reopened = TaskStore(database: migrated, now: { [unowned self] in clock }, keepDoneDays: { 30 })
        XCTAssertEqual(reopened.suggestions, [TaskSuggestion(id: "review-pr-12", title: "Review PR 12", due: nil, notes: "From the watcher",
                                                             url: URL(string: "https://example.com/pr/12"),
                                                             origin: .automation(id: "prs", name: "PRs"), created: clock)])
        XCTAssertEqual(reopened.suggest([TaskSuggestion.Draft(key: "12", title: "Something else", due: nil)], automation: "prs", name: "PRs"), [],
                       "the stored key survives")
        XCTAssertEqual(reopened.task("send-the-deck")?.waitingOn, "Ana")
        XCTAssertEqual(reopened.dueMarks(), ["send-the-deck": TaskDueMark(due: clock, snoozedUntil: nil)])
    }

    func testNoTwoMigrationsShareAVersionAndNewOnesComeAfterEveryOldOne() {
        let versions = AppMigrations.all.map(\.version)
        XCTAssertEqual(Set(versions).count, versions.count, "no two migrations share a version")
        // A database that already ran 431 skips anything numbered at or below it.
        XCTAssertTrue(CaptureStore.migrations.allSatisfy { $0.version > 431 }, "a database at the old latest version would skip them")
        XCTAssertTrue(TaskStore.migrations.contains { $0.version == 441 })
    }

    // MARK: Waiting on

    func testWaitingOnSuggestionBecomesAWaitingTask() throws {
        store.suggest([("Send the deck", "Friday", "Ana"), ("Book the room", nil, nil), ("Long", nil, String(repeating: "a", count: 150))],
                      meeting: meeting)
        XCTAssertEqual(store.suggestions.map(\.id), ["book-the-room", "long", "send-the-deck"])
        XCTAssertEqual(store.suggestions.map(\.waitingOn), [nil, String(repeating: "a", count: 100), "Ana"], "a long owner is cut, not dropped")
        XCTAssertEqual(makeStore().suggestions, store.suggestions, "the owner survives a restart")

        let deck = try store.accept("send-the-deck")
        XCTAssertEqual(deck.waitingOn, "Ana")
        XCTAssertEqual(deck.waitingLabel, "Waiting on Ana")
        XCTAssertEqual(deck.status, .backlog)
        XCTAssertEqual(deck.notes, "Due (from the meeting): Friday")
        XCTAssertTrue(try XCTUnwrap(store.history(deck.id).first?.detail).hasPrefix("backlog: Send the deck (waiting on Ana) [source: meeting "))
        XCTAssertEqual(makeStore().task(deck.id)?.waitingOn, "Ana")
        XCTAssertNil(try store.accept("book-the-room").waitingOn)
    }

    func testAutomationSuggestionsAreNeverWaitingOn() throws {
        let url = URL(string: "https://github.com/acme/app/pull/3")!
        store.suggest([draft("3", "Review PR 3", url: url)], automation: "gh", name: "GitHub")
        XCTAssertNil(store.suggestions.first?.waitingOn)
        XCTAssertNil(store.suggestions.first?.waitingLabel)
        let item = try store.accept("review-pr-3")
        XCTAssertNil(item.waitingOn)
        XCTAssertEqual(item.links, [TaskLink(kind: .url, ref: url.absoluteString, label: nil)])
        XCTAssertEqual(item.source, .automation)
    }

    func testWaitingOnNeverNeedsTheUser() throws {
        let id = try store.create(title: "Approve the budget", status: .needsYou, source: .meeting, waitingOn: "Them", by: "user").id
        try store.create(title: "Mine", status: .inProgress, source: .chat, by: "user")
        XCTAssertFalse(try XCTUnwrap(store.task(id)).needsUser)
        XCTAssertEqual(store.task(id)?.waitingLabel, "Waiting on them")
        XCTAssertEqual(store.activeCount, 1)

        try store.update(id, waitingOn: .some(nil), by: "agent:mcp")
        XCTAssertTrue(try XCTUnwrap(store.task(id)).needsUser)
        XCTAssertEqual(store.activeCount, 2)
        XCTAssertEqual(store.history(id).last?.detail, "waiting on: none")
    }

    func testWaitingOnThroughCall() throws {
        let created = try call("create", ["title": "Send the deck", "waiting_on": "  Ana  ", "origin": ["kind": "chat", "ref": "chat-1", "reason": "test"]])
        XCTAssertEqual(created["waiting_on"] as? String, "Ana")
        let id = try XCTUnwrap(created["id"] as? String)
        XCTAssertEqual(try call("update", ["id": id, "changes": ["waiting_on": "Priya"]])["waiting_on"] as? String, "Priya")
        XCTAssertEqual(store.history(id).last?.detail, "waiting on: Priya")
        XCTAssertEqual(try call("update", ["id": id, "changes": ["title": "Send the new deck"]])["waiting_on"] as? String, "Priya",
                       "absent, it stays")
        XCTAssertNil(try call("update", ["id": id, "changes": ["waiting_on": NSNull()]])["waiting_on"])
        XCTAssertNil(try call("create", ["title": "Blank owner", "waiting_on": "   ", "origin": ["kind": "chat", "ref": "c", "reason": "r"]])["waiting_on"])

        XCTAssertEqual(callError("create", ["title": "x", "waiting_on": 7, "origin": ["kind": "chat", "ref": "c", "reason": "r"]]), "waiting_on must be a string")
        XCTAssertNotNil(callError("update", ["id": id, "changes": ["waiting_on": String(repeating: "a", count: 101)]]))
    }

    func testMigration304KeepsExistingTasksAndSuggestions() throws {
        let file = dir.appendingPathComponent("ironpet.db")
        let before = AppMigrations.all.filter { $0.version < 304 }
        let id = "ship-it"
        var old: Database? = try Database(path: file, migrations: before)
        let time = clock.timeIntervalSince1970
        try old?.write { db in
            try db.execute("""
                INSERT INTO task_items(id, title, notes, status, source, due, created, updated, closed)
                VALUES(?, 'Ship it', '', 'needs_you', 'chat', NULL, ?, ?, NULL)
                """, [id, time, time])
            try db.execute("""
                INSERT INTO task_suggestions(id, title, due, meeting, created) VALUES('book-the-room', 'Book the room', 'Friday', ?, ?)
                """, [meeting.path, time])
            try db.execute("""
                INSERT INTO task_suggestions(id, title, url, automation, automation_name, created)
                VALUES('reply-to-sam', 'Reply to Sam', 'https://mail.example.com/m/1', 'gmail', 'Gmail', ?)
                """, [time + 1])
        }
        old = nil

        let database = try Database(path: file, migrations: AppMigrations.all)
        XCTAssertGreaterThanOrEqual(database.schemaVersion, 304)
        let upgraded = TaskStore(database: database, now: { [unowned self] in clock }, keepDoneDays: { 30 })
        XCTAssertEqual(upgraded.task(id)?.title, "Ship it")
        XCTAssertNil(upgraded.task(id)?.waitingOn)
        XCTAssertEqual(upgraded.task(id)?.needsUser, true)
        XCTAssertEqual(upgraded.suggestions.map(\.title), ["Book the room", "Reply to Sam"])
        XCTAssertEqual(upgraded.suggestions.map(\.origin), [.meeting(meeting), .automation(id: "gmail", name: "Gmail")])
        XCTAssertEqual(upgraded.suggestions.last?.url?.absoluteString, "https://mail.example.com/m/1")
        XCTAssertTrue(upgraded.suggestions.allSatisfy { $0.waitingOn == nil })
        try upgraded.update(id, waitingOn: "Ana", by: "user")
        XCTAssertEqual(upgraded.task(id)?.waitingOn, "Ana")
    }

    func testMeetingSummaryLeavesPendingSuggestionsAndOneInfoBubble() throws {
        let added = store.suggest([("Send the invoice", nil, nil), ("Send the deck", nil, "Ana")], meeting: meeting)
        XCTAssertEqual(store.suggestions.count, 2)
        XCTAssertTrue(store.tasks.isEmpty, "no task is created")
        let bubbles = BubbleStore()
        Announcer.showTaskSuggestions(added, in: bubbles)
        XCTAssertEqual(bubbles.bubbles.count, 1)
        let bubble = try XCTUnwrap(bubbles.bubbles.first)
        XCTAssertEqual(bubble.title, "From your meeting")
        XCTAssertTrue(bubble.actions.isEmpty)
        XCTAssertEqual(bubble.body, "2 suggestions for review\nSend the invoice")

        let watcher = Announcer.taskSuggestionsBubble([TaskSuggestion(id: "a", title: "Reply to Sam", origin: .automation(id: "gmail", name: "Gmail"),
                                                                       created: clock)])
        XCTAssertEqual(watcher?.title, "Gmail")
        XCTAssertEqual(watcher?.body, "1 suggestion for review\nReply to Sam")
        XCTAssertNil(Announcer.taskSuggestionsBubble([]))
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
