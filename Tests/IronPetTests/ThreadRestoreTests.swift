import Combine
import XCTest
@testable import IronPet

final class ThreadRestoreTests: XCTestCase {
    private func thread(_ kinds: [ChatSession.Item.Kind]) -> ChatThread {
        ChatThread(id: "t1", title: "Chat", workspace: "/tmp", updatedAt: Date(),
                   items: kinds.map { ChatSession.Item(kind: $0) }, agent: "claude")
    }

    func testRunningStepsShowAsFailedAfterQuit() {
        let restored = thread([.user("hi"), .tool("Ran `npm test`", ok: nil), .tool("Read a.ts", ok: true)]).restoredAfterQuit()
        guard case .tool(_, let running) = restored.items[1].kind, case .tool(_, let finished) = restored.items[2].kind else {
            return XCTFail("tool items expected")
        }
        XCTAssertEqual(running, false)
        XCTAssertEqual(finished, true)
    }

    func testOtherItemsAndMetadataAreKept() {
        let original = thread([.user("hi"), .assistant("hello"), .tool("Edited b.ts", ok: false)])
        let restored = original.restoredAfterQuit()
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.agent, "claude")
        XCTAssertEqual(restored.items.map(\.id), original.items.map(\.id))
        guard case .assistant(let text) = restored.items[1].kind else { return XCTFail("assistant item expected") }
        XCTAssertEqual(text, "hello")
    }

    func testTaskLinkRoundTripsAndOldThreadsStillDecode() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var linked = thread([.user("hi")])
        linked.task = "fix-login"
        XCTAssertEqual(try decoder.decode(ChatThread.self, from: encoder.encode(linked)).task, "fix-login")
        let old = #"{"id":"t1","title":"Chat","workspace":"/tmp","updatedAt":"2026-11-01T10:00:00Z","items":[],"agent":"claude"}"#
        XCTAssertNil(try decoder.decode(ChatThread.self, from: Data(old.utf8)).task)
    }

    // MARK: Transcript

    private func describe(_ items: [ChatSession.Item]) -> [String] {
        items.map {
            switch $0.kind {
            case .assistant(let text): "a:\(text)"
            case .tool(let summary, let ok): "t:\(summary):\(ok.map(String.init) ?? "nil")"
            default: "other"
            }
        }
    }

    func testTranscriptFoldsTextToolsAndSubagents() {
        var transcript = ChatTranscript()
        var items: [ChatSession.Item] = []
        XCTAssertEqual(transcript.apply(.assistant("Hel"), to: &items, running: true).activity, "Writing")
        _ = transcript.apply(.assistant("lo"), to: &items, running: true)
        XCTAssertEqual(transcript.apply(.toolStarted(id: "1", summary: "Ran `npm test`"), to: &items, running: true).activity,
                       "Running `npm test`")
        _ = transcript.apply(.subagentTool(parent: "1", id: "s1", summary: "Read a.ts", ok: nil), to: &items, running: true)
        _ = transcript.apply(.subagentTool(parent: "1", id: "s1", summary: "Read a.ts", ok: true), to: &items, running: true)
        XCTAssertEqual(transcript.apply(.toolFinished(id: "1", ok: true), to: &items, running: true), .init(activity: "Thinking", changed: true))
        XCTAssertEqual(describe(items), ["a:Hello", "t:Ran `npm test` · 1 tool call:true"])
    }

    func testTranscriptOutsideATurnOpensANewReplyAndAsksToSave() {
        var transcript = ChatTranscript()
        var items = [ChatSession.Item(kind: .assistant("Done"))]
        XCTAssertEqual(transcript.apply(.assistant("Late"), to: &items, running: false), .init(changed: true))
        _ = transcript.apply(.assistant(" result"), to: &items, running: false)
        _ = transcript.apply(.toolStarted(id: "2", summary: "Edited a.ts"), to: &items, running: false)
        XCTAssertEqual(transcript.apply(.toolFinished(id: "2", ok: false), to: &items, running: false), .init(save: true, changed: true))
        XCTAssertEqual(describe(items), ["a:Done", "a:Late result", "t:Edited a.ts:false"])
        XCTAssertEqual(transcript.apply(.toolFinished(id: "unknown", ok: true), to: &items, running: false), .init(save: true),
                       "an update for a row that is not there changes nothing")
    }

    @MainActor
    func testATaskRunThreadKeepsTheRunRulesInTheChat() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-chat-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let worktrees = base.appendingPathComponent("worktrees")
        let copy = worktrees.appendingPathComponent("app-1a2b3c4d/fix-login")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let session = ChatSession(restore: false)
        session.taskWorktrees = worktrees
        session.autoMode = true
        var answers: [ApprovalDecision] = []
        func ask(_ call: ACPToolCall) { session.handlePermission(call) { answers.append($0) } }
        func shell(_ command: String) -> ACPToolCall { ACPToolCall(id: UUID().uuidString, title: command, kind: "execute", rawInput: ["command": command]) }

        session.open(ChatThread(id: "t-run", title: "Task: Fix login", workspace: copy.path, updatedAt: Date(), items: [], agent: "none", task: "fix-login"))
        XCTAssertEqual(session.taskRunScope, RunScope(root: copy))
        ask(shell("git push origin HEAD"))
        XCTAssertEqual(answers.last?.allow, false)
        XCTAssertEqual(answers.last?.message, ApprovalRules.refusedInRun)
        let count = answers.count
        ask(ACPToolCall(id: "i", title: "Edit", kind: "edit", rawInput: ["file_path": copy.appendingPathComponent("a.swift").path]))
        ask(shell("npm test"))
        ask(shell("git config remote.origin.url https://evil.example/app.git"))
        ask(ACPToolCall(id: "e", title: "Edit", kind: "edit", rawInput: ["file_path": base.appendingPathComponent("elsewhere.txt").path]))
        XCTAssertEqual(answers.count, count, "edits and commands wait on a card, even in Auto")
        XCTAssertEqual(session.approvals.map(\.title),
                       ["Edit a.swift?", "Run this command?", "Change the project's shared git setup?", "Edit elsewhere.txt outside the task's copy?"])
        session.stop()

        await session.loadRunRemotes()
        XCTAssertEqual(session.agentEnvironment["GIT_CONFIG_COUNT"], "6", "not a repository: only the URL rewrites")
        try GitFixture.initRepo(copy)
        try GitFixture.sh(["git", "remote", "add", "origin", "https://example.com/app.git"], in: copy)
        session.open(ChatThread(id: "t-run2", title: "Task: Fix login", workspace: copy.path, updatedAt: Date(), items: [], agent: "none", task: "fix-login"))
        let worktree = copy.deletingLastPathComponent().appendingPathComponent("fix-login-2")
        try GitFixture.sh(["git", "worktree", "add", "-q", "-b", "ironpet/fix-login-2", worktree.path], in: copy)
        session.open(ChatThread(id: "t-run3", title: "Task: Fix login", workspace: worktree.path, updatedAt: Date(), items: [], agent: "none", task: "fix-login"))
        XCTAssertEqual(session.agentEnvironment["GIT_CONFIG_COUNT"], "6", "reading the environment never runs git")
        await session.loadRunRemotes()
        XCTAssertEqual(session.agentEnvironment["GIT_CONFIG_KEY_0"], "remote.origin.pushurl", "the copy's real remotes are blocked too")
        XCTAssertEqual(session.agentEnvironment["GIT_CONFIG_COUNT"], "7")
        session.stop()

        session.open(ChatThread(id: "t-moved", title: "Task: Fix login", workspace: base.path, updatedAt: Date(), items: [], agent: "none", task: "fix-login"))
        XCTAssertNil(session.taskRunScope, "after the copy is removed the thread points at the user's own folder")
        session.open(ChatThread(id: "t-chat", title: "Chat", workspace: copy.path, updatedAt: Date(), items: [], agent: "none"))
        XCTAssertEqual(session.taskRunScope, RunScope(root: copy), "any chat in a copy, such as a new chat left in its folder")
        session.newChat()
        XCTAssertEqual(session.taskRunScope, RunScope(root: copy), "a new chat keeps the folder, so it keeps the rules")
        session.open(ChatThread(id: "t-elsewhere", title: "Chat", workspace: base.path, updatedAt: Date(), items: [], agent: "none"))
        XCTAssertNil(session.taskRunScope, "a chat outside the copies")
    }

    @MainActor
    func testOnlyAgentsThatAskWorkInATaskRunsCopy() async throws {
        let savedAgent = UserDefaults.standard.string(forKey: "chatAgent")
        defer { UserDefaults.standard.set(savedAgent, forKey: "chatAgent") }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-chat-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let worktrees = base.appendingPathComponent("worktrees")
        let copy = worktrees.appendingPathComponent("app-1a2b3c4d/fix-login")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let session = ChatSession(restore: false)
        session.taskWorktrees = worktrees
        var turns: [ACPTurn] = []
        session.turnRunner = { turn, _ in turns.append(turn) }
        var telegram: [ChatSession.TelegramEvent] = []
        session.onTelegram = { _, event in telegram.append(event) }
        func settle() async { for _ in 0..<5 { await Task.yield() } }
        let pi = try XCTUnwrap(AgentCatalog.agent(id: "pi"))
        let claude = try XCTUnwrap(AgentCatalog.agent(id: "claude"))
        let refusal = "Pi cannot work in a task run's copy: only \(TaskRunner.askingAgentNames) are known to ask before each change. Pick one of them, or choose another folder."
        func errors() -> [String] { session.items.compactMap { if case .error(let m) = $0.kind { m } else { nil } } }

        session.open(ChatThread(id: "t-run", title: "Task: Fix login", workspace: copy.path, updatedAt: Date(), items: [], agent: "pi", task: "fix-login"))
        session.setAgent(pi)
        XCTAssertEqual(session.agent.id, "pi")
        session.input = "keep going"
        session.send()
        await settle()
        XCTAssertTrue(turns.isEmpty, "Pi gets no turn in the copy")
        XCTAssertEqual(session.input, "keep going", "the draft stays for another agent")
        XCTAssertEqual(errors(), [refusal])
        session.send()
        XCTAssertEqual(errors(), [refusal], "the refusal is not repeated")
        session.submitFromTelegram("from the phone", chat: 7)
        await settle()
        XCTAssertTrue(turns.isEmpty)
        XCTAssertEqual(telegram, [.failed(refusal)])
        XCTAssertFalse(session.submitFromAutomation("review", automation: "a1"))
        XCTAssertTrue(turns.isEmpty)

        session.setAgent(claude)
        session.send()
        await settle()
        XCTAssertEqual(turns.map(\.prompt), ["keep going"], "an agent that asks may work in the copy (a new chat, since the agent changed)")
        XCTAssertNotNil(session.taskRunScope, "with the run's rules")
        XCTAssertEqual(TaskRunner.askingAgentNames, "Claude Code, Codex, Cursor and Gemini CLI")

        let plain = ChatSession(restore: false)
        plain.turnRunner = { turn, _ in turns.append(turn) }
        plain.workspace = base
        plain.setAgent(pi)
        plain.input = "hello"
        plain.send()
        await settle()
        XCTAssertEqual(turns.last?.prompt, "hello", "outside a copy Pi chats as before")
    }

    @MainActor
    func testANoOpEventDoesNotPublishTheItems() {
        let session = ChatSession(restore: false)
        session.items = [ChatSession.Item(kind: .assistant("Done"))]
        var published = 0
        let watch = session.$items.dropFirst().sink { _ in published += 1 }
        session.handleBackground(.toolFinished(id: "unknown", ok: true))
        session.handleBackground(.toolUpdated(id: "unknown", summary: "x"))
        XCTAssertEqual(published, 0)
        session.handleBackground(.assistant("Late"))
        XCTAssertEqual(published, 1)
        watch.cancel()
    }
}
