import XCTest
@testable import IronPet

@MainActor
final class MCPEndpointTests: XCTestCase {
    private var tasks: TaskStore!

    override func setUp() async throws {
        try await super.setUp()
        tasks = TaskStore(database: Database.open(path: nil, migrations: AppMigrations.all).database, keepDoneDays: { 30 })
    }

    override func tearDown() async throws {
        tasks = nil
        try await super.tearDown()
    }

    private func rpc(_ method: String, _ params: [String: Any] = [:], tasks: TaskStore?) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 7, "method": method, "params": params])
        let (status, data) = await MCPEndpoint.handle(body, automations: nil, tasks: tasks.map { TasksAPI(store: $0) })
        XCTAssertEqual(status, "200 OK")
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(reply["id"] as? Int, 7)
        return reply
    }

    private func tool(_ name: String, _ args: [String: Any], tasks: TaskStore?) async throws -> (text: String, isError: Bool) {
        let reply = try await rpc("tools/call", ["name": name, "arguments": args], tasks: tasks)
        let result = try XCTUnwrap(reply["result"] as? [String: Any], "\(reply)")
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    func testToolsListHasAutomationAndTaskTools() async throws {
        let reply = try await rpc("tools/list", tasks: nil)
        let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["automations_list", "automations_create", "automations_run_now", "automations_history"]))
        XCTAssertEqual(Set(names.filter { $0.hasPrefix("tasks_") }),
                       ["tasks_list", "tasks_get", "tasks_create", "tasks_update", "tasks_close", "tasks_delete",
                        "tasks_suggest", "tasks_suggestions_list", "tasks_suggestion_accept", "tasks_suggestion_reject"])
        XCTAssertEqual(Set(names.filter { $0.hasPrefix("screen_") }), ["screen_search", "screen_window"], "the screen tools are listed for the chat agents")
        for tool in tools {
            let schema = tool["inputSchema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object", "\(tool["name"] ?? "")")
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
        }
        let create = try XCTUnwrap(tools.first { $0["name"] as? String == "tasks_create" })
        XCTAssertTrue((create["description"] as? String ?? "").contains("needs_you"))
        XCTAssertEqual((create["inputSchema"] as? [String: Any])?["required"] as? [String], ["title", "origin"])
    }

    func testInitializeMentionsAutomationsAndTasks() async throws {
        let reply = try await rpc("initialize", ["protocolVersion": "2025-06-18"], tasks: nil)
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        let instructions = result["instructions"] as? String ?? ""
        XCTAssertTrue(instructions.contains("automations"))
        XCTAssertTrue(instructions.contains("task list"))
    }

    func testSuggestCreatesASuggestionAndRefusesIncompleteCalls() async throws {
        let origin: [String: Any] = ["kind": "email", "ref": "mail:abc", "reason": "Ana asked for a date"]
        let made = try await tool("tasks_suggest", ["id": "mail:abc", "title": "Reply to Ana", "origin": origin], tasks: tasks)
        XCTAssertFalse(made.isError, made.text)
        XCTAssertEqual(tasks.suggestions.map(\.title), ["Reply to Ana"])
        XCTAssertEqual(tasks.tasks, [], "a suggestion is never a task")
        XCTAssertTrue(try XCTUnwrap(tasks.suggestions.first?.sourceRef).contains("Ana asked for a date"))
        let again = try await tool("tasks_suggest", ["id": "mail:abc", "title": "Another title", "origin": origin], tasks: tasks)
        XCTAssertFalse(again.isError, again.text)
        XCTAssertEqual(tasks.suggestions.count, 1, "same id is ignored")

        for (missing, args) in [("title", ["id": "m2", "origin": origin] as [String: Any]),
                                ("id", ["title": "No id", "origin": origin]),
                                ("origin", ["id": "m3", "title": "No origin"]),
                                ("origin.reason", ["id": "m4", "title": "No reason", "origin": ["kind": "email", "ref": "r"]])] {
            let refused = try await tool("tasks_suggest", args, tasks: tasks)
            XCTAssertTrue(refused.isError, "missing \(missing): \(refused.text)")
        }
        XCTAssertEqual(tasks.suggestions.count, 1, "refused calls create nothing")
    }

    func testCreateThenListRoundTripsThroughTheStore() async throws {
        let created = try await tool("tasks_create", ["title": "Review the release notes", "notes": "Before Friday", "status": "in_progress",
                                                      "links": [["kind": "url", "ref": "https://example.com/pr/1", "label": "PR"]],
                                                      "origin": ["kind": "chat", "ref": "chat-1", "reason": "test"]], tasks: tasks)
        XCTAssertFalse(created.isError, created.text)
        XCTAssertTrue(created.text.contains("\"id\" : \"review-the-release-notes\""), created.text)
        XCTAssertEqual(tasks.tasks.map(\.status), [.inProgress])
        XCTAssertEqual(tasks.tasks.first?.links.first?.ref, "https://example.com/pr/1")
        XCTAssertEqual(tasks.history("review-the-release-notes").first?.by, "agent:mcp")

        let listed = try await tool("tasks_list", [:], tasks: tasks)
        XCTAssertFalse(listed.isError, listed.text)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(listed.text.utf8)) as? [String: Any])
        let items = try XCTUnwrap(object["tasks"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["id"] as? String }, ["review-the-release-notes"])
        XCTAssertEqual(items.first?["status"] as? String, "in_progress")

        let closed = try await tool("tasks_close", ["id": "review-the-release-notes", "note": "Shipped"], tasks: tasks)
        XCTAssertFalse(closed.isError, closed.text)
        let open = try await tool("tasks_list", [:], tasks: tasks)
        XCTAssertFalse(open.text.contains("review-the-release-notes"), "done tasks are left out by default")
    }

    func testWaitingOnIsInTheSchemaAndRoundTrips() async throws {
        let reply = try await rpc("tools/list", tasks: nil)
        let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        func properties(_ name: String) -> [String: Any] {
            let schema = tools.first { $0["name"] as? String == name }?["inputSchema"] as? [String: Any]
            return schema?["properties"] as? [String: Any] ?? [:]
        }
        XCTAssertNotNil(properties("tasks_create")["waiting_on"])
        XCTAssertNotNil((properties("tasks_update")["changes"] as? [String: Any]).flatMap { $0["properties"] as? [String: Any] }?["waiting_on"])

        let created = try await tool("tasks_create", ["title": "Send the deck", "waiting_on": "Ana", "origin": ["kind": "chat", "ref": "chat-1", "reason": "test"]], tasks: tasks)
        XCTAssertFalse(created.isError, created.text)
        XCTAssertEqual(tasks.task("send-the-deck")?.waitingOn, "Ana")
        let got = try await tool("tasks_get", ["id": "send-the-deck"], tasks: tasks)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(got.text.utf8)) as? [String: Any])
        XCTAssertEqual(object["waiting_on"] as? String, "Ana")

        let cleared = try await tool("tasks_update", ["id": "send-the-deck", "changes": ["waiting_on": NSNull()]], tasks: tasks)
        XCTAssertFalse(cleared.isError, cleared.text)
        XCTAssertNil(tasks.task("send-the-deck")?.waitingOn)
    }

    func testStoreValidationErrorsReachTheAgent() async throws {
        let bad = try await tool("tasks_create", ["title": "  ", "origin": ["kind": "chat", "ref": "chat-1", "reason": "test"]], tasks: tasks)
        XCTAssertTrue(bad.isError)
        XCTAssertEqual(bad.text, "title is empty")
        let missing = try await tool("tasks_get", ["id": "nope"], tasks: tasks)
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("no task"), missing.text)
    }

    func testUnknownToolIsAnInvalidParamsError() async throws {
        let reply = try await rpc("tools/call", ["name": "notes_add", "arguments": [:]], tasks: tasks)
        XCTAssertNil(reply["result"])
        let error = try XCTUnwrap(reply["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertEqual(error["message"] as? String, "unknown tool notes_add")
    }

    func testToolsWithoutTheirStoreReportAnErrorInsteadOfFailing() async throws {
        let task = try await tool("tasks_list", [:], tasks: nil)
        XCTAssertTrue(task.isError)
        XCTAssertTrue(task.text.contains("not available"), task.text)
        let automation = try await tool("automations_list", [:], tasks: tasks)
        XCTAssertTrue(automation.isError)
        XCTAssertTrue(automation.text.contains("not available"), automation.text)
    }

    func testNotificationsParseErrorsAndUnknownMethods() async throws {
        let notification = await MCPEndpoint.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8), automations: nil, tasks: tasks.map { TasksAPI(store: $0) })
        XCTAssertEqual(notification.status, "202 Accepted")
        XCTAssertTrue(notification.body.isEmpty)
        let garbage = await MCPEndpoint.handle(Data("not json".utf8), automations: nil, tasks: tasks.map { TasksAPI(store: $0) })
        XCTAssertEqual(garbage.status, "400 Bad Request")
        let unknown = try await rpc("resources/list", tasks: tasks)
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        let ping = try await rpc("ping", tasks: tasks)
        XCTAssertNotNil(ping["result"] as? [String: Any])
    }
}
