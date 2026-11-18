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

    func testTypedMessageReplyIsNotRead() async {
        session.input = "what changed?"
        session.send()
        await answer(0, "Two files changed.")
        XCTAssertEqual(spoken, [])
    }

    func testEditedVoiceNoteStillCountsUntilTheInputIsCleared() async {
        session.sendAfterDictation = false
        session.receiveTranscript("what changed")
        session.input += " today?"
        session.send()
        await answer(0, "Nothing yet.")
        XCTAssertEqual(spoken, ["Nothing yet."])

        session.receiveTranscript("scrap that")
        session.input = ""
        session.input = "typed instead"
        session.send()
        await answer(1, "Okay.")
        XCTAssertEqual(spoken, ["Nothing yet."])
    }

    func testQuietDuringACall() async {
        session.isQuiet = { true }
        session.receiveTranscript("status?")
        await answer(0, "All green.")
        XCTAssertEqual(spoken, [])
    }

    func testFailedTurnIsNotRead() async {
        session.receiveTranscript("status?")
        await answer(0, "Partial", error: "agent crashed")
        XCTAssertEqual(spoken, [])
    }

    func testQueuedVoiceNoteKeepsItsFlag() async {
        session.input = "typed first"
        session.send()
        await settle()
        session.receiveTranscript("then this by voice")
        XCTAssertEqual(session.queue.count, 1)
        await answer(0, "First answer.")
        XCTAssertEqual(spoken, [], "the typed turn's reply is not read")
        await answer(1, "Second answer.")
        XCTAssertEqual(spoken, ["Second answer."])
    }

    func testSpeakerButtonReadsAnyReply() async {
        session.input = "typed"
        session.send()
        await answer(0, "A typed reply.")
        let reply = try! XCTUnwrap(session.items.last { if case .assistant = $0.kind { true } else { false } })
        session.toggleSpeech(reply)
        await settle()
        XCTAssertEqual(spoken, ["A typed reply."])
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
