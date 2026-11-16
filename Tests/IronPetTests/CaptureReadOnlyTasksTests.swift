import XCTest
@testable import IronPet

/// The capture analysis turn reads text other people wrote, so its only tools are `tasks_list` and `tasks_get`. The server enforces that on
/// its own path, whatever the client sends.
@MainActor
final class CaptureReadOnlyTasksTests: XCTestCase {
    private var store: TaskStore!
    private var server: EventServer!

    override func setUp() async throws {
        try await super.setUp()
        store = TaskStore(database: Database.open(path: nil, migrations: AppMigrations.all).database, keepDoneDays: { 30 })
        server = EventServer(token: "ro-token") { _ in }
        server.onAgentAPI = { [weak self] request, respond in
            MCPEndpoint.route(request, automations: { nil }, tasks: { self?.store }, respond: respond)
        }
        try server.start(preferredPort: 47460)
    }

    override func tearDown() async throws {
        server = nil
        store = nil
        try await super.tearDown()
    }

    private func rpc(_ path: String, _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("ro-token", forHTTPHeaderField: "x-ironpet-token")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 3, "method": method, "params": params])
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func call(_ name: String, _ args: [String: Any] = [:], path: String = MCPEndpoint.readOnlyTasksPath) async throws -> (text: String, isError: Bool) {
        let reply = try await rpc(path, "tools/call", ["name": name, "arguments": args])
        let result = try XCTUnwrap(reply["result"] as? [String: Any], "\(reply)")
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    func testTheReadOnlyScopeListsExactlyTheTwoReadTools() async throws {
        let reply = try await rpc(MCPEndpoint.readOnlyTasksPath, "tools/list")
        let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), ["tasks_list", "tasks_get"])
        // The full endpoint is unchanged.
        let full = try await rpc("/mcp", "tools/list")
        let names = Set(((full["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["tasks_create", "tasks_update", "tasks_close", "tasks_delete"]))
    }

    func testWriteToolsAreRefusedAndChangeNothing() async throws {
        let task = try store.create(title: "Send the Acme contract", source: .user, by: "user")
        let before = store.tasks
        let attempts: [(String, [String: Any])] = [
            ("tasks_create", ["title": "Wire money to account 123"]),
            ("tasks_update", ["id": task.id, "changes": ["title": "Hacked"]]),
            ("tasks_close", ["id": task.id]),
            ("tasks_delete", ["id": task.id]),
            ("automations_list", [:]),
            ("automations_create", ["name": "x", "trigger": ["type": "interval", "minutes": 1], "action": ["type": "shell", "command": "touch /tmp/pwned"]]),
            ("automations_run_now", ["id": "x"]),
        ]
        for (name, args) in attempts {
            let result = try await call(name, args)
            XCTAssertTrue(result.isError, "\(name) must be refused")
            XCTAssertTrue(result.text.contains("not available"), "\(name): \(result.text)")
        }
        XCTAssertEqual(store.tasks, before, "no task changed")
        XCTAssertEqual(store.history(task.id).count, 1, "and nothing was written to its history")
    }

    func testListWithDoneAndStatusFilterAndGetWork() async throws {
        let open = try store.create(title: "Open one", source: .user, by: "user")
        let done = try store.create(title: "Finished one", source: .user, by: "user")
        try store.close(done.id, note: "shipped", by: "user")
        let openOnly = try await call("tasks_list")
        XCTAssertFalse(openOnly.isError)
        XCTAssertTrue(openOnly.text.contains(open.id))
        XCTAssertFalse(openOnly.text.contains(done.id), "done tasks are left out unless asked for")
        let withDone = try await call("tasks_list", ["include_done": true])
        XCTAssertTrue(withDone.text.contains(done.id))
        XCTAssertTrue(withDone.text.contains("\"closed\""), "with when it was closed, so recent ones can be told apart")
        let onlyDone = try await call("tasks_list", ["status": "done"])
        XCTAssertTrue(onlyDone.text.contains(done.id))
        XCTAssertFalse(onlyDone.text.contains(open.id))
        let one = try await call("tasks_get", ["id": done.id])
        XCTAssertTrue(one.text.contains("shipped"), "tasks_get returns the history")
    }

    func testTheReadOnlyPathNeedsTheTokenAndPostsOnly() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)\(MCPEndpoint.readOnlyTasksPath)")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
    }

    func testTheStdioBridgeFlagPicksTheReadOnlyPath() {
        XCTAssertEqual(MCPEndpoint.readOnlyTasksPath, "/mcp/tasks-readonly")
    }

    // MARK: The turn's MCP configuration

    func testTheCaptureTurnGetsOnlyTheReadOnlyServerAndOtherRestrictedRunsGetNone() async throws {
        let saved = (ACPBackend.readOnlyTasksMCPServer, ACPBackend.defaultMCPServers)
        defer { (ACPBackend.readOnlyTasksMCPServer, ACPBackend.defaultMCPServers) = saved }
        let readOnly: JSON = ["name": "ironpet", "command": "/x/IronPet", "args": ["mcp", "--tasks-readonly"], "env": [JSON]()]
        let full: JSON = ["name": "ironpet", "command": "/x/IronPet", "args": ["mcp"], "env": [JSON]()]
        ACPBackend.readOnlyTasksMCPServer = { readOnly }
        ACPBackend.defaultMCPServers = { [full] }
        let agent = ACPAgent(id: "fake", name: "Fake", command: "/nonexistent", args: [], helper: nil)

        let capture = ACPBackend(agent: agent)
        capture.restricted = true
        capture.readOnlyTaskTools = true
        XCTAssertEqual(capture.sessionMCPServers.count, 1)
        XCTAssertEqual(capture.sessionMCPServers.first?["args"] as? [String], ["mcp", "--tasks-readonly"])

        let meeting = ACPBackend(agent: agent)
        meeting.restricted = true
        XCTAssertTrue(meeting.sessionMCPServers.isEmpty, "meeting summaries and automations still get no MCP servers")

        let chat = ACPBackend(agent: agent)
        XCTAssertEqual(chat.sessionMCPServers.first?["args"] as? [String], ["mcp"])
    }
}
