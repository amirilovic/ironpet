import XCTest
@testable import IronPet

/// The Mac window's side of the chat, on top of `ChatAPI`: the draft, and a copy of the shared chat kept current by events.
@MainActor
final class ChatViewModelTests: XCTestCase {
    private var h: ChatHarness!
    private var deliver: [(AgentEvent) -> Void] = []

    override func setUp() async throws {
        TestMemory.isolate()
        h = ChatHarness()
        deliver = []
        h.session.workspace = FileManager.default.temporaryDirectory
        h.session.turnRunner = { [unowned self] _, emit in deliver.append(emit) }
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        await h.model.settle()
    }

    func testTheCopyFollowsAStreamingReplyOneMessageAtATime() async throws {
        await h.type("hello")
        await settle()
        deliver[0](.assistant("Hi"))
        await settle()
        deliver[0](.assistant(" there"))
        await settle()
        let texts = h.model.items.compactMap { item -> String? in if case .assistant(let t) = item.kind { return t } else { return nil } }
        XCTAssertEqual(texts, ["Hi there"], "the streamed reply is one message in the copy, not one per chunk")
        XCTAssertTrue(h.model.isRunning)
        deliver[0](.finished(error: nil))
        await settle()
        XCTAssertFalse(h.model.isRunning)
        XCTAssertEqual(h.model.items.map(\.id), h.session.items.map(\.id))
    }

    func testReadsAreForgottenOnceTheyFinish() async {
        await h.type("hello")
        await settle()
        for chunk in 0..<50 { deliver[0](.assistant("chunk \(chunk) ")) }
        await settle()
        XCTAssertTrue(h.model.pendingReadCount == 0, "finished reads must not pile up")
    }

    func testSendingClearsTheDraftAndKeepsItWhenNothingWasSent() async {
        h.model.input = "first"
        h.model.attachments = [URL(fileURLWithPath: "/tmp/a.png")]
        await h.model.sendNow()
        XCTAssertEqual(h.model.input, "")
        XCTAssertTrue(h.model.attachments.isEmpty)
        XCTAssertNil(h.model.replyingTo)
    }

    func testStopGivesQueuedMessagesBackToTheDraftAfterWhatIsThere() async {
        await h.type("running")
        h.model.input = "queued one"
        await h.model.sendNow()
        await settle()
        XCTAssertEqual(h.model.queue.map(\.text), ["queued one"])
        h.model.input = "half typed"
        await h.model.stopNow()
        await settle()
        XCTAssertEqual(h.model.input, "half typed\n\nqueued one")
        XCTAssertTrue(h.model.queue.isEmpty)
    }

    func testOptionsChangesReachTheWindow() async throws {
        await h.api.setAutoMode(true)
        await h.api.setModel("fast")
        await settle()
        XCTAssertTrue(h.model.autoMode)
        XCTAssertEqual(h.model.model, "fast")
        h.session.receiveCommands([SlashCommand(name: "compact", detail: "Shrink")])
        await settle()
        XCTAssertTrue(h.model.commands.isEmpty, "nothing is fetched until the user types a slash")
        h.model.input = "/co"
        await settle()
        XCTAssertEqual(h.model.slashMatches.map(\.name), ["compact"])
        XCTAssertTrue(h.model.completeSlash())
        XCTAssertEqual(h.model.input, "/compact ")
    }

    func testAVoiceNoteThatFailsLeavesARetryableNoticeInTheChat() async {
        h.model.voice.onFailure?("Could not transcribe", true)
        await settle()
        let notice = h.model.items.last
        guard case .error(let text)? = notice?.kind else { return XCTFail("no notice") }
        XCTAssertEqual(text, "Could not transcribe")
        XCTAssertEqual(h.model.voiceRetryItem, notice?.id)
        h.model.retryVoice()
        await settle()
        XCTAssertNil(h.model.voiceRetryItem)
        XCTAssertTrue(h.model.items.isEmpty, "the notice goes away when the note is tried again")
    }

    func testReplyingQuotesAMessageAndTheNextSendCarriesIt() async throws {
        await h.type("what is 2+2?")
        await settle()
        deliver[0](.assistant("4"))
        deliver[0](.finished(error: nil))
        await settle()
        let answer = try XCTUnwrap(h.model.items.last)
        h.model.reply(to: answer)
        XCTAssertEqual(h.model.replyingTo?.text, "4")
        XCTAssertEqual(h.model.replyFocusTick, 1)
    }
}
