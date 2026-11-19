import XCTest
@testable import IronPet

@MainActor
final class MemoryMCPTests: XCTestCase {
    private var dir: URL!
    private var store: FileMemoryStore!
    private var index: MemoryIndex!
    private var screen: CaptureStore!
    private var threads: [String: ChatThread] = [:]
    private var workspace: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-memory-mcp-\(UUID().uuidString)")
        workspace = dir.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let database = try Database(path: nil, migrations: AppMigrations.all)
        index = MemoryIndex(database: database)
        screen = CaptureStore(database: database)
        store = FileMemoryStore(directory: dir.appendingPathComponent("memory"), index: index)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var services: MemoryMCP.Services {
        MemoryMCP.Services(store: store, index: index, screen: screen, context: { [workspace] in ("3f2a9c1d-session", workspace) },
                           thread: { [threads] in threads[$0] })
    }

    private func call(_ name: String, _ args: [String: Any], caller: String? = nil) async throws -> (value: [String: Any], isError: Bool, text: String) {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]])
        let (_, data) = await MCPEndpoint.handle(body, automations: nil, tasks: nil, screen: screen, memory: services, caller: caller)
        let result = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let value = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        return (value, result["isError"] as? Bool ?? false, text)
    }

    func testRememberWritesTheNoteWithTheChatAsItsSource() async throws {
        let saved = try await call("memory_remember", ["text": "Prefers pnpm over npm", "scope": "me"])
        XCTAssertFalse(saved.isError, saved.text)
        XCTAssertEqual(saved.value["file"] as? String, "me.md")
        XCTAssertEqual(store.document(store.aboutMe)?.notes.first?.source, "chat:3f2a9c1d")
        let project = try await call("memory_remember", ["text": "Tests run with swift test", "scope": "project"])
        XCTAssertFalse(project.isError, project.text)
        XCTAssertEqual(store.document(store.projectFile(ProjectKey.of(workspace)))?.notes.map(\.text), ["Tests run with swift test"])
    }

    func testRememberRefusesSecretsAndMissingFields() async throws {
        let secret = try await call("memory_remember", ["text": "AWS key AKIAIOSFODNN7EXAMPLE", "scope": "me"])
        XCTAssertTrue(secret.isError)
        XCTAssertTrue(secret.text.contains("not saved"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.aboutMe.path))
        let noScope = try await call("memory_remember", ["text": "x"])
        XCTAssertTrue(noScope.isError)
        let badScope = try await call("memory_remember", ["text": "x", "scope": "world"])
        XCTAssertTrue(badScope.text.contains("scope is me, project or people"))
        let noPerson = try await call("memory_remember", ["text": "Likes tea", "scope": "people"])
        XCTAssertTrue(noPerson.text.contains("person's name"))
    }

    func testForgetMovesTheNoteToHistoryAndSaysWhatWentAway() async throws {
        _ = try await call("memory_remember", ["text": "Prefers pnpm over npm", "scope": "me"])
        _ = try await call("memory_remember", ["text": "Works in Helsinki", "scope": "me"])
        let forgot = try await call("memory_forget", ["query": "pnpm"])
        XCTAssertFalse(forgot.isError, forgot.text)
        XCTAssertEqual((forgot.value["removed"] as? [[String: Any]])?.first?["note"] as? String, "Prefers pnpm over npm")
        XCTAssertEqual(store.document(store.aboutMe)?.notes.map(\.text), ["Works in Helsinki"])
        let copies = try FileManager.default.contentsOfDirectory(atPath: store.historyRoot.appendingPathComponent("me.md").path)
        XCTAssertFalse(copies.isEmpty, "the note is in .history")
        let again = try await call("memory_forget", ["query": "pnpm"])
        XCTAssertTrue(again.isError)
    }

    func testSearchFindsChatsNotesHistoryAndTheScreen() async throws {
        let item = ChatSession.Item(kind: .user("I always use pnpm, never npm"))
        let thread = ChatThread(id: "t1", title: "Packages", workspace: workspace.path, updatedAt: Date(),
                                items: [item, .init(kind: .assistant("Got it, pnpm."))], agent: "claude")
        threads["t1"] = thread
        index.indexThread(thread)
        index.flush()
        _ = try await call("memory_remember", ["text": "Prefers pnpm over npm", "scope": "me"])
        _ = try await call("memory_forget", ["query": "pnpm"])
        _ = try screen.ingest(app: CaptureApp(bundleId: "com.apple.Safari", name: "Safari"), title: "pnpm docs", url: nil, trigger: .click,
                              lines: ["pnpm install is fast"])
        let all = try await call("memory_search", ["query": "pnpm"])
        let kinds = (all.value["hits"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
        XCTAssertEqual(Set(kinds), ["chat", "screen"], "the forgotten note is not found by default")
        let history = try await call("memory_search", ["query": "pnpm", "kinds": ["history"]])
        XCTAssertEqual((history.value["hits"] as? [[String: Any]])?.first?["kind"] as? String, "history", "only when asked for")
        let chats = try await call("memory_search", ["query": "never npm", "kinds": ["chat"]])
        let hit = try XCTUnwrap((chats.value["hits"] as? [[String: Any]])?.first)
        XCTAssertEqual(hit["id"] as? String, "chat:t1/\(item.id.uuidString)")
        let excerpt = try await call("memory_get", ["id": hit["id"] as! String])
        let messages = try XCTUnwrap(excerpt.value["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant"])
        XCTAssertEqual(messages.first?["hit"] as? Bool, true)
        XCTAssertEqual(excerpt.value["thread"] as? String, "Packages")
    }

    func testAnAutomationSessionIsOutsideTextAndCannotWriteMeOrForget() async throws {
        _ = try await call("memory_remember", ["text": "Prefers tea", "scope": "me"])
        let me = try await call("memory_remember", ["text": "Prefers coffee", "scope": "me"], caller: "automation:mail")
        XCTAssertTrue(me.isError)
        XCTAssertTrue(me.text.contains("may not save notes about the user"))
        let forget = try await call("memory_forget", ["query": "tea"], caller: "automation:mail")
        XCTAssertTrue(forget.isError)
        XCTAssertEqual(store.document(store.aboutMe)?.notes.map(\.text), ["Prefers tea"])
        let project = try await call("memory_remember", ["text": "Uses Make", "scope": "project"], caller: "automation:mail")
        XCTAssertTrue(project.isError, "no project is taken from the chat that happens to be open")
        let person = try await call("memory_remember", ["text": "Sends the invoices", "scope": "people", "person": "Ana"], caller: "automation:mail")
        XCTAssertFalse(person.isError, person.text)
        XCTAssertEqual(store.document(store.people)?.notes.first?.source, "automation:mail")
    }

    func testAnAutomationSessionNamesItselfToTheIronpetServerOnly() {
        let saved = ACPBackend.defaultMCPServers
        defer { ACPBackend.defaultMCPServers = saved }
        ACPBackend.defaultMCPServers = { [["name": "ironpet", "command": "/x", "args": ["mcp"], "env": [JSON]()], ["name": "other", "command": "/y"]] }
        let backend = ACPBackend(agent: AgentCatalog.agent(id: "claude")!)
        XCTAssertNil((backend.sessionMCPServers.first?["env"] as? [JSON])?.first)
        backend.mcpCaller = "automation:mail"
        let env = backend.sessionMCPServers.first?["env"] as? [JSON]
        XCTAssertEqual(env?.first?["name"] as? String, MCPEndpoint.callerVariable)
        XCTAssertEqual(env?.first?["value"] as? String, "automation:mail")
        XCTAssertNil(backend.sessionMCPServers.last?["env"])
        backend.restricted = true
        XCTAssertTrue(backend.sessionMCPServers.isEmpty)
    }

    func testAnAutomationSessionMayNotEditMemoryFiles() {
        let memoryEdit = ACPToolCall(id: "1", title: "Edit", kind: "edit", paths: [FileMemoryStore.directory.appendingPathComponent("me.md").path])
        XCTAssertFalse(AutomationSession.decision(for: memoryEdit).allow)
        XCTAssertFalse(AutomationPrompt.decision(for: memoryEdit).allow, "the {{item.*}} run carries outside text")
        XCTAssertTrue(AutomationPrompt.decision(for: ACPToolCall(id: "2", title: "Read", kind: "read", paths: ["/tmp/x"])).allow)
        let otherEdit = ACPToolCall(id: "2", title: "Edit", kind: "edit", paths: ["/tmp/work/app.swift"])
        XCTAssertTrue(AutomationSession.decision(for: otherEdit).allow, "other non-destructive edits run in an automation's session")
    }

    func testScreenIsLeftOutWhenCaptureHasNoData() async throws {
        let result = try await call("memory_search", ["query": "anything", "kinds": ["screen"]])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.value["count"] as? Int, 0)
    }

    func testGetReadsANoteWithItsEarlierVersionsAndRefusesUnknownIds() async throws {
        _ = try await call("memory_remember", ["text": "Uses zsh", "scope": "me"])
        _ = try await call("memory_remember", ["text": "Uses vim", "scope": "me"])
        let found = try await call("memory_search", ["query": "zsh", "kinds": ["note"]])
        let hit = try XCTUnwrap((found.value["hits"] as? [[String: Any]])?.first { ($0["id"] as? String)?.hasPrefix("note:") == true })
        let note = try await call("memory_get", ["id": hit["id"] as! String])
        XCTAssertEqual(note.value["note"] as? String, "Uses zsh")
        XCTAssertEqual((note.value["earlier_versions"] as? [[String: Any]])?.count, 1)
        let unknown = try await call("memory_get", ["id": "chat:nope/none"])
        XCTAssertTrue(unknown.isError)
        let bad = try await call("memory_get", ["id": "nonsense"])
        XCTAssertTrue(bad.isError)
    }

    func testBadTimesAndKindsAreErrors() async throws {
        let time = try await call("memory_search", ["query": "x", "since": "last tuesday"])
        XCTAssertTrue(time.isError)
        let kind = try await call("memory_search", ["query": "x", "kinds": ["email"]])
        XCTAssertTrue(kind.text.contains("unknown kinds"))
    }

    func testWithoutServicesTheToolsSayTheyAreUnavailable() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                               "params": ["name": "memory_search", "arguments": ["query": "x"]]])
        let (_, data) = await MCPEndpoint.handle(body, automations: nil, tasks: nil)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("memory is not available"))
    }

    func testTheNoProjectFolderHasNoProjectFile() {
        XCTAssertNil(MemoryMCP.project(ChatSession.scratchWorkspace))
        XCTAssertNil(MemoryMCP.project(nil))
        XCTAssertEqual(MemoryMCP.source(thread: nil), "agent")
    }
}
