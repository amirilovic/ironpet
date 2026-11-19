import XCTest
@testable import IronPet

@MainActor
private final class FakeDeskAgent: FrontDeskAgent {
    var onPermission: ((ACPToolCall, @escaping (ApprovalDecision) -> Void) -> Void)?
    var turns: [ACPTurn] = []
    var replies = ["Two jobs are running.", "Started it."]
    private(set) var prepared = 0
    private(set) var newSessions = 0
    private(set) var shutDown = false
    private(set) var cancels = 0
    private var session = 1

    func prepare(_ workspace: URL) async { prepared += 1 }
    func startNewSession() {
        newSessions += 1
        session += 1
    }
    func cancel() { cancels += 1 }
    func shutdown() { shutDown = true }

    func runTurn(_ turn: ACPTurn, onEvent: @escaping (AgentEvent) -> Void) async {
        turns.append(turn)
        onEvent(.session("voice-\(session)"))
        onEvent(.assistant(replies.isEmpty ? "Okay." : replies.removeFirst()))
        onEvent(.finished(error: nil))
    }
}

@MainActor
final class FrontDeskTests: XCTestCase {
    private var folder: URL!
    private var savedThreads: URL!
    private var agents: [FakeDeskAgent] = []
    private var memory: FileMemoryStore!
    private var ended: [String] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("frontdesk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("threads"), withIntermediateDirectories: true)
        savedThreads = ThreadStore.directory
        ThreadStore.directory = folder.appendingPathComponent("threads")
        memory = FileMemoryStore(directory: folder.appendingPathComponent("memory"))
        agents = []
        ended = []
    }

    override func tearDown() async throws {
        ThreadStore.directory = savedThreads
        try? FileManager.default.removeItem(at: folder)
    }

    private func desk() -> FrontDesk {
        let desk = FrontDesk()
        desk.currentAgent = { (AgentCatalog.all[0], "haiku") }
        desk.makeAgent = { [unowned self] _ in
            let agent = FakeDeskAgent()
            agents.append(agent)
            return agent
        }
        let memory = memory!
        desk.memory = { memory }
        desk.onConversationEnded = { [unowned self] in ended.append($0) }
        desk.petName = { "Ghost" }
        desk.workspace = folder.appendingPathComponent("scratch")
        return desk
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func testAConversationIsOneVoiceThreadThatMemoryReadsWhenItEnds() async throws {
        _ = try memory.remember("Prefers short answers", scope: .me, source: MemoryNote.userSource).get()
        _ = try memory.remember("Leads the platform team", scope: .people, person: "Maria", source: MemoryNote.userSource).get()
        let desk = desk()
        desk.prepare()
        await until { agents.first?.prepared == 1 }

        let first = try await desk.reply(to: "what's running for Maria")
        let second = try await desk.reply(to: "start the lint")
        XCTAssertEqual(first, "Two jobs are running.")
        XCTAssertEqual(second, "Started it.")
        XCTAssertEqual(agents.count, 1, "one warm process")
        let turns = agents[0].turns
        XCTAssertEqual(turns.map(\.model), ["haiku", "haiku"])
        let preamble = try XCTUnwrap(turns[0].preamble)
        XCTAssertTrue(preamble.contains("You are Ghost"))
        XCTAssertTrue(preamble.contains("Prefers short answers"), "the user's notes are recalled")
        XCTAssertTrue(preamble.contains("Leads the platform team"), "so are the people the user names")
        XCTAssertNil(turns[1].preamble)

        let thread = try XCTUnwrap(ThreadStore.load("voice-1"))
        XCTAssertEqual(thread.voice, true)
        XCTAssertEqual(thread.title, "what's running for Maria")
        let said = thread.items.compactMap { item -> String? in
            if case .user(let text) = item.kind { return item.origin == ChatSession.voiceOrigin ? text : nil } else { return nil }
        }
        XCTAssertEqual(said, ["what's running for Maria", "start the lint"])

        desk.finish()
        XCTAssertEqual(agents[0].newSessions, 1)
        XCTAssertEqual(agents[0].turns.count, 2, "no extra turn after the conversation")
        XCTAssertEqual(ended, ["voice-1"], "the thread goes to memory's reflection pass")

        // The next conversation is a new session with the preamble again.
        _ = try await desk.reply(to: "anything need me")
        XCTAssertNotNil(agents[0].turns.last?.preamble)
        XCTAssertNotNil(ThreadStore.load("voice-2"))
    }

    func testAConversationWithNothingSaidIsNotReadByMemory() async throws {
        let desk = desk()
        desk.prepare()
        await until { agents.first?.prepared == 1 }
        desk.finish()
        XCTAssertEqual(agents[0].newSessions, 1)
        XCTAssertTrue(agents[0].turns.isEmpty)
        XCTAssertTrue(ended.isEmpty)
    }

    func testOnlyALiveReplyMayUseTools() async throws {
        let desk = desk()
        _ = try await desk.reply(to: "what's running")
        let agent = agents[0]
        var decision: ApprovalDecision?
        agent.onPermission?(ACPToolCall(title: "mcp__ironpet__jobs_start", kind: "other")) { decision = $0 }
        XCTAssertEqual(decision?.allow, false, "no reply is on the agent")
    }

    func testTheFrontDeskHandsWorkOffInsteadOfRunningIt() {
        XCTAssertTrue(FrontDesk.decision(for: ACPToolCall(title: "mcp__ironpet__jobs_start", kind: "other", rawInput: ["title": "x"])).allow)
        XCTAssertTrue(FrontDesk.decision(for: ACPToolCall(title: "mcp__ironpet__status_overview", kind: "other")).allow)
        XCTAssertTrue(FrontDesk.decision(for: ACPToolCall(title: "Read", kind: "read")).allow)
        XCTAssertFalse(FrontDesk.decision(for: ACPToolCall(title: "Run", kind: "execute", rawInput: ["command": "npm install"])).allow)
        XCTAssertFalse(FrontDesk.decision(for: ACPToolCall(title: "Edit", kind: "edit", rawInput: ["file_path": "/work/a.swift"])).allow)
        XCTAssertFalse(FrontDesk.decision(for: ACPToolCall(title: "mcp__other__jobs_start", kind: "other")).allow)
    }

    func testFastestModel() {
        let models = [ChatModel(id: "opus", name: "Claude Opus 4.8"), ChatModel(id: "gemini-pro", name: "Gemini 3 Pro"),
                      ChatModel(id: "haiku", name: "Claude Haiku 4.5")]
        XCTAssertEqual(FrontDesk.fastestModel(in: models), "haiku")
        XCTAssertNil(FrontDesk.fastestModel(in: [ChatModel(id: "gemini-pro", name: "Gemini 3 Pro")]), "gemini is not a mini")
        XCTAssertEqual(FrontDesk.fastestModel(in: [ChatModel(id: "gpt-5.6-mini", name: "GPT-5.6 mini")]), "gpt-5.6-mini")
    }

    func testVoiceScopeMarksIronpetsServerOnly() {
        let servers: [JSON] = [["name": "ironpet", "command": "/bin/ironpet", "env": []], ["name": "other", "command": "x"]]
        let scoped = MCPEndpoint.voiceScoped(servers)
        XCTAssertEqual((scoped[0]["env"] as? [JSON])?.first?["value"] as? String, "voice")
        XCTAssertNil(scoped[1]["env"])
        XCTAssertEqual(MCPEndpoint.path(forScope: "voice"), MCPEndpoint.voicePath)
        XCTAssertEqual(MCPEndpoint.path(forScope: "job"), MCPEndpoint.jobPath)
        XCTAssertEqual(MCPEndpoint.path(forScope: nil), "/mcp")
    }
}
