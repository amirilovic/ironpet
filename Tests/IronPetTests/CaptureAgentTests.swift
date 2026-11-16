import XCTest
@testable import IronPet

/// S6 through the real harness path: `ACPCaptureRunner` drives a scripted agent over ACP.
final class CaptureAgentTests: XCTestCase {
    private var dir: URL!

    private static let script = #"""
    #!/usr/bin/env python3
    import json, os, sys
    log = open(os.environ["FAKE_LOG"], "a")
    def send(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    sid = None
    for line in sys.stdin:
        m = json.loads(line); log.write(line); log.flush()
        method, mid, p = m.get("method"), m.get("id"), m.get("params", {})
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1, "agentCapabilities": {}, "authMethods": []}})
        elif method == "session/new":
            sid = "sess-1"
            send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": sid,
                  "models": {"currentModelId": "m1", "availableModels": [{"modelId": "m1", "name": "One"}, {"modelId": "big", "name": "Big"}]}}})
        elif method in ("session/set_model", "session/set_mode"):
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
        elif method == "session/prompt":
            # Ask for permissions first: a shell command, a task lookup and a task write. Only the lookup may be allowed.
            asks = [(900, "`touch x`", "execute", None), (901, "ironpet tasks_list", "other", "mcp__ironpet__tasks_list"),
                    (902, "ironpet tasks_create", "other", "mcp__ironpet__tasks_create")]
            for rid, title, kind, tool in asks:
                call = {"toolCallId": "t%d" % rid, "title": title, "kind": kind}
                if tool: call["_meta"] = {"claudeCode": {"toolName": tool}}
                send({"jsonrpc": "2.0", "id": rid, "method": "session/request_permission", "params": {"sessionId": sid, "toolCall": call,
                      "options": [{"optionId": "yes", "name": "Allow", "kind": "allow_once"}, {"optionId": "no", "name": "Reject", "kind": "reject_once"}]}})
                reply = json.loads(sys.stdin.readline()); log.write(json.dumps(reply) + "\n"); log.flush()
            answer = open(os.environ["FAKE_ANSWER"]).read()
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update":
                  {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": answer}}}})
            send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
    """#

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-capture-acp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appendingPathComponent("fake-agent")
        try Self.script.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        setenv("FAKE_LOG", dir.appendingPathComponent("log").path, 1)
        setenv("FAKE_ANSWER", dir.appendingPathComponent("answer").path, 1)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var agent: ACPAgent { ACPAgent(id: "fake", name: "Fake", command: dir.appendingPathComponent("fake-agent").path, args: [], helper: nil) }

    private func logged() -> [[String: Any]] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func testThreeAllowedItemsInOneThreadMakeOneAgentRunWithTheOpenTasks() async throws {
        let store = CaptureStore.inMemory()
        let tasks = MemoryTaskList()
        let createdTask = await tasks.create(title: "Send the Acme contract", notes: "", due: nil)
        let task = try XCTUnwrap(createdTask)
        func message(_ lines: [String], at: Date) throws -> Int64 {
            let item = CaptureItem(app: CaptureApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack"), threadKey: "slack:ana", threadTitle: "Ana",
                                   content: .conversation(title: "Ana", isGroup: false, messages: lines.map { CaptureMessage(author: "Ana", text: $0) }), parser: "test")
            return try XCTUnwrap(store.ingest(item, now: at).itemId)
        }
        let t0 = Date().addingTimeInterval(-3600)
        let a = try message(["Can you send the invoice to Dana?"], at: t0)
        _ = try message(["Can you send the invoice to Dana?", "Also call me tomorrow"], at: t0.addingTimeInterval(10))
        let c = try message(["Can you send the invoice to Dana?", "Also call me tomorrow", "The contract is due 2026-11-20"], at: t0.addingTimeInterval(20))
        try """
            {"new_tasks":[{"title":"Send the invoice to Dana","source_items":[\(a)],"quote":"send the invoice to Dana"}],
             "updates":[{"task_id":"\(task.id)","due":"2026-11-20","source_items":[\(c)],"quote":"The contract is due 2026-11-20"}]}
            """.write(to: dir.appendingPathComponent("answer"), atomically: true, encoding: .utf8)

        let saved = ACPBackend.readOnlyTasksMCPServer
        defer { ACPBackend.readOnlyTasksMCPServer = saved }
        ACPBackend.readOnlyTasksMCPServer = { ["name": "ironpet", "command": "/x/IronPet", "args": ["mcp", "--tasks-readonly"], "env": [JSON]()] }
        let filter = CaptureDecisionFilter(settings: { Config.ScreenCapture.Decision() }, makeClient: { _, _ in AlwaysSafe() })
        _ = await filter.run(on: store, tasks: tasks)
        XCTAssertEqual(store.count(inState: "ready"), 3)
        let workspace = dir.appendingPathComponent("agent-folder")
        let analyzer = CaptureAnalyzer(store: store, tasks: tasks, settings: { .init(agent: "fake", model: "big", delay: 180, sendApps: ["com.tinyspeck.slackmacgap"]) },
                                       runner: ACPCaptureRunner(timeout: 30), resolveAgent: { _ in self.agent }, workspace: workspace)
        var shown: [CaptureProposal] = []
        analyzer.onProposals = { shown = $0 }
        let result = await analyzer.runIfDue(now: Date())
        let proposals = try XCTUnwrap(result)

        XCTAssertEqual(Set(proposals.map(\.kind)), [.newTask, .update])
        XCTAssertEqual(shown, proposals)
        let log = logged()
        let prompts = log.filter { $0["method"] as? String == "session/prompt" }
        XCTAssertEqual(prompts.count, 1, "one run")
        let promptText = ((prompts[0]["params"] as? [String: Any])?["prompt"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        XCTAssertFalse(promptText.contains("Send the Acme contract"), "the open tasks are not pasted into the prompt")
        XCTAssertFalse(promptText.contains("EXISTING OPEN TASKS"))
        XCTAssertTrue(promptText.contains("tasks_list"))
        XCTAssertTrue(promptText.contains("send the invoice to Dana"))
        // The selected model is applied, and the agent works in its own folder, not the chat's.
        XCTAssertTrue(log.contains { $0["method"] as? String == "session/set_model" && ($0["params"] as? [String: Any])?["modelId"] as? String == "big" })
        let session = try XCTUnwrap(log.first { $0["method"] as? String == "session/new" })
        let cwd = (session["params"] as? [String: Any])?["cwd"] as? String
        XCTAssertEqual(cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, workspace.resolvingSymlinksInPath().path)
        // The shell command and the task write were refused. The task lookup was allowed.
        func outcome(_ id: Int) -> String? {
            let reply = log.first { ($0["id"] as? Int) == id }
            return ((reply?["result"] as? [String: Any])?["outcome"] as? [String: Any])?["optionId"] as? String
        }
        XCTAssertEqual(outcome(900), "no")
        XCTAssertEqual(outcome(901), "yes")
        XCTAssertEqual(outcome(902), "no")
        // The session got exactly one MCP server, the read-only one.
        let servers = (session["params"] as? [String: Any])?["mcpServers"] as? [[String: Any]] ?? []
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?["args"] as? [String], ["mcp", "--tasks-readonly"])
        XCTAssertEqual(store.sendLog().first?.harness, "fake")
        XCTAssertEqual(store.sendLog().first?.model, "big")
        XCTAssertEqual(store.sendLog().first?.items.count, 3)
    }

    /// The user's chat is theirs: a capture run, Add and Ignore must not touch its session, folder, agent, model, draft or messages.
    @MainActor
    func testACaptureRunLeavesTheUsersChatSessionAndFolderUnchanged() async throws {
        let chat = ChatSession(restore: false)
        let chatFolder = dir.appendingPathComponent("chat-folder")
        try FileManager.default.createDirectory(at: chatFolder, withIntermediateDirectories: true)
        chat.workspace = chatFolder
        chat.turnRunner = { _, onEvent in onEvent(.assistant("hello")); onEvent(.finished(error: nil)) }
        chat.input = "hi"
        chat.send()
        for _ in 0..<10 { await Task.yield() }
        chat.input = "a half-typed draft"
        func state() -> [String] {
            ["folder=\(chat.workspace?.path ?? "-")", "session=\(chat.sessionID ?? "-")", "agent=\(chat.agent.id)", "model=\(chat.model ?? "-")",
             "input=\(chat.input)", "items=\(chat.items.count)", "history=\(chat.history.count)", "running=\(chat.isRunning)"]
        }
        let before = state()
        XCTAssertTrue(before.contains("folder=\(chatFolder.path)"))

        let store = CaptureStore.inMemory()
        let item = CaptureItem(app: CaptureApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack"), threadKey: "slack:ana", threadTitle: "Ana",
                               content: .conversation(title: "Ana", isGroup: false, messages: [CaptureMessage(author: "Ana", text: "Please send the invoice")]), parser: "test")
        let id = try XCTUnwrap(store.ingest(item, now: Date().addingTimeInterval(-3600)).itemId)
        try """
            {"new_tasks":[{"title":"Send the invoice","source_items":[\(id)],"quote":"send the invoice"}]}
            """.write(to: dir.appendingPathComponent("answer"), atomically: true, encoding: .utf8)
        let saved = ACPBackend.readOnlyTasksMCPServer
        defer { ACPBackend.readOnlyTasksMCPServer = saved }
        ACPBackend.readOnlyTasksMCPServer = { ["name": "ironpet", "command": "/x/IronPet", "args": ["mcp", "--tasks-readonly"], "env": [JSON]()] }
        let tasks = MemoryTaskList()
        let filter = CaptureDecisionFilter(settings: { Config.ScreenCapture.Decision() }, makeClient: { _, _ in AlwaysSafe() })
        _ = await filter.run(on: store, tasks: tasks)
        let captureFolder = dir.appendingPathComponent("capture-agent")
        let analyzer = CaptureAnalyzer(store: store, tasks: tasks, settings: { .init(agent: "fake", model: nil, delay: 180, sendApps: ["com.tinyspeck.slackmacgap"]) },
                                       runner: ACPCaptureRunner(timeout: 30), resolveAgent: { _ in self.agent }, workspace: captureFolder)
        let service = CaptureService(store: store, config: { Config.ScreenCapture() }, tasks: tasks)
        let ran = await analyzer.run()
        let proposals = try XCTUnwrap(ran)
        XCTAssertEqual(proposals.count, 1)
        _ = await service.accept(proposals[0])
        service.ignore(proposals[0])

        XCTAssertEqual(state(), before, "the chat session, folder, agent, model, draft and messages are the same")
        let log = logged()
        let session = try XCTUnwrap(log.first { $0["method"] as? String == "session/new" })
        let cwd = (session["params"] as? [String: Any])?["cwd"] as? String
        XCTAssertEqual(cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, captureFolder.resolvingSymlinksInPath().path,
                       "the agent ran in its own folder, not the chat's")
        XCTAssertFalse(log.contains { $0["method"] as? String == "session/load" }, "it never resumed the chat's session")
    }
}

private struct AlwaysSafe: CaptureDecisionClient {
    func probabilities(text: String, existingTasks: [String: String], questions: [(name: String, instructions: String)]) async throws -> [String: Double] {
        Dictionary(uniqueKeysWithValues: questions.map { ($0.name, 0.01) })
    }
}
