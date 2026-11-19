import XCTest
@testable import IronPet

@MainActor
final class ChatResetTests: XCTestCase {
    private var session: ChatSession!
    private var deliver: [(AgentEvent) -> Void] = []
    private var log: [String] = []
    private var turns: [ACPTurn] = []
    private let folder = FileManager.default.temporaryDirectory

    override func setUp() async throws {
        TestMemory.isolate()
        session = ChatSession(restore: false)
        deliver = []
        turns = []
        log = []
        ChatLog.sink = { [unowned self] in log.append($0) }
        session.workspace = folder
        session.turnRunner = { [unowned self] turn, onEvent in
            turns.append(turn)
            deliver.append(onEvent)
        }
    }

    override func tearDown() async throws { ChatLog.sink = nil }

    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    private func chatted(thread: String = "s1") async {
        session.input = "hello"
        session.send()
        await settle()
        deliver[0](.session(thread))
        deliver[0](.assistant("hi"))
        deliver[0](.finished(error: nil))
        await settle()
    }

    private func thread(id: String = "t2") -> ChatThread {
        ChatThread(id: id, title: "Old", workspace: "/tmp", updatedAt: Date(),
                   items: [.init(kind: .user("old"))], agent: session.agent.id)
    }

    func testS1NewChatClearsAndKeepsAuto() async {
        await chatted()
        session.autoMode = true
        session.newChat()
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertNil(session.threadID)
        XCTAssertTrue(session.autoMode)
    }

    func testS1AutoSurvivesNewChatAndRelaunch() async {
        let defaults = UserDefaults.standard
        let keys = ["chatAutoMode", "chatThread", "chatDraft", "chatAttachments"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        defaults.removeObject(forKey: "chatThread")
        let first = ChatSession(restore: true)
        first.autoMode = true
        first.newChat()
        XCTAssertTrue(defaults.bool(forKey: "chatAutoMode"), "a new chat must not overwrite the saved Auto value")
        let relaunched = ChatSession(restore: true)
        XCTAssertTrue(relaunched.autoMode)
    }

    func testS2OpenThreadKeepsAuto() async {
        session.autoMode = true
        session.open(thread())
        XCTAssertEqual(session.threadID, "t2")
        XCTAssertTrue(session.autoMode)
    }

    func testS3FailedTurnKeepsTranscriptAndThread() async {
        await chatted()
        let before = session.items.map(\.id)
        session.input = "again"
        session.send()
        await settle()
        deliver[1](.finished(error: "The agent stopped"))
        await settle()
        XCTAssertEqual(session.threadID, "s1")
        XCTAssertEqual(Array(session.items.map(\.id).prefix(before.count)), before)
    }

    func testS3LoadFallbackKeepsThread() async {
        await chatted()
        session.input = "again"
        session.send()
        await settle()
        // The agent could not load s1 and made a new session.
        deliver[1](.session("fresh"))
        deliver[1](.finished(error: nil))
        await settle()
        XCTAssertEqual(session.threadID, "s1")
        XCTAssertGreaterThanOrEqual(session.items.count, 3)
        XCTAssertTrue(log.contains { $0.contains("fresh") && $0.contains("kept") })
        session.input = "third"
        session.send()
        await settle()
        XCTAssertEqual(turns.last?.resume, "s1", "the next message continues in the same thread")
    }

    func testS4TelegramWhileBusyQueuesWithoutClearing() async {
        await chatted()
        session.autoMode = true
        session.input = "busy"
        session.send()
        await settle()
        let count = session.items.count
        session.submit("from phone", from: .telegram(chat: 7))
        XCTAssertEqual(session.userQueueCount, 1)
        XCTAssertEqual(session.items.count, count)
        XCTAssertEqual(session.threadID, "s1")
        session.cancel(from: .telegram(chat: 7))
        XCTAssertEqual(session.userQueueCount, 0)
        XCTAssertEqual(session.items.count, count)
        XCTAssertTrue(session.autoMode)
        XCTAssertFalse(log.contains { $0.hasPrefix("chat cleared") })
    }

    func testShowingTheWindowKeepsTheChat() async {
        await chatted()
        session.prepareForShow()
        XCTAssertFalse(session.items.isEmpty)
        XCTAssertEqual(session.threadID, "s1")
        XCTAssertFalse(log.contains { $0.hasPrefix("chat cleared") })
    }

    func testS5EachChangeLogsItsReason() async {
        await chatted()
        session.newChat(reason: "menu")
        XCTAssertEqual(log.filter { $0.hasPrefix("chat cleared") }.count, 1)
        XCTAssertTrue(log.last?.contains("menu") == true)
        log = []
        session.open(thread())
        XCTAssertEqual(log.filter { $0.hasPrefix("thread t2 loaded") }.count, 1)
        log = []
        session.use(URL(fileURLWithPath: "/tmp/elsewhere"))
        XCTAssertEqual(log.filter { $0.hasPrefix("workspace changed") }.count, 1)
        log = []
        if let other = AgentCatalog.all.first(where: { $0 != session.agent }) {
            session.setAgent(other)
            XCTAssertTrue(log.contains { $0.hasPrefix("agent changed") })
        }
    }
}
