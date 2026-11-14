import XCTest
@testable import IronPet

/// Runs ACPBackend against a scripted agent (a small Python program speaking ACP on stdio).
@MainActor
final class ACPBackendTests: XCTestCase {
    private var dir: URL!

    private static let script = #"""
    #!/usr/bin/env python3
    import json, os, sys, time
    log = open(os.environ["FAKE_LOG"], "a")
    mode = os.environ.get("FAKE_MODE", "")
    def send(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    sid = None
    def update(u): send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": u}})
    for line in sys.stdin:
        m = json.loads(line); log.write(line); log.flush()
        method, mid, p = m.get("method"), m.get("id"), m.get("params", {})
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1,
                  "agentCapabilities": {"loadSession": True, "promptCapabilities": {"image": True}},
                  "authMethods": [{"id": "login", "name": "Log in"}]}})
        elif method in ("session/new", "session/load"):
            if mode == "auth":
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32000, "message": "Authentication required"}}); continue
            sid = p.get("sessionId") or "sess-1"
            if os.environ.get("FAKE_MODE") == "bypass":
                pass
            if method == "session/load": update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "REPLAY"}})
            send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": sid,
                  "modes": {"currentModeId": "bypassPermissions" if mode == "bypass" else "default",
                            "availableModes": [{"id": "default"}, {"id": "bypassPermissions"}]},
                  "models": {"currentModelId": "m1", "availableModels": [{"modelId": "m1", "name": "Model One"}, {"modelId": "m2", "name": "Model Two"}]}}})
        elif method in ("session/set_model", "session/set_mode"):
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
        elif method == "session/prompt":
            text = "".join(b.get("text", "") for b in p["prompt"])
            if "SLOW" in text:
                update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "working"}})
                for l in sys.stdin:
                    c = json.loads(l); log.write(l); log.flush()
                    if c.get("method") == "session/cancel":
                        send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "cancelled"}}); break
                continue
            if "PERMISSION" in text:
                update({"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "`touch x`", "kind": "execute", "status": "pending", "rawInput": {"command": "touch x"}})
                send({"jsonrpc": "2.0", "id": 900, "method": "session/request_permission", "params": {"sessionId": sid,
                      "toolCall": {"toolCallId": "t1", "title": "`touch x`", "kind": "execute"},
                      "options": [{"optionId": "yes", "name": "Allow", "kind": "allow_once"}, {"optionId": "no", "name": "Reject", "kind": "reject_once"}]}})
                reply = json.loads(sys.stdin.readline()); log.write(json.dumps(reply) + "\n"); log.flush()
                ok = reply["result"]["outcome"].get("optionId") == "yes"
                update({"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed" if ok else "failed"})
            update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "pid=%d" % os.getpid()}})
            send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
    """#

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-acp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.script.write(to: dir.appendingPathComponent("fake-agent"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("fake-agent").path)
        setenv("FAKE_LOG", dir.appendingPathComponent("log").path, 1)
        unsetenv("FAKE_MODE")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var agent: ACPAgent { ACPAgent(id: "fake", name: "Fake", command: dir.appendingPathComponent("fake-agent").path, args: [], helper: nil) }

    private func turn(_ prompt: String, resume: String? = nil, model: String? = nil, images: [URL] = []) -> ACPTurn {
        ACPTurn(prompt: prompt, preamble: "PREAMBLE", workspace: dir, resume: resume, model: model, images: images, files: [])
    }

    private func logged() -> [JSON] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? JSON }
    }

    private func run(_ backend: ACPBackend, _ turn: ACPTurn) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        await backend.runTurn(turn) { events.append($0) }
        return events
    }

    private func text(_ events: [AgentEvent]) -> String {
        events.compactMap { if case .assistant(let t) = $0 { return t } else { return nil } }.joined()
    }

    func testTurnStreamsTextAndReportsSessionAndModels() async {
        let backend = ACPBackend(agent: agent)
        let events = await run(backend, turn("hello"))
        XCTAssertTrue(text(events).hasPrefix("pid="))
        guard case .finished(let error) = events.last, error == nil else { return XCTFail("expected a clean finish") }
        XCTAssertTrue(events.contains { if case .session("sess-1") = $0 { return true } else { return false } })
        let models = events.compactMap { event -> [ChatModel]? in if case .models(_, let list) = event { return list } else { return nil } }.first
        XCTAssertEqual(models?.map(\.id), ["m1", "m2"])
        backend.shutdown()
    }

    func testInitializeDeclaresNoFilesystemOrTerminalCapability() async throws {
        let backend = ACPBackend(agent: agent)
        _ = await run(backend, turn("hello"))
        let initialize = try XCTUnwrap(logged().first { $0["method"] as? String == "initialize" })
        let capabilities = try XCTUnwrap((initialize["params"] as? JSON)?["clientCapabilities"] as? JSON)
        XCTAssertNil(capabilities["fs"])
        XCTAssertNil(capabilities["terminal"])
        backend.shutdown()
    }

    func testSecondTurnUsesTheSameProcessAndSession() async {
        let backend = ACPBackend(agent: agent)
        let first = text(await run(backend, turn("one")))
        let pid = backend.processID
        let second = text(await run(backend, turn("two")))
        XCTAssertEqual(first, second, "the fake agent prints its pid, so equal text means the same process")
        XCTAssertEqual(backend.processID, pid)
        XCTAssertEqual(logged().filter { $0["method"] as? String == "session/new" }.count, 1)
        XCTAssertEqual(logged().filter { $0["method"] as? String == "session/prompt" }.count, 2)
        backend.shutdown()
    }

    func testPreambleIsSentOnlyWithTheFirstPrompt() async {
        let backend = ACPBackend(agent: agent)
        _ = await run(backend, turn("one"))
        _ = await run(backend, turn("two"))
        let prompts = logged().filter { $0["method"] as? String == "session/prompt" }
            .map { (($0["params"] as? JSON)?["prompt"] as? [JSON])?.first?["text"] as? String ?? "" }
        XCTAssertTrue(prompts[0].hasPrefix("PREAMBLE"))
        XCTAssertFalse(prompts[1].contains("PREAMBLE"))
        backend.shutdown()
    }

    func testPermissionRequestIsAnsweredWithTheChosenOption() async {
        for (decision, optionID, ok) in [(ApprovalDecision.allow, "yes", true), (ApprovalDecision.deny(), "no", false)] {
            let backend = ACPBackend(agent: agent)
            var asked: ACPToolCall?
            backend.onPermission = { call, respond in
                asked = call
                respond(decision)
            }
            let events = await run(backend, turn("PERMISSION"))
            XCTAssertEqual(asked?.command, "touch x")
            XCTAssertEqual(asked?.kind, "execute")
            let finished = events.compactMap { event -> Bool? in if case .toolFinished(_, let ok) = event { return ok } else { return nil } }
            XCTAssertEqual(finished, [ok])
            let reply = logged().last { ($0["result"] as? JSON)?["outcome"] != nil }
            XCTAssertEqual((((reply?["result"] as? JSON)?["outcome"]) as? JSON)?["optionId"] as? String, optionID)
            backend.shutdown()
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("log"))
        }
    }

    func testCancelSendsSessionCancelAndKeepsTheProcess() async throws {
        let backend = ACPBackend(agent: agent)
        var events: [AgentEvent] = []
        let running = Task { await backend.runTurn(turn("SLOW")) { events.append($0) } }
        for _ in 0..<100 where !events.contains(where: { if case .assistant = $0 { return true } else { return false } }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let pid = try XCTUnwrap(backend.processID)
        backend.cancel()
        await running.value
        XCTAssertTrue(logged().contains { $0["method"] as? String == "session/cancel" })
        XCTAssertEqual(backend.processID, pid)
        // The next message works over the same process and session.
        let next = await run(backend, turn("again"))
        XCTAssertTrue(text(next).hasPrefix("pid="))
        XCTAssertEqual(backend.processID, pid)
        XCTAssertEqual(logged().filter { $0["method"] as? String == "session/new" }.count, 1)
        backend.shutdown()
    }

    func testTheCancelWatchdogDoesNotKillALaterPrompt() async throws {
        let backend = ACPBackend(agent: agent)
        var events: [AgentEvent] = []
        let running = Task { await backend.runTurn(turn("SLOW")) { events.append($0) } }
        for _ in 0..<100 where !events.contains(where: { if case .assistant = $0 { return true } else { return false } }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let pid = try XCTUnwrap(backend.processID)
        backend.cancel()
        await running.value
        // Start a long prompt on the same process right away and keep it running past the watchdog's five seconds.
        var second: [AgentEvent] = []
        let next = Task { await backend.runTurn(turn("SLOW")) { second.append($0) } }
        try await Task.sleep(nanoseconds: 6_000_000_000)
        XCTAssertEqual(backend.processID, pid, "the process serves the second prompt and must stay up")
        backend.cancel()
        await next.value
        backend.shutdown()
    }

    func testBypassModeFromTheUsersSettingsIsSwitchedToTheAskingMode() async {
        setenv("FAKE_MODE", "bypass", 1)
        defer { unsetenv("FAKE_MODE") }
        let backend = ACPBackend(agent: agent)
        _ = await run(backend, turn("hi"))
        let set = logged().first { $0["method"] as? String == "session/set_mode" }
        XCTAssertEqual((set?["params"] as? JSON)?["modeId"] as? String, "default")
        backend.shutdown()
    }

    func testAnAskingModeIsLeftAlone() async {
        let backend = ACPBackend(agent: agent)
        _ = await run(backend, turn("hi"))
        XCTAssertFalse(logged().contains { $0["method"] as? String == "session/set_mode" })
        backend.shutdown()
    }

    func testAskingModeChoice() {
        XCTAssertEqual(ACPBackend.askingMode(current: "bypassPermissions", available: ["default", "acceptEdits", "plan", "auto", "bypassPermissions"]), "default")
        XCTAssertEqual(ACPBackend.askingMode(current: "acceptEdits", available: ["default", "acceptEdits"]), "default")
        XCTAssertEqual(ACPBackend.askingMode(current: "auto", available: ["default", "auto"]), "default")
        XCTAssertEqual(ACPBackend.askingMode(current: "full-access", available: ["read-only", "auto", "full-access"]), "auto")
        XCTAssertEqual(ACPBackend.askingMode(current: "yolo", available: ["default", "autoEdit", "yolo"]), "default")
        XCTAssertNil(ACPBackend.askingMode(current: "default", available: ["default", "bypassPermissions"]))
        XCTAssertNil(ACPBackend.askingMode(current: "agent", available: ["agent", "plan", "ask"]), "Cursor's modes are left alone")
        XCTAssertNil(ACPBackend.askingMode(current: "auto", available: ["read-only", "auto", "full-access"]), "Codex's auto asks on request")
        XCTAssertNil(ACPBackend.askingMode(current: nil, available: ["default"]))
    }

    func testStoredSessionIsReopenedWithSessionLoad() async {
        let backend = ACPBackend(agent: agent)
        let events = await run(backend, turn("continue", resume: "old-session"))
        XCTAssertTrue(logged().contains { $0["method"] as? String == "session/load" && ($0["params"] as? JSON)?["sessionId"] as? String == "old-session" })
        XCTAssertFalse(logged().contains { $0["method"] as? String == "session/new" })
        XCTAssertFalse(text(events).contains("REPLAY"), "the replayed transcript is not appended to the chat")
        let prompts = logged().filter { $0["method"] as? String == "session/prompt" }
        XCTAssertEqual((prompts.first?["params"] as? JSON)?["sessionId"] as? String, "old-session")
        backend.shutdown()
    }

    func testChosenModelIsAppliedToTheSession() async {
        let backend = ACPBackend(agent: agent)
        _ = await run(backend, turn("hi", model: "m2"))
        let set = logged().first { $0["method"] as? String == "session/set_model" }
        XCTAssertEqual((set?["params"] as? JSON)?["modelId"] as? String, "m2")
        backend.shutdown()
    }

    func testAuthRequiredBecomesASignInOffer() async {
        setenv("FAKE_MODE", "auth", 1)
        defer { unsetenv("FAKE_MODE") }
        let backend = ACPBackend(agent: agent)
        let events = await run(backend, turn("hi"))
        guard case .needsSignIn(let methods)? = events.last else { return XCTFail("expected needsSignIn, got \(events)") }
        XCTAssertEqual(methods.map(\.name), ["Log in"])
        XCTAssertEqual(methods.first?.type, "agent")
        backend.shutdown()
    }

    func testImagesAreSentAsImageBlocksWhenTheAgentAccepts() async throws {
        let image = dir.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        let backend = ACPBackend(agent: agent)
        _ = await run(backend, turn("look", images: [image]))
        let prompt = (logged().first { $0["method"] as? String == "session/prompt" }?["params"] as? JSON)?["prompt"] as? [JSON]
        let block = prompt?.first { $0["type"] as? String == "image" }
        XCTAssertEqual(block?["mimeType"] as? String, "image/png")
        XCTAssertEqual(block?["data"] as? String, Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
        XCTAssertFalse((prompt?.first?["text"] as? String ?? "").contains("shot.png"), "no path hint when the image itself is sent")
        backend.shutdown()
    }

    func testMissingExecutableFailsWithAClearMessage() async {
        let backend = ACPBackend(agent: ACPAgent(id: "nope", name: "Nope", command: "/nonexistent/agent", args: [], helper: nil))
        let events = await run(backend, turn("hi"))
        guard case .finished(let error)? = events.last else { return XCTFail("expected a finish") }
        XCTAssertTrue(error?.contains("not found") == true, error ?? "")
    }
}
