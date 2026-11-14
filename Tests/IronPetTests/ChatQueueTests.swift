import XCTest
@testable import IronPet

@MainActor
final class ChatQueueTests: XCTestCase {
    private var session: ChatSession!
    /// One entry per turn the session started; `deliver` sends events to that turn.
    private var turns: [ACPTurn] = []
    private var deliver: [(AgentEvent) -> Void] = []

    override func setUp() async throws {
        session = ChatSession(restore: false)
        turns = []
        deliver = []
        session.workspace = FileManager.default.temporaryDirectory
        session.turnRunner = { [unowned self] turn, onEvent in
            turns.append(turn)
            deliver.append(onEvent)
        }
    }

    /// Lets the Task that starts a turn run.
    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    private func complete(_ index: Int, error: String? = nil) async {
        await settle()
        deliver[index](.finished(error: error))
        await settle()
    }

    private func type(_ text: String) async {
        session.input = text
        session.send()
        await settle()
    }

    private var userTexts: [String] {
        session.items.compactMap { if case .user(let text) = $0.kind { text } else { nil } }
    }

    func testS1QueuesWhileRunning() async {
        await type("first")
        await type("a")
        await type("b")
        XCTAssertEqual(session.queue.map(\.text), ["a", "b"])
        XCTAssertEqual(session.input, "")
        XCTAssertEqual(turns.count, 1)
    }

    func testS2SendsQueuedOneAfterAnother() async {
        await type("first")
        await type("a")
        await type("b")
        await complete(0)
        XCTAssertEqual(turns.map(\.prompt), ["first", "a"])
        XCTAssertEqual(userTexts, ["first", "a"])
        XCTAssertEqual(session.queue.map(\.text), ["b"])
        await complete(1)
        XCTAssertEqual(userTexts, ["first", "a", "b"])
        await complete(2)
        XCTAssertTrue(session.queue.isEmpty)
        XCTAssertEqual(session.state, .done)
        XCTAssertEqual(turns.count, 3)
    }

    func testS3StopRestoresQueueToInput() async {
        await type("first")
        await type("a")
        await type("b")
        session.input = "draft"
        session.stop()
        await settle()
        XCTAssertTrue(session.queue.isEmpty)
        XCTAssertEqual(session.input, "draft\n\na\n\nb")
        XCTAssertEqual(turns.count, 1)
    }

    func testS3FailureRestoresQueueToInput() async {
        await type("first")
        await type("a")
        await type("b")
        await complete(0, error: "boom")
        XCTAssertEqual(turns.count, 1)
        XCTAssertTrue(session.queue.isEmpty)
        XCTAssertEqual(session.input, "a\n\nb")
        XCTAssertEqual(session.state, .failed)
    }

    func testS4AttachmentsStayWithTheirMessage() async {
        let shot = URL(fileURLWithPath: "/tmp/shot-a.png")
        let later = URL(fileURLWithPath: "/tmp/shot-b.png")
        await type("first")
        session.attach(shot)
        await type("a")
        session.attach(later)
        await type("b")
        XCTAssertEqual(session.queue.map(\.attachments), [[shot], [later]])
        XCTAssertTrue(session.attachments.isEmpty)
        await complete(0)
        XCTAssertEqual(turns[1].images + turns[1].files, [shot])
        await complete(1)
        XCTAssertEqual(turns[2].images + turns[2].files, [later])
    }

    func testS5RemoveQueued() async {
        await type("first")
        await type("a")
        await type("b")
        session.removeQueued(session.queue[0].id)
        XCTAssertEqual(session.queue.map(\.text), ["b"])
        await complete(0)
        XCTAssertEqual(turns.map(\.prompt), ["first", "b"])
        await complete(1)
        XCTAssertEqual(turns.count, 2)
    }

    func testS6SendsImmediatelyWhenIdle() async {
        await type("hello")
        XCTAssertTrue(session.queue.isEmpty)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(userTexts, ["hello"])
        XCTAssertEqual(session.input, "")
    }
}
