import XCTest
@testable import IronPet

@MainActor
private final class FakeClips: ClipPlaying {
    var played: [String] = []
    var stops = 0
    /// Holds each clip until the test releases it, so a stop can land mid-clip.
    var hold = false
    private var waiting: CheckedContinuation<Void, Error>?

    func play(_ audio: Data) async throws {
        played.append(String(decoding: audio, as: UTF8.self))
        guard hold else { return }
        try await withCheckedThrowingContinuation { waiting = $0 }
    }

    func stop() {
        stops += 1
        waiting?.resume(throwing: CancellationError())
        waiting = nil
    }
}

@MainActor
final class SpeechPlayerTests: XCTestCase {
    private var clips: FakeClips!
    private var speech: SpeechPlayer!
    private var requested: [String] = []

    override func setUp() async throws {
        clips = FakeClips()
        speech = SpeechPlayer(player: clips)
        speech.isEnabled = { true }
        requested = []
        speech.synthesize = { [unowned self] text in
            self.requested.append(text)
            return Data(text.utf8)
        }
    }

    private func waitUntilIdle() async {
        for _ in 0..<200 where speech.isSpeaking { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testReadsEveryChunkInOrder() async {
        let id = UUID()
        speech.speak("First one. Second one. Third one.\n\n```\ncode\n```", id: id)
        XCTAssertEqual(speech.speakingID, id)
        await waitUntilIdle()
        XCTAssertEqual(clips.played, ["First one.", "Second one. Third one."])
        XCTAssertEqual(requested, clips.played)
        XCTAssertNil(speech.speakingID)
        XCTAssertEqual(speech.phase, .idle)
    }

    func testDoesNothingWhenOffOrNothingToSay() {
        speech.speak("```\nls\n```", id: UUID())
        XCTAssertFalse(speech.isSpeaking)
        speech.isEnabled = { false }
        speech.speak("Hello.", id: UUID())
        XCTAssertFalse(speech.isSpeaking)
        XCTAssertEqual(requested, [])
    }

    func testStopCutsTheClipAndSkipsTheRest() async {
        clips.hold = true
        speech.speak("One. Two is a longer sentence. Three.", id: UUID())
        for _ in 0..<200 where clips.played.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        speech.stop()
        XCTAssertFalse(speech.isSpeaking)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(clips.played, ["One."])
    }

    func testANewReplyReplacesTheOneBeingRead() async {
        clips.hold = true
        let first = UUID(), second = UUID()
        speech.speak("Old reply.", id: first)
        for _ in 0..<200 where clips.played.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        speech.speak("New reply.", id: second)
        XCTAssertEqual(speech.speakingID, second)
        for _ in 0..<200 where clips.played.count < 2 { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(speech.speakingID, second, "the stopped read must not clear the new one")
        XCTAssertEqual(clips.played, ["Old reply.", "New reply."])
    }

    func testAFailedRequestIsReported() async {
        var failures: [String] = []
        speech.onFailure = { failures.append($0) }
        speech.synthesize = { _ in throw SpeechError.noAudio }
        speech.speak("Hello there.", id: UUID())
        await waitUntilIdle()
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("no audio"))
        XCTAssertEqual(clips.played, [])
    }
}
