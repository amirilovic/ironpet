import XCTest
@testable import IronPet

/// Drives the shared chat only through `IronPetAPI`. The agent is a scripted `turnRunner`; the helper receives the chat session only
/// so the test can set that runner, the way it would set a fake agent process.
@MainActor
final class ChatAPITests: XCTestCase {
    private var events: APIEventBus!
    private var seen: [APIEvent] = []
    private var session: ChatSession!
    private var api: IronPetAPI!
    private var turns: [ACPTurn] = []
    private var deliver: [(AgentEvent) -> Void] = []
    private var heard: [(ChatOrigin, ChatTurnEvent)] = []
    private var previousThreads: URL!
    private var threads: URL!

    override func setUp() async throws {
        events = APIEventBus()
        seen = []
        events.subscribe { [unowned self] in seen.append($0) }
        session = ChatSession(restore: false)
        session.workspace = FileManager.default.temporaryDirectory
        turns = []
        deliver = []
        heard = []
        session.turnRunner = { [unowned self] turn, onEvent in
            turns.append(turn)
            deliver.append(onEvent)
        }
        api = APITestSupport.makeAPI(events: events, chat: session)
        api.chat.onTurn { [unowned self] origin, event in heard.append((origin, event)) }
        previousThreads = ThreadStore.directory
        threads = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-api-threads-\(UUID().uuidString)")
        ThreadStore.directory = threads
    }

    override func tearDown() async throws {
        ThreadStore.directory = previousThreads
        try? FileManager.default.removeItem(at: threads)
    }

    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    private let phone = ChatOrigin(client: "ios", ref: "device-1")

    func testASentMessageRunsATurnAndTheSenderHearsTheAnswer() async throws {
        try api.chat.send(SendChatRequest(text: "  What changed today?  ", origin: phone))
        await settle()
        XCTAssertEqual(turns.map(\.prompt), ["What changed today?"])
        XCTAssertEqual(api.chat.status.running, true)
        deliver[0](.assistant("Two files."))
        deliver[0](.finished(error: nil))
        await settle()
        XCTAssertEqual(api.chat.status.running, false)
        XCTAssertEqual(heard.map(\.0), [phone, phone])
        XCTAssertEqual(heard.last?.1, .finished("Two files."))
        let items = api.chat.transcript()
        XCTAssertEqual(items.first?.origin, "ios", "the transcript marks where the message came from")
        XCTAssertEqual(api.chat.title, "What changed today?")
    }

    func testChatChangesArriveOnTheBusWithIncreasingSequenceNumbers() async throws {
        try api.chat.send(SendChatRequest(text: "hello", origin: phone))
        await settle()
        deliver[0](.assistant("Hi"))
        deliver[0](.finished(error: nil))
        await settle()
        let kinds = Set(seen.map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.chatItem, .chatState]))
        XCTAssertEqual(seen.map(\.seq), Array(1...seen.count))
    }

    func testABusyAgentQueuesTheNextMessageAndCancelDropsIt() async throws {
        try api.chat.send(SendChatRequest(text: "first", origin: phone))
        try api.chat.send(SendChatRequest(text: "second", origin: phone))
        await settle()
        XCTAssertEqual(api.chat.status.queued, 1)
        XCTAssertTrue(heard.contains { $0.1 == .queued })
        api.chat.cancel(from: phone)
        XCTAssertEqual(api.chat.status.queued, 0)
    }

    func testApprovalsAreListedAndDecidedThroughTheAPI() async throws {
        try api.chat.send(SendChatRequest(text: "delete the build folder", origin: phone))
        await settle()
        var decision: ApprovalDecision?
        session.handlePermission(ACPToolCall(id: "1", title: "Run", kind: "execute", rawInput: ["command": "rm -rf build"])) { decision = $0 }
        let pending = try XCTUnwrap(api.chat.approvalList().first)
        XCTAssertTrue(heard.contains { if case .approval(let id, _, _) = $0.1 { return id == pending.id } else { return false } })
        try api.chat.decide(DecideApprovalRequest(id: pending.id, allow: false))
        XCTAssertEqual(decision?.allow, false)
        XCTAssertTrue(api.chat.approvalList().isEmpty)
        XCTAssertTrue(heard.contains { $0.1 == .approvalDecided(id: pending.id, outcome: .denied) })
        XCTAssertThrowsError(try api.chat.decide(DecideApprovalRequest(id: pending.id, allow: true))) {
            XCTAssertEqual(($0 as? APIError)?.code, .notFound)
        }
    }

    func testStopEndsTheTurnAndTellsTheSender() async throws {
        try api.chat.send(SendChatRequest(text: "long job", origin: phone))
        await settle()
        api.chat.stop()
        XCTAssertFalse(api.chat.status.running)
        XCTAssertEqual(heard.last?.1, .failed("Stopped on the Mac."))
    }

    func testAnEmptyMessageIsRejected() {
        XCTAssertThrowsError(try api.chat.send(SendChatRequest(text: "   ", origin: phone))) { XCTAssertEqual(($0 as? APIError)?.code, .invalid) }
    }

    func testThreadsListOpenAndNewChat() async throws {
        try api.chat.send(SendChatRequest(text: "remember the milk", origin: phone))
        await settle()
        deliver[0](.session("thread-1"))
        deliver[0](.assistant("Noted."))
        deliver[0](.finished(error: nil))
        await settle()
        let saved = try XCTUnwrap(api.chat.threads().first)
        XCTAssertEqual(saved.title, "remember the milk")
        api.chat.newChat()
        XCTAssertTrue(api.chat.transcript().isEmpty)
        XCTAssertEqual(api.chat.title, "New chat")
        try api.chat.openThread(saved.id)
        XCTAssertEqual(api.chat.title, "remember the milk")
        XCTAssertThrowsError(try api.chat.openThread("nope")) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
    }

    func testRequestsRoundTripAsJSON() throws {
        let request = SendChatRequest(text: "hi", origin: phone, attachments: [URL(fileURLWithPath: "/tmp/a.png")])
        XCTAssertEqual(try JSONDecoder().decode(SendChatRequest.self, from: JSONEncoder().encode(request)), request)
        let status = ChatStatus(running: true, title: "t", queued: 2, pendingApprovals: 1)
        XCTAssertEqual(try JSONDecoder().decode(ChatStatus.self, from: JSONEncoder().encode(status)), status)
    }
}
