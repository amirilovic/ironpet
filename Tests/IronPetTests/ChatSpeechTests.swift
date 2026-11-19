import XCTest
@testable import IronPet

@MainActor
final class ChatSpeechTests: XCTestCase {
    private var session: ChatSession!
    private var deliver: [(AgentEvent) -> Void] = []
    /// What was sent to the speech server, in order.
    private var spoken: [String] = []

    override func setUp() async throws {
        session = ChatSession(restore: false)
        session.sendAfterDictation = true
        session.workspace = FileManager.default.temporaryDirectory
        deliver = []
        spoken = []
        session.turnRunner = { [unowned self] _, onEvent in deliver.append(onEvent) }
        session.speech.isEnabled = { true }
        // Recorded, then cut short, so no audio device is needed.
        session.speech.synthesize = { [unowned self] text in
            spoken.append(text)
            throw CancellationError()
        }
    }

    private func settle() async { for _ in 0..<10 { await Task.yield() } }

    private func answer(_ index: Int, _ text: String, error: String? = nil) async {
        await settle()
        deliver[index](.assistant(text))
        deliver[index](.finished(error: error))
        await settle()
    }

    func testVoiceNoteReplyIsReadAloud() async {
        session.receiveTranscript("what changed?")
        await answer(0, "Two files changed.\n\n```\ndiff\n```")
        XCTAssertEqual(spoken, ["Two files changed."])
    }

    func testTypedMessageReplyIsReadAloud() async {
        session.input = "what changed?"
        session.send()
        await answer(0, "Two files changed.")
        XCTAssertEqual(spoken, ["Two files changed."])
    }

    func testTelegramAndAutomationRepliesAreNotRead() async {
        session.submit("status?", from: .telegram(chat: 42))
        await answer(0, "All green.")
        XCTAssertTrue(session.submitFromAutomation("check CI", automation: "ci"))
        await answer(1, "CI passed.")
        XCTAssertEqual(spoken, [])
    }

    func testQuietDuringACall() async {
        session.isQuiet = { true }
        session.receiveTranscript("status?")
        await answer(0, "All green.")
        XCTAssertEqual(spoken, [])
    }

    func testOffNeverAsksWhetherItIsQuiet() async {
        var quietChecks = 0
        session.isQuiet = { quietChecks += 1; return false }
        session.speech.isEnabled = { false }
        session.receiveTranscript("status?")
        await answer(0, "All green.")
        XCTAssertEqual(spoken, [])
        XCTAssertEqual(quietChecks, 0, "the quiet check polls the microphone list, so it must not run while off")
    }

    func testFailedTurnIsNotRead() async {
        session.receiveTranscript("status?")
        await answer(0, "Partial", error: "agent crashed")
        XCTAssertEqual(spoken, [])
    }

    func testQueuedMessageIsReadWhenItsTurnEnds() async {
        session.input = "first"
        session.send()
        await settle()
        session.input = "then this"
        session.send()
        XCTAssertEqual(session.queue.count, 1)
        await answer(0, "First answer.")
        XCTAssertEqual(spoken, ["First answer."])
        await answer(1, "Second answer.")
        XCTAssertEqual(spoken, ["First answer.", "Second answer."])
    }

    func testSpeakerButtonReadsAnyReply() async {
        XCTAssertTrue(session.submitFromAutomation("check CI", automation: "ci"))
        await answer(0, "CI passed.")
        XCTAssertEqual(spoken, [])
        let reply = try! XCTUnwrap(session.items.last { if case .assistant = $0.kind { true } else { false } })
        session.toggleSpeech(reply)
        await settle()
        XCTAssertEqual(spoken, ["CI passed."])
    }

    func testSendingStopsSpeech() async {
        session.speech.synthesize = { _ in try await Task.sleep(nanoseconds: 10_000_000_000); return Data() }
        let item = ChatSession.Item(kind: .assistant("Long reply."))
        session.toggleSpeech(item)
        XCTAssertEqual(session.speech.speakingID, item.id)
        session.input = "interrupting"
        session.send()
        XCTAssertNil(session.speech.speakingID)
    }
}
