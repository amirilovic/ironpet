import XCTest
@testable import IronPet

/// Screen capture proposals wait as suggestions in the task list, and a reviewing agent resolves them over MCP.
@MainActor
final class CaptureSuggestionsTests: XCTestCase {
    private var tasks: TaskStore!
    private var capture: CaptureStore!
    private var database: Database!

    override func setUp() async throws {
        try await super.setUp()
        database = Database.open(path: nil, migrations: AppMigrations.all).database
        tasks = TaskStore(database: database, now: { Date(timeIntervalSince1970: 1_800_000_000) }, keepDoneDays: { 30 })
        capture = CaptureStore.inMemory()
        tasks.ignoreCapture = { [capture] fingerprint, kind in capture?.ignore(fingerprint: fingerprint, kind: kind) }
    }

    override func tearDown() async throws {
        tasks = nil
        capture = nil
        try await super.tearDown()
    }

    private func newTask(_ title: String = "Send the invoice", quote: String = "Please send the invoice") -> CaptureProposal {
        CaptureProposal(id: CaptureStore.fingerprint(kind: "new_task", title: title), kind: .newTask, title: title, notes: "", due: "2026-11-20",
                        taskId: nil, status: nil, sources: [4, 7], quote: quote, diff: [])
    }

    private func closeProposal(for task: TaskItem) -> CaptureProposal {
        CaptureProposal(id: CaptureStore.fingerprint(kind: "update", title: "status: open -> done", taskId: task.id), kind: .update, title: task.title,
                        notes: task.notes, due: nil, taskId: task.id, status: "done", sources: [9], quote: "Merged the release PR",
                        diff: ["status: open -> done"])
    }

    func testNewTaskProposalIsStoredAsSuggestion() throws {
        let stored = tasks.suggest(capture: [newTask()])
        let s = try XCTUnwrap(stored.first)
        XCTAssertEqual(tasks.suggestions, stored)
        XCTAssertEqual(s.title, "Send the invoice")
        XCTAssertEqual(s.quote, "Please send the invoice")
        XCTAssertEqual(s.evidence, [4, 7])
        XCTAssertEqual(s.kind, .newTask)
        XCTAssertEqual(s.origin, .capture(fingerprint: newTask().id))
        XCTAssertTrue(tasks.tasks.isEmpty, "a suggestion is not a task")
        XCTAssertEqual(tasks.suggest(capture: [newTask()]), [], "the same proposal is not stored twice")
        let reopened = TaskStore(database: database, now: { Date(timeIntervalSince1970: 1_800_000_000) }, keepDoneDays: { 30 })
        XCTAssertEqual(reopened.suggestions, stored, "suggestions survive a restart")
    }

    func testCloseProposalLeavesTheTaskUnchanged() throws {
        let task = try tasks.create(title: "Ship the release", source: .chat, by: "test")
        let s = try XCTUnwrap(tasks.suggest(capture: [closeProposal(for: task)]).first)
        XCTAssertEqual(tasks.task(task.id)?.status, .backlog)
        XCTAssertEqual(s.target, task.id)
        XCTAssertEqual(s.changes["status"], "done")
        XCTAssertEqual(s.diff, ["status: open -> done"])
        XCTAssertEqual(s.kind, .update)
    }

    func testListOverMCPShowsEveryOrigin() async throws {
        let task = try tasks.create(title: "Ship the release", source: .chat, by: "test")
        tasks.suggest(capture: [newTask(), closeProposal(for: task)])
        tasks.suggest([("Book the room", nil, nil)], meeting: URL(fileURLWithPath: "/tmp/meeting"))
        tasks.suggest([TaskSuggestion.Draft(key: "1", title: "Review PR 12", due: nil)], automation: "prs", name: "PRs")
        let result = try XCTUnwrap(try? tasks.call("suggestions_list", [:], by: "agent:mcp").get() as? [String: Any])
        let list = try XCTUnwrap(result["suggestions"] as? [[String: Any]])
        XCTAssertEqual(Set(list.compactMap { $0["origin"] as? String }), ["capture", "meeting", "automation"])
        let update = try XCTUnwrap(list.first { $0["kind"] as? String == "update" })
        XCTAssertEqual(update["target"] as? String, task.id)
        XCTAssertEqual(update["target_title"] as? String, "Ship the release")
        XCTAssertEqual((update["changes"] as? [String: String])?["status"], "done")
        XCTAssertEqual(update["quote"] as? String, "Merged the release PR")
        XCTAssertEqual(update["evidence_ids"] as? [Int64], [9])
        XCTAssertNotNil(update["created"])
        let fresh = try XCTUnwrap(list.first { $0["title"] as? String == "Send the invoice" })
        XCTAssertEqual(fresh["kind"] as? String, "new_task")

        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                               "params": ["name": "tasks_suggestions_list", "arguments": [:]]])
        let (_, data) = await MCPEndpoint.handle(body, automations: nil, tasks: tasks)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("evidence_ids"), "the tool is served over MCP")
    }

    func testAcceptingACloseAppliesItAndRecordsTheNote() throws {
        let task = try tasks.create(title: "Ship the release", source: .chat, by: "test")
        let s = try XCTUnwrap(tasks.suggest(capture: [closeProposal(for: task)]).first)
        let result = tasks.call("suggestion_accept", ["id": s.id, "note": "gh pr view shows it merged"], by: "agent:mcp")
        guard case .success = result else { return XCTFail("\(result)") }
        XCTAssertEqual(tasks.task(task.id)?.status, .done)
        XCTAssertTrue(tasks.suggestions.isEmpty)
        let history = tasks.history(task.id)
        XCTAssertTrue(history.contains { $0.kind == .note && $0.detail.contains("gh pr view shows it merged") && $0.by == "agent:mcp" })
    }

    func testAddAllLeavesUpdatesPending() throws {
        let task = try tasks.create(title: "Ship the release", source: .chat, by: "test")
        tasks.suggest(capture: [closeProposal(for: task), newTask()])
        tasks.acceptAll()
        XCTAssertEqual(tasks.task(task.id)?.status, .backlog, "Add all never closes or changes an existing task")
        XCTAssertEqual(tasks.suggestions.map(\.kind), [.update])
        XCTAssertNotNil(tasks.tasks.first { $0.title == "Send the invoice" })
    }

    func testAcceptingANewTaskWithOverrides() throws {
        let s = try XCTUnwrap(tasks.suggest(capture: [newTask()]).first)
        let result = tasks.call("suggestion_accept", ["id": s.id, "title": "Send the October invoice", "due": "2026-11-25", "status": "needs_you",
                                                       "note": "confirmed with Ana"], by: "agent:mcp")
        guard case .success = result else { return XCTFail("\(result)") }
        let item = try XCTUnwrap(tasks.tasks.first)
        XCTAssertEqual(item.title, "Send the October invoice")
        XCTAssertEqual(item.status, .needsYou)
        XCTAssertEqual(item.source, .capture)
        XCTAssertTrue(item.notes.contains("Please send the invoice"))
        XCTAssertTrue(item.notes.contains("From screen capture items 4, 7"))
        XCTAssertTrue(tasks.history(item.id).contains { $0.detail == "confirmed with Ana" })
        XCTAssertTrue(tasks.suggestions.isEmpty)
    }

    func testRejectingACaptureSuggestionRemembersItsFingerprint() throws {
        let proposal = newTask()
        let s = try XCTUnwrap(tasks.suggest(capture: [proposal]).first)
        let result = tasks.call("suggestion_reject", ["id": s.id, "note": "duplicate of the billing task"], by: "agent:mcp")
        guard case .success = result else { return XCTFail("\(result)") }
        XCTAssertTrue(tasks.suggestions.isEmpty)
        XCTAssertTrue(tasks.tasks.isEmpty)
        XCTAssertTrue(capture.isIgnored(proposal.id))

        let item = CaptureStore.Item(id: 4, threadId: 1, threadKey: "k", threadTitle: "t", app: "a", appName: "A", kind: "conversation", at: Date(), version: 1,
                                      body: "Ana: Please send the invoice", state: "ready")
        let answer = #"{"new_tasks":[{"title":"Send the invoice","source_items":[4],"quote":"Please send the invoice"}]}"#
        XCTAssertTrue(CaptureAnalyzer.proposals(from: answer, items: [item], tasks: [], store: capture).isEmpty, "the next run does not propose it again")
    }

    func testUnknownSuggestionIsAnError() {
        guard case .failure = tasks.call("suggestion_accept", ["id": "nope"], by: "agent:mcp") else { return XCTFail("accept") }
        guard case .failure = tasks.call("suggestion_reject", ["id": "nope"], by: "agent:mcp") else { return XCTFail("reject") }
    }

    func testMigrationFromSchema305KeepsSuggestions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-sugg-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("ironpet.db")
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let old = try Database(path: path, migrations: AppMigrations.all.filter { $0.version <= 420 })
            XCTAssertEqual(old.schemaVersion, 420)
            try old.write { db in
                try db.execute("INSERT INTO task_suggestions(id, title, due, meeting, created, waiting_on) VALUES('a', 'Book the room', 'Friday', '/tmp/m', ?, 'Ana')",
                               [time.timeIntervalSince1970])
                try db.execute("INSERT INTO task_suggestions(id, title, notes, url, automation, automation_name, created) VALUES('b', 'Review PR', 'n', 'https://example.com/1', 'prs', 'PRs', ?)",
                               [time.timeIntervalSince1970])
            }
        }
        let migrated = try Database(path: path, migrations: AppMigrations.all)
        XCTAssertEqual(migrated.schemaVersion, AppMigrations.all.map(\.version).max())
        let store = TaskStore(database: migrated, now: { time }, keepDoneDays: { 30 })
        XCTAssertEqual(store.suggestions.map(\.id), ["a", "b"])
        XCTAssertEqual(store.suggestions[0].waitingOn, "Ana")
        XCTAssertEqual(store.suggestions[1].url, URL(string: "https://example.com/1"))
        XCTAssertEqual(store.suggest(capture: [newTask()]).count, 1)
        XCTAssertEqual(try store.accept("a").title, "Book the room")
        XCTAssertThrowsError(try migrated.write { try $0.execute("INSERT INTO task_suggestions(id, title, created) VALUES('x', 'x', 0)") },
                             "a suggestion has exactly one origin")
        XCTAssertThrowsError(try migrated.write {
            try $0.execute("INSERT INTO task_suggestions(id, title, meeting, capture, created) VALUES('y', 'y', 'm', 'c', 0)")
        }, "two origins are refused")
    }

    func testCLIMapsToSuggestionOperations() throws {
        XCTAssertEqual(try TaskCLI.request(["suggestions"]).op, "suggestions_list")
        let accept = try TaskCLI.request(["accept", "send-the-invoice", "--note", "ok", "--due", "2026-11-25"])
        XCTAssertEqual(accept.op, "suggestion_accept")
        XCTAssertEqual(accept.args["id"] as? String, "send-the-invoice")
        XCTAssertEqual(accept.args["due"] as? String, "2026-11-25")
        XCTAssertEqual(try TaskCLI.request(["reject", "x", "--note", "dup"]).args["note"] as? String, "dup")
    }
}

extension CaptureSuggestionsTests {
    func testARunShowsOneInfoBubbleWithNoActions() throws {
        let store = BubbleStore()
        let two = tasks.suggest(capture: [newTask("Send the invoice"), newTask("Book the room")])
        Announcer.showTaskSuggestions(two, in: store)
        XCTAssertEqual(store.bubbles.count, 1)
        let bubble = try XCTUnwrap(store.bubbles.first)
        XCTAssertEqual(bubble.title, "From your screen")
        XCTAssertTrue(bubble.actions.isEmpty)
        XCTAssertNotNil(bubble.expires)
        XCTAssertEqual(bubble.body, "2 suggestions for review\nSend the invoice")

        Announcer.showTaskSuggestions(tasks.suggest(capture: [newTask("Call Sam")]), in: store)
        XCTAssertEqual(store.bubbles.count, 1, "the next run replaces it")
        XCTAssertEqual(store.bubbles.first?.body, "1 suggestion for review\nCall Sam")

        let empty = BubbleStore()
        Announcer.showTaskSuggestions(tasks.suggest(capture: [newTask("Call Sam")]), in: empty)
        XCTAssertTrue(empty.bubbles.isEmpty, "a run that stores nothing shows nothing")
    }
}

extension CaptureSuggestionsTests {
    func testAcceptedCaptureSuggestionRecordsItsProvenance() throws {
        var proposal = newTask()
        proposal.sendLog = 12
        let s = try XCTUnwrap(tasks.suggest(capture: [proposal]).first)
        let ref = try XCTUnwrap(s.sourceRef.flatMap { TaskStore.refValue($0) as? [String: Any] })
        XCTAssertEqual(ref["send_log"] as? Int, 12)
        XCTAssertEqual(ref["items"] as? [Int], [4, 7])
        XCTAssertEqual(ref["fingerprint"] as? String, proposal.id)

        let item = try tasks.accept(s.id, by: "agent:mcp")
        XCTAssertEqual(item.source, .capture)
        XCTAssertEqual(item.sourceRef, s.sourceRef)
        let created = try XCTUnwrap(tasks.history(item.id).first { $0.kind == .created })
        XCTAssertTrue(created.detail.contains("source: capture"), created.detail)
        XCTAssertTrue(created.detail.contains("\"send_log\":12") && created.detail.contains("\"items\":[4,7]"), created.detail)

        let got = try XCTUnwrap(tasks.call("get", ["id": item.id], by: "agent:mcp").get() as? [String: Any])
        XCTAssertEqual(got["source"] as? String, "capture")
        XCTAssertEqual((got["source_ref"] as? [String: Any])?["send_log"] as? Int, 12)
        let listed = try XCTUnwrap(tasks.call("suggestions_list", [:], by: "agent:mcp").get() as? [String: Any])
        XCTAssertNotNil(listed["suggestions"])
    }

    func testAcceptedMeetingSuggestionRecordsTheMeetingPath() throws {
        let folder = URL(fileURLWithPath: "/tmp/ironpet-meetings/2026-11-16 1000")
        let s = try XCTUnwrap(tasks.suggest([("Send the deck", nil, nil)], meeting: folder).first)
        let listed = try XCTUnwrap(tasks.call("suggestions_list", [:], by: "agent:mcp").get() as? [String: Any])
        let row = try XCTUnwrap((listed["suggestions"] as? [[String: Any]])?.first)
        XCTAssertEqual((row["source_ref"] as? [String: Any])?["meeting"] as? String, folder.path)
        let item = try tasks.accept(s.id)
        XCTAssertEqual(item.source, .meeting)
        XCTAssertEqual((TaskStore.refValue(try XCTUnwrap(item.sourceRef)) as? [String: Any])?["meeting"] as? String, folder.path)
        XCTAssertTrue(try XCTUnwrap(tasks.history(item.id).first).detail.contains(folder.path))
    }

    func testAutomationSuggestionRecordsTheAutomation() throws {
        let s = try XCTUnwrap(tasks.suggest([TaskSuggestion.Draft(key: "1", title: "Review PR 12", due: nil)], automation: "prs", name: "PRs").first)
        let ref = try XCTUnwrap(s.sourceRef.flatMap { TaskStore.refValue($0) as? [String: Any] })
        XCTAssertEqual(ref["automation"] as? String, "prs")
        XCTAssertNotNil(ref["at"])
    }

    private func mcp(_ name: String, _ args: [String: Any]) async throws -> (text: String, isError: Bool) {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                               "params": ["name": name, "arguments": args]])
        let (_, data) = await MCPEndpoint.handle(body, automations: nil, tasks: tasks)
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        return (try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String), result["isError"] as? Bool ?? false)
    }

    func testCreateNeedsAnOriginWithEveryField() async throws {
        let good: [String: Any] = ["kind": "pr", "ref": "https://github.com/acme/app/pull/12", "reason": "It waits for the user's review"]
        for (origin, field) in [(nil, "origin"), (["kind": "pr", "ref": "x"], "origin.reason"), (["kind": "pr", "reason": "x"], "origin.ref"),
                                (["kind": "pr", "ref": "  ", "reason": "x"], "origin.ref"), (["kind": "pr", "ref": "x", "reason": ""], "origin.reason"),
                                (["kind": "robot", "ref": "x", "reason": "y"], "origin.kind")] as [([String: Any]?, String)] {
            var args: [String: Any] = ["title": "Review the PR"]
            args["origin"] = origin
            let result = try await mcp("tasks_create", args)
            XCTAssertTrue(result.isError, field)
            XCTAssertTrue(result.text.contains(field), "\(field): \(result.text)")
        }
        XCTAssertTrue(tasks.tasks.isEmpty, "nothing was created")

        let made = try await mcp("tasks_create", ["title": "Review the PR", "origin": good])
        XCTAssertFalse(made.isError, made.text)
        let item = try XCTUnwrap(tasks.tasks.first)
        XCTAssertEqual(item.source, .pr)
        let ref = try XCTUnwrap(TaskStore.refValue(try XCTUnwrap(item.sourceRef)) as? [String: Any])
        XCTAssertEqual(ref["ref"] as? String, "https://github.com/acme/app/pull/12")
        XCTAssertEqual(ref["reason"] as? String, "It waits for the user's review")
        XCTAssertTrue(try XCTUnwrap(tasks.history(item.id).first).detail.contains("It waits for the user's review"))
        let got = try await mcp("tasks_get", ["id": item.id])
        XCTAssertTrue(got.text.contains("\"source\" : \"pr\"") && got.text.contains("source_ref"), got.text)

        let schema = try XCTUnwrap(TaskMCP.tools.first { $0["name"] as? String == "tasks_create" }?["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["title", "origin"])
        let originSchema = try XCTUnwrap((schema["properties"] as? [String: Any])?["origin"] as? [String: Any])
        XCTAssertEqual(originSchema["required"] as? [String], ["kind", "ref", "reason"])
    }

    func testCloseUpdateAndSuggestionToolsNeedANote() async throws {
        let task = try tasks.create(title: "Ship the release", source: .chat, by: "test")
        for note in [nil, "", "   "] as [String?] {
            var args: [String: Any] = ["id": task.id]
            args["note"] = note
            let result = try await mcp("tasks_close", args)
            XCTAssertTrue(result.isError && result.text.contains("note"), result.text)
        }
        XCTAssertEqual(tasks.task(task.id)?.status, .backlog)
        let noNote = try await mcp("tasks_update", ["id": task.id, "changes": ["status": "in_progress"]])
        XCTAssertTrue(noNote.isError && noNote.text.contains("note"), noNote.text)
        let titleOnly = try await mcp("tasks_update", ["id": task.id, "changes": ["title": "Ship the 2.0 release"]])
        XCTAssertFalse(titleOnly.isError, "a change that is not a status change needs no note: \(titleOnly.text)")
        let moved = try await mcp("tasks_update", ["id": task.id, "changes": ["status": "in_progress"], "note": "Started the build"])
        XCTAssertFalse(moved.isError, moved.text)

        let closed = try await mcp("tasks_close", ["id": task.id, "note": "gh pr view 12 shows it merged"])
        XCTAssertFalse(closed.isError, closed.text)
        XCTAssertEqual(tasks.task(task.id)?.status, .done)
        XCTAssertTrue(tasks.history(task.id).contains { $0.detail == "gh pr view 12 shows it merged" })

        let s = try XCTUnwrap(tasks.suggest(capture: [newTask()]).first)
        let accept = try await mcp("tasks_suggestion_accept", ["id": s.id])
        let reject = try await mcp("tasks_suggestion_reject", ["id": s.id, "note": " "])
        XCTAssertTrue(accept.isError && reject.isError)
        XCTAssertEqual(tasks.suggestions.count, 1, "the suggestion is still pending")
    }

    func testExistingRowsKeepNullRefsAfterMigration() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-ref-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("ironpet.db")
        do {
            let old = try Database(path: path, migrations: AppMigrations.all.filter { $0.version <= 420 })
            try old.write { db in
                try db.execute("INSERT INTO task_items(id, title, notes, status, source, created, updated) VALUES('a', 'A', '', 'backlog', 'chat', 0, 0)")
            }
        }
        let migrated = try Database(path: path, migrations: AppMigrations.all)
        let store = TaskStore(database: migrated, keepDoneDays: { 100_000 })
        XCTAssertEqual(store.tasks.map(\.id), ["a"])
        XCTAssertNil(store.tasks[0].sourceRef)
    }
}
