import XCTest
@testable import IronPet

/// Each agent reports in its own format; these check that the common session status comes out right.
@MainActor
final class SessionMappingTests: XCTestCase {
    private func event(_ source: AgentSource, _ name: String, _ payload: [String: Any]) -> HookEvent {
        HookEvent(source: source, name: name, payload: payload, origin: SessionOrigin())
    }

    private func session(_ store: SessionStore, _ source: AgentSource, _ id: String) -> AgentSession? {
        store.sessions["\(source.rawValue):\(id)"]
    }

    func testCodexUsesClaudeEventNames() {
        let store = SessionStore()
        store.apply(event(.codex, "UserPromptSubmit", ["session_id": "c1", "cwd": "/work/app", "prompt": "fix the test"]))
        XCTAssertEqual(session(store, .codex, "c1")?.status, .running)
        XCTAssertEqual(session(store, .codex, "c1")?.origin.workspace, "/work/app")
        store.apply(event(.codex, "PermissionRequest", ["session_id": "c1", "tool_name": "Bash"]))
        XCTAssertEqual(session(store, .codex, "c1")?.status, .needsInput)
        store.apply(event(.codex, "Stop", ["session_id": "c1", "last_assistant_message": "Done."]))
        XCTAssertEqual(session(store, .codex, "c1")?.status, .done)
        XCTAssertEqual(session(store, .codex, "c1")?.lastResponse, "Done.")
    }

    func testGeminiTurnToolsAndPermission() {
        let store = SessionStore()
        store.apply(event(.gemini, "BeforeAgent", ["session_id": "g1", "cwd": "/work/g", "prompt": "add a test"]))
        XCTAssertEqual(session(store, .gemini, "g1")?.status, .running)
        store.apply(event(.gemini, "AfterTool", ["session_id": "g1", "tool_name": "write_file", "tool_input": ["file_path": "/work/g/a.swift"]]))
        XCTAssertEqual(session(store, .gemini, "g1")?.editedFiles, ["/work/g/a.swift"])
        store.apply(event(.gemini, "Notification", ["session_id": "g1", "message": "Allow write_file?"]))
        XCTAssertEqual(session(store, .gemini, "g1")?.status, .needsInput)
        store.apply(event(.gemini, "AfterAgent", ["session_id": "g1", "prompt_response": "All set"]))
        XCTAssertEqual(session(store, .gemini, "g1")?.status, .done)
        XCTAssertEqual(session(store, .gemini, "g1")?.lastResponse, "All set")
        store.apply(event(.gemini, "SessionEnd", ["session_id": "g1", "reason": "exit"]))
        XCTAssertEqual(session(store, .gemini, "g1")?.ended, true)
    }

    func testCopilotCamelCasePayloads() {
        let store = SessionStore()
        store.apply(event(.copilot, "userPromptSubmitted", ["sessionId": "p1", "cwd": "/work/c", "prompt": "refactor"]))
        XCTAssertEqual(session(store, .copilot, "p1")?.status, .running)
        store.apply(event(.copilot, "permissionRequest", ["sessionId": "p1", "toolName": "bash"]))
        XCTAssertEqual(session(store, .copilot, "p1")?.status, .needsInput)
        XCTAssertEqual(session(store, .copilot, "p1")?.detail, "Wants to use bash")
        store.apply(event(.copilot, "errorOccurred", ["sessionId": "p1", "error": ["message": "boom"]]))
        XCTAssertEqual(session(store, .copilot, "p1")?.status, .failed)
        XCTAssertEqual(session(store, .copilot, "p1")?.detail, "boom")
    }

    func testPiExtensionEvents() {
        let store = SessionStore()
        store.apply(event(.pi, "agent_start", ["session_id": "i1", "cwd": "/work/pi", "prompt": "explain"]))
        XCTAssertEqual(session(store, .pi, "i1")?.status, .running)
        store.apply(event(.pi, "tool", ["session_id": "i1", "tool_name": "read"]))
        XCTAssertEqual(session(store, .pi, "i1")?.detail, "read")
        store.apply(event(.pi, "agent_settled", ["session_id": "i1"]))
        XCTAssertEqual(session(store, .pi, "i1")?.status, .done)
    }

    func testEventsWithoutASessionIdAreIgnored() {
        let store = SessionStore()
        store.apply(event(.codex, "Stop", [:]))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testWatchSwitchesPerAgent() {
        var integrations = Config.Integrations()
        XCTAssertFalse(integrations.watches(.codex))
        integrations.setWatches(true, .codex)
        integrations.setWatches(true, .claude)
        XCTAssertTrue(integrations.watches(.codex))
        XCTAssertTrue(integrations.claudeHooks, "Cursor and Claude Code keep their old config keys")
        XCTAssertFalse(integrations.watches(.pi))
    }
}
