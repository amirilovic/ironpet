import XCTest
@testable import IronPet

@MainActor
final class ChatQueueTests: XCTestCase {
    private var session: ChatSession!
    /// One entry per turn the session started; `deliver` sends events to that turn.
    private var turns: [ACPTurn] = []
    private var deliver: [(AgentEvent) -> Void] = []

    override func setUp() async throws {
        TestMemory.isolate()
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

    private var assistantTexts: [String] {
        session.items.compactMap { if case .assistant(let text) = $0.kind { text } else { nil } }
    }

    func testMemoryHearsTurnEndsThreadSwitchesAndAutomationAnswers() async {
        let saved = ThreadStore.directory
        ThreadStore.directory = FileManager.default.temporaryDirectory.appendingPathComponent("memory-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ThreadStore.directory); ThreadStore.directory = saved }
        var ended: [String] = [], left: [String] = [], answers: [String] = []
        session.onTurnEnded = { ended.append($0) }
        session.onThreadLeft = { left.append($0) }
        session.onAutomationAnswer = { id, answer in answers.append("\(id): \(answer)") }
        await type("hello")
        deliver[0](.session("thread-1"))
        await complete(0)
        XCTAssertEqual(ended, ["thread-1"])
        session.submitFromAutomation("check things", automation: "watcher")
        await settle()
        deliver[1](.assistant("All quiet."))
        await complete(1)
        XCTAssertEqual(answers, ["watcher: All quiet."])
        session.newChat()
        XCTAssertEqual(left, ["thread-1"])
        session.newChat()
        XCTAssertEqual(left, ["thread-1"], "a chat with no thread has nothing to leave")
    }

    func testBackgroundResultAfterTheTurnShowsAsItsOwnReplyAndKeepsTheChatIdle() async {
        await type("start it")
        deliver[0](.assistant("started"))
        await complete(0)
        XCTAssertFalse(session.isRunning)
        session.handleBackground(.assistant("RESULT "))
        session.handleBackground(.assistant("done"))
        XCTAssertEqual(assistantTexts, ["started", "RESULT done"])
        XCTAssertFalse(session.isRunning)
        await type("next")
        XCTAssertEqual(turns.count, 2, "a new message starts at once instead of queueing")
        XCTAssertTrue(session.queue.isEmpty)
    }

    private var itemKinds: [String] {
        session.items.map {
            switch $0.kind {
            case .assistant(let text): "assistant:\(text)"
            case .tool(let summary, _): "tool:\(summary)"
            default: "other"
            }
        }
    }

    func testSubagentToolCallsDoNotSplitTheReply() async {
        await type("go")
        deliver[0](.assistant("an offer to start "))
        deliver[0](.toolStarted(id: "agent", summary: "Research"))
        deliver[0](.assistant("then "))
        deliver[0](.subagentTool(parent: "agent", id: "s1", summary: "Ran `ls`", ok: nil))
        deliver[0](.assistant("recording."))
        deliver[0](.subagentTool(parent: "agent", id: "s1", summary: "Ran `ls`", ok: true))
        XCTAssertEqual(itemKinds.dropFirst(), ["assistant:an offer to start ", "tool:Research · 1 tool call", "assistant:then recording."])
    }

    func testSubagentCallBetweenTextChunksKeepsOneMessage() async {
        await type("go")
        deliver[0](.toolStarted(id: "agent", summary: "Research"))
        deliver[0](.assistant("an offer to start "))
        deliver[0](.subagentTool(parent: "agent", id: "s1", summary: "Ran `ls`", ok: nil))
        deliver[0](.assistant("recording."))
        XCTAssertEqual(assistantTexts, ["an offer to start recording."])
    }

    func testMainAgentToolStillSplitsTheReplyInline() async {
        await type("go")
        deliver[0](.assistant("before "))
        deliver[0](.toolStarted(id: "t", summary: "Ran `ls`"))
        deliver[0](.assistant("after"))
        XCTAssertEqual(itemKinds.dropFirst(), ["assistant:before ", "tool:Ran `ls`", "assistant:after"])
    }

    func testSubagentCallAfterTheTurnUpdatesItsParentRow() async {
        await type("go")
        deliver[0](.toolStarted(id: "agent", summary: "Research"))
        await complete(0)
        session.handleBackground(.subagentTool(parent: "agent", id: "s1", summary: "Ran `ls`", ok: nil))
        session.handleBackground(.subagentTool(parent: "agent", id: "s2", summary: "Read a.txt", ok: nil))
        XCTAssertEqual(itemKinds.dropFirst(), ["tool:Research · 2 tool calls"])
        XCTAssertFalse(session.isRunning)
    }

    func testBackgroundUpdateDuringTheNextTurnIsKept() async {
        await type("one")
        session.handleBackground(.assistant("late result"))
        XCTAssertEqual(assistantTexts, ["late result"])
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
