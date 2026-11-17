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
    turns = 0
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
            if mode == "loadfail" and method == "session/load":
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32002, "message": "Session not found"}}); continue
            sid = p.get("sessionId") or "sess-1"
            if os.environ.get("FAKE_MODE") == "bypass":
                pass
            if method == "session/load":
                update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "REPLAY"}})
                update({"sessionUpdate": "available_commands_update", "availableCommands": [{"name": "review", "description": "Review code"}, {"name": "init", "description": "Set up", "input": {"hint": "path"}}, {"name": "compact", "description": "Shrink"}]})
            modes = {"currentModeId": "bypassPermissions" if mode in ("bypass", "setmodefail") else "default",
                     "availableModes": [{"id": "default"}, {"id": "bypassPermissions"}]}
            if mode == "codex":
                # codex-acp 2.6.0: AgentMode.all() and its default, Agent ("Auto review").
                modes = {"currentModeId": "agent", "availableModes": [{"id": "read-only"}, {"id": "workspace-write"}, {"id": "agent"}, {"id": "agent-full-access"}]}
            if mode == "codexold":
                modes = {"currentModeId": "auto", "availableModes": [{"id": "auto"}, {"id": "full-access"}]}
            send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": sid, "modes": modes,
                  "models": {"currentModelId": "m1", "availableModels": [{"modelId": "m1", "name": "Model One"}, {"modelId": "m2", "name": "Model Two"}]}}})
        elif method == "session/set_mode" and mode == "setmodefail":
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "Invalid Mode"}})
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
            if "SWITCH" in text:
                update({"sessionUpdate": "current_mode_update", "currentModeId": "bypassPermissions"})
                time.sleep(0.5)
                send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
                continue
            if "BACKGROUND" in text:
                update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "started"}})
                send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
                time.sleep(0.3)
                update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "RESULT"}})
                continue
            if "SUBAGENT" in text:
                # Shapes follow claude-agent-acp 0.81: every update from a subagent, text included, carries
                # _meta.claudeCode.parentToolUseId (the Agent tool call's id). The refining tool_call_update does not.
                parent = {"claudeCode": {"toolName": "Agent"}}
                child = {"claudeCode": {"toolName": "Bash", "parentToolUseId": "toolu_agent"}}
                update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "an offer to start "}})
                update({"sessionUpdate": "tool_call", "toolCallId": "toolu_agent", "title": "Research", "kind": "other", "status": "pending", "rawInput": {"run_in_background": True}, "_meta": parent})
                update({"sessionUpdate": "tool_call", "toolCallId": "toolu_sub", "title": "`ls`", "kind": "execute", "status": "pending", "rawInput": {"command": "ls"}, "_meta": child})
                update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "subagent chatter"}, "_meta": {"claudeCode": {"parentToolUseId": "toolu_agent"}}})
                update({"sessionUpdate": "tool_call_update", "toolCallId": "toolu_sub", "status": "completed"})
                update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "recording."}})
                send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
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
            if mode == "usage":
                turns += 1
                update({"sessionUpdate": "usage_update", "used": 100, "size": 1000, "cost": {"amount": [0.05, 0.12][min(turns, 2) - 1], "currency": "USD"},
                        "_meta": {"_claude/model": "claude-real"}})
                send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn",
                      "usage": {"inputTokens": 120, "outputTokens": 30, "totalTokens": 150, "cachedReadTokens": 400, "cachedWriteTokens": 10}}})
                continue
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

    func testCommandListIsReportedEvenWhileTheSessionReplays() async {
        let backend = ACPBackend(agent: agent)
        let events = await run(backend, turn("hello", resume: "sess-1"))
        XCTAssertFalse(text(events).contains("REPLAY"))
        let commands = events.compactMap { event -> [SlashCommand]? in if case .commands(let list) = event { return list } else { return nil } }.first
        XCTAssertEqual(commands?.map(\.name), ["review", "init", "compact"])
        XCTAssertEqual(commands?[1].hint, "path")
        XCTAssertEqual(commands?[0].detail, "Review code")
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

    func testClaudeDeclaresThatSubagentTrafficMayFollowThePromptResponse() {
        let claude = ACPAgent(id: "claude", name: "Claude Code", command: "claude", args: [], helper: nil)
        let air = (ACPBackend.clientCapabilities(for: claude)["_meta"] as? JSON)?["jetbrains"] as? JSON
        XCTAssertEqual(((air?["air"] as? JSON)?["capabilities"]) as? [String], ["backgroundSubagents"])
        XCTAssertTrue(ACPBackend.clientCapabilities(for: agent).isEmpty, "other agents get no extension")
    }

    func testUpdatesAfterThePromptResponseGoToTheBackgroundHandler() async {
        let backend = ACPBackend(agent: agent)
        var late: [AgentEvent] = []
        backend.onBackground = { late.append($0) }
        let events = await run(backend, turn("BACKGROUND"))
        XCTAssertEqual(text(events), "started", "the turn ends at the response, without the later result")
        guard case .finished(let error) = events.last, error == nil else { return XCTFail("expected a clean finish") }
        for _ in 0..<40 where late.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(text(late), "RESULT")
        backend.shutdown()
    }

    func testSubagentCallsAreTaggedWithTheirParentAndItsChatterIsDropped() async {
        let backend = ACPBackend(agent: agent)
        let events = await run(backend, turn("SUBAGENT"))
        XCTAssertEqual(text(events), "an offer to start recording.")
        let subagent = events.compactMap { event -> (String, String, Bool?)? in
            if case .subagentTool(let parent, let id, _, let ok) = event { return (parent, id, ok) } else { return nil }
        }
        XCTAssertEqual(subagent.map(\.0), ["toolu_agent", "toolu_agent"])
        XCTAssertEqual(subagent.map(\.1), ["toolu_sub", "toolu_sub"])
        XCTAssertEqual(subagent.map { $0.2 }, [nil, true], "the update without _meta still finds its parent")
        let inline = events.compactMap { event -> String? in
            switch event {
            case .toolStarted(let id, _), .toolFinished(let id, _): return id
            default: return nil
            }
        }
        XCTAssertEqual(inline, ["toolu_agent"], "only the main agent's own call is an inline tool event")
        backend.shutdown()
    }

    func testStopWithNoTurnRunningSendsNoCancel() async {
        let backend = ACPBackend(agent: agent)
        _ = await run(backend, turn("BACKGROUND"))
        backend.cancel()
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(logged().filter { $0["method"] as? String == "session/cancel" }.isEmpty,
                      "the adapter's cancel interrupts Claude Code, which also stops background subagents")
        backend.shutdown()
    }

    func testFailedSessionLoadStartsANewSessionWithoutError() async throws {
        setenv("FAKE_MODE", "loadfail", 1)
        defer { unsetenv("FAKE_MODE") }
        var lines: [String] = []
        ChatLog.sink = { lines.append($0) }
        defer { ChatLog.sink = nil }
        let backend = ACPBackend(agent: agent)
        let events = await run(backend, turn("hello", resume: "old-thread"))
        guard case .finished(let error) = events.last, error == nil else { return XCTFail("expected a clean finish") }
        XCTAssertTrue(events.contains { if case .session("sess-1") = $0 { return true } else { return false } })
        XCTAssertEqual(logged().filter { $0["method"] as? String == "session/load" }.count, 1)
        XCTAssertEqual(logged().filter { $0["method"] as? String == "session/new" }.count, 1)
        XCTAssertTrue(lines.contains { $0.hasPrefix("session/load failed for old-thread") })
        backend.shutdown()
    }

    func testAgentProcessExitResumesTheSameSessionOnTheNextTurn() async throws {
        var lines: [String] = []
        ChatLog.sink = { lines.append($0) }
        defer { ChatLog.sink = nil }
        let backend = ACPBackend(agent: agent)
        let first = text(await run(backend, turn("one")))
        let pid = try XCTUnwrap(backend.processID)
        kill(pid, SIGKILL)
        for _ in 0..<50 where !lines.contains(where: { $0.contains("exited") }) { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(lines.contains { $0.contains("exited") })
        let events = await run(backend, turn("two", resume: "sess-1"))
        guard case .finished(let error) = events.last, error == nil else { return XCTFail("expected a clean finish") }
        XCTAssertNotEqual(text(events), first, "a new process answered")
        let loads = logged().filter { $0["method"] as? String == "session/load" }
        XCTAssertEqual((loads.first?["params"] as? JSON)?["sessionId"] as? String, "sess-1")
        XCTAssertFalse(events.contains { if case .session = $0 { return true } else { return false } }, "the session is the same, so no new one is announced")
        XCTAssertFalse(text(events).contains("REPLAY"))
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
        XCTAssertEqual(ACPBackend.askingMode(current: "yolo", available: ["default", "autoEdit", "yolo"]), "default")
        XCTAssertNil(ACPBackend.askingMode(current: "default", available: ["default", "bypassPermissions"]))
        XCTAssertNil(ACPBackend.askingMode(current: "agent", available: ["agent", "plan", "ask"]), "Cursor's modes are left alone")
        XCTAssertNil(ACPBackend.askingMode(current: nil, available: ["default"]))
        // The chat leaves codex-acp 2.6.0's modes as they are, as before; task runs use runMode below.
        let codex = ["read-only", "workspace-write", "agent", "agent-full-access"]
        XCTAssertNil(ACPBackend.askingMode(current: "agent", available: codex))
        XCTAssertNil(ACPBackend.askingMode(current: "workspace-write", available: codex))
    }

    func testTaskRunModeChoice() throws {
        let codex = ["read-only", "workspace-write", "agent", "agent-full-access"]
        for current in ["agent", "agent-full-access", "workspace-write", nil] {
            XCTAssertEqual(try ACPBackend.runMode(agent: "codex", current: current, available: codex), "read-only", current ?? "nil")
        }
        XCTAssertNil(try ACPBackend.runMode(agent: "codex", current: "read-only", available: codex))
        XCTAssertThrowsError(try ACPBackend.runMode(agent: "codex", current: "auto", available: ["auto", "full-access"]),
                             "a Codex without read-only cannot run tasks")
        let claude = ["default", "acceptEdits", "plan", "auto", "bypassPermissions"]
        for current in ["bypassPermissions", "acceptEdits", "auto", "dontAsk"] {
            XCTAssertEqual(try ACPBackend.runMode(agent: "claude", current: current, available: claude), "default", current)
        }
        XCTAssertNil(try ACPBackend.runMode(agent: "claude", current: "default", available: claude))
        XCTAssertNil(try ACPBackend.runMode(agent: "claude", current: "plan", available: claude))
        XCTAssertEqual(try ACPBackend.runMode(agent: "gemini", current: "yolo", available: ["default", "autoEdit", "yolo"]), "default")
        XCTAssertEqual(try ACPBackend.runMode(agent: "gemini", current: "autoEdit", available: ["default", "autoEdit", "yolo"]), "default")
        XCTAssertNil(try ACPBackend.runMode(agent: "cursor", current: "agent", available: ["agent", "plan", "ask"]), "Cursor's agent mode asks")
        XCTAssertNil(try ACPBackend.runMode(agent: "fake", current: nil, available: []), "no modes to judge")
        XCTAssertThrowsError(try ACPBackend.runMode(agent: "other", current: "auto", available: ["auto", "full-access"]))
    }

    func testATaskRunSwitchesCodexToReadOnly() async {
        setenv("FAKE_MODE", "codex", 1)
        defer { unsetenv("FAKE_MODE") }
        let codex = ACPAgent(id: "codex", name: "Codex", command: dir.appendingPathComponent("fake-agent").path, args: [], helper: nil)
        let chat = ACPBackend(agent: codex)
        _ = await run(chat, turn("hi"))
        XCTAssertFalse(logged().contains { $0["method"] as? String == "session/set_mode" }, "the chat leaves Codex's mode alone")
        chat.shutdown()
        let backend = ACPBackend(agent: codex)
        backend.requiresAskingMode = true
        let events = await run(backend, turn("hi"))
        guard case .finished(nil) = events.last else { return XCTFail("the run's turn goes ahead: \(events)") }
        let set = logged().last { $0["method"] as? String == "session/set_mode" }
        XCTAssertEqual((set?["params"] as? JSON)?["modeId"] as? String, "read-only")
        backend.shutdown()
    }

    func testATaskRunFailsWhenItCannotReachAnAskingMode() async {
        let codex = ACPAgent(id: "codex", name: "Codex", command: dir.appendingPathComponent("fake-agent").path, args: [], helper: nil)
        setenv("FAKE_MODE", "codexold", 1)
        defer { unsetenv("FAKE_MODE") }
        let missing = ACPBackend(agent: codex)
        missing.requiresAskingMode = true
        let events = await run(missing, turn("hi"))
        guard case .finished(let error?) = events.last else { return XCTFail("no read-only mode must fail the turn") }
        XCTAssertTrue(error.contains("read-only"), error)
        XCTAssertFalse(logged().contains { $0["method"] as? String == "session/prompt" }, "no prompt is sent")
        missing.shutdown()

        setenv("FAKE_MODE", "setmodefail", 1)
        let refused = ACPBackend(agent: agent)
        refused.requiresAskingMode = true
        let refusedEvents = await run(refused, turn("hi", resume: "old-session"))
        guard case .finished(let refusal?) = refusedEvents.last else { return XCTFail("a failed set_mode must fail the turn") }
        XCTAssertTrue(refusal.contains("did not switch to its default mode"), refusal)
        XCTAssertFalse(logged().contains { $0["method"] as? String == "session/new" }, "a failed switch is not taken as a failed load")
        XCTAssertFalse(logged().contains { $0["method"] as? String == "session/prompt" })
        refused.shutdown()

        let chat = ACPBackend(agent: agent)
        let chatEvents = await run(chat, turn("hi"))
        guard case .finished(nil) = chatEvents.last else { return XCTFail("the chat only logs a failed switch, as before") }
        chat.shutdown()
    }

    func testATaskRunAgentThatLeavesItsAskingModeIsStopped() async {
        let backend = ACPBackend(agent: agent)
        backend.requiresAskingMode = true
        let events = await run(backend, turn("SWITCH modes"))
        guard case .finished(let error?) = events.last else { return XCTFail("switching to bypassPermissions must stop the run") }
        XCTAssertEqual(error, "Fake switched itself to its bypassPermissions mode, which does not ask before changes, so ironpet stopped it.")
        backend.shutdown()
        let chat = ACPBackend(agent: agent)
        let chatEvents = await run(chat, turn("SWITCH modes"))
        guard case .finished(nil) = chatEvents.last else { return XCTFail("the chat is not stopped") }
        chat.shutdown()
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

    // MARK: Usage

    private func usageStore() throws -> UsageStore {
        UsageStore(database: try Database(path: nil, migrations: AppMigrations.all))
    }

    private func recorded(_ store: UsageStore) -> UsageSummary {
        store.summary(days: 7)
    }

    func testTurnWithReportedUsageStoresOneChatRecord() async throws {
        setenv("FAKE_MODE", "usage", 1)
        let store = try usageStore()
        let backend = ACPBackend(agent: agent)
        backend.usageFeature = .chat
        backend.usageStore = store
        _ = await run(backend, turn("hello"))
        let rows = recorded(store).rows
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.feature, .chat)
        XCTAssertEqual(row.model, "claude-real", "the model the agent names in usage_update wins over the session default")
        XCTAssertEqual(row.requests, 1)
        XCTAssertEqual([row.inputTokens, row.outputTokens, row.cacheReadTokens, row.cacheWriteTokens, row.totalTokens], [120, 30, 400, 10, 150])
        XCTAssertEqual(row.cost ?? 0, 0.05, accuracy: 1e-9)
        XCTAssertEqual(row.currency, "USD")
        XCTAssertNotNil(row.duration)
        backend.shutdown()
    }

    func testCostIsTheChangeInSessionCostNotTheRunningTotal() async throws {
        setenv("FAKE_MODE", "usage", 1)
        let store = try usageStore()
        let backend = ACPBackend(agent: agent)
        backend.usageFeature = .chat
        backend.usageStore = store
        _ = await run(backend, turn("one"))
        _ = await run(backend, turn("two"))
        let row = try XCTUnwrap(recorded(store).rows.first)
        XCTAssertEqual(row.requests, 2)
        XCTAssertEqual(row.cost ?? 0, 0.12, accuracy: 1e-9, "0.05 for the first turn plus 0.07 for the second")
        backend.shutdown()
    }

    func testAgentWithoutUsageStoresTurnAndDurationOnly() async throws {
        let store = try usageStore()
        let backend = ACPBackend(agent: agent)
        backend.usageFeature = .chat
        backend.usageStore = store
        _ = await run(backend, turn("hello"))
        let row = try XCTUnwrap(recorded(store).rows.first)
        XCTAssertEqual(row.requests, 1)
        XCTAssertNotNil(row.duration)
        XCTAssertEqual(row.model, "m1", "the session's current model when the agent names none")
        for value in [row.inputTokens, row.outputTokens, row.cacheReadTokens, row.cacheWriteTokens, row.totalTokens] { XCTAssertNil(value) }
        XCTAssertNil(row.cost)
        XCTAssertFalse(recorded(store).hasCost)
        backend.shutdown()
    }

    func testBackendWithoutAFeatureRecordsNothing() async throws {
        setenv("FAKE_MODE", "usage", 1)
        let store = try usageStore()
        let backend = ACPBackend(agent: agent)
        backend.usageStore = store
        _ = await run(backend, turn("hello"))
        XCTAssertTrue(recorded(store).rows.isEmpty)
        backend.shutdown()
    }

    func testAutomationPromptCountsUnderAutomations() async throws {
        let store = try usageStore()
        let previous = UsageStore.shared
        UsageStore.shared = store
        defer { UsageStore.shared = previous }
        let automation = Automation(id: "a", name: "A", trigger: .init(type: "interval", minutes: 5, clock: "wall"),
                                    action: .init(type: "prompt", title: "A"), createdBy: "user")
        let result = await AutomationPrompt.run(automation, prompt: "hi", workspace: dir.appendingPathComponent("ws"), agentOverride: agent)
        guard case .success = result else { return XCTFail("the prompt run failed: \(result)") }
        XCTAssertEqual(recorded(store).rows.map(\.feature), [.automations])
    }

    func testMeetingSummaryRunnerCountsUnderMeetingSummaries() async throws {
        let store = try usageStore()
        let runner = MeetingController.makeSummaryRunner(agent)
        runner.usageStore = store
        _ = await run(runner, turn("summarize"))
        XCTAssertEqual(recorded(store).rows.map(\.feature), [.meetingSummary])
        runner.shutdown()
    }
}
