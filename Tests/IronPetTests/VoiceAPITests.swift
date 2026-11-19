import XCTest
@testable import IronPet

/// Drives speaking, stopping and transcribing only through `IronPetAPI`, with the voice server stubbed.
@MainActor
final class VoiceAPITests: XCTestCase {
    private var session: ChatSession!
    private var api: IronPetAPI!
    private var synthesized: [String] = []

    override func setUp() async throws {
        session = ChatSession(restore: false)
        api = APITestSupport.makeAPI(chat: session)
        synthesized = []
        api.voice.synthesize = { [unowned self] text in synthesized.append(text); return Data([UInt8](repeating: 1, count: 64)) }
        session.speech.synthesize = api.voice.synthesize
    }

    private let reply = "First sentence here. Second sentence follows right after it. " + String(repeating: "More words fill the third part of the reply. ", count: 12)

    func testSpeakingNeedsTheSettingAndSomethingToRead() {
        XCTAssertThrowsError(try api.voice.speak(SpeakRequest(text: reply))) { XCTAssertEqual(($0 as? APIError)?.code, .unavailable) }
        api.settings.update { $0.speech.enabled = true }
        XCTAssertThrowsError(try api.voice.speak(SpeakRequest(text: "```\ncode only\n```"))) { XCTAssertEqual(($0 as? APIError)?.code, .invalid) }
    }

    func testSpeakStartsReadingAndStopEndsIt() throws {
        api.settings.update { $0.speech.enabled = true }
        XCTAssertFalse(api.voice.status.speaking)
        try api.voice.speak(SpeakRequest(text: reply))
        XCTAssertTrue(api.voice.status.speaking)
        XCTAssertTrue(api.voice.status.speechEnabled)
        api.voice.stop()
        XCTAssertFalse(api.voice.status.speaking)
    }

    func testAudioHandsBackChunksWithoutPlayingAnything() async throws {
        api.settings.update { $0.speech.enabled = true }
        var chunks: [SpeechChunk] = []
        for try await chunk in try api.voice.audio(SpeakRequest(text: reply)) { chunks.append(chunk) }
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map(\.index), Array(0..<chunks.count))
        XCTAssertTrue(chunks.allSatisfy { $0.count == chunks.count && $0.mime == "audio/wav" && $0.audio.count == 64 })
        XCTAssertEqual(synthesized.count, chunks.count)
        XCTAssertEqual(synthesized.first, "First sentence here.", "the first chunk is one sentence, so audio starts early")
        XCTAssertFalse(api.voice.status.speaking, "nothing played on this Mac")
        XCTAssertThrowsError(try api.voice.audio(SpeakRequest(text: ""))) { XCTAssertEqual(($0 as? APIError)?.code, .invalid) }
    }

    func testAServerFailureReachesTheCaller() async throws {
        api.settings.update { $0.speech.enabled = true }
        api.voice.synthesize = { _ in throw SpeechError.noAudio }
        do {
            for try await _ in try api.voice.audio(SpeakRequest(text: reply)) {}
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual((error as? APIError)?.code, .failed)
        }
    }

    func testTranscribeNeedsVoiceInputAndAudio() async throws {
        api.voice.transcribeAudio = { audio, name, mime in "\(audio.count) bytes \(name) \(mime)" }
        do { _ = try await api.voice.transcribe(TranscribeRequest(audio: Data([1, 2, 3]))); XCTFail("transcribed while off") } catch {
            XCTAssertEqual((error as? APIError)?.code, .unavailable)
        }
        api.settings.update { $0.voice.enabled = true }
        let text = try await api.voice.transcribe(TranscribeRequest(audio: Data([1, 2, 3]), fileName: "note.ogg", mime: "audio/ogg"))
        XCTAssertEqual(text, "3 bytes note.ogg audio/ogg")
        do { _ = try await api.voice.transcribe(TranscribeRequest(audio: Data())); XCTFail("transcribed nothing") } catch {
            XCTAssertEqual((error as? APIError)?.code, .invalid)
        }
        api.voice.transcribeAudio = { _, _, _ in throw TranscriptionError.timedOut }
        do { _ = try await api.voice.transcribe(TranscribeRequest(audio: Data([1]))); XCTFail("expected a failure") } catch {
            XCTAssertEqual((error as? APIError)?.code, .failed)
        }
    }

    func testRequestsRoundTripAsJSON() throws {
        let request = TranscribeRequest(audio: Data([1, 2]), fileName: "a.wav", mime: "audio/wav")
        XCTAssertEqual(try JSONDecoder().decode(TranscribeRequest.self, from: JSONEncoder().encode(request)), request)
        let chunk = SpeechChunk(index: 0, count: 2, mime: "audio/wav", audio: Data([9]))
        XCTAssertEqual(try JSONDecoder().decode(SpeechChunk.self, from: JSONEncoder().encode(chunk)), chunk)
    }
}
