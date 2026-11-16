import XCTest
@testable import IronPet

final class SegmentFilterTests: XCTestCase {
    private let rate = WAV.sampleRate

    private func noise(_ seconds: Double, amplitude: Int16) -> [Int16] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * Double(rate))).map { _ in Int16.random(in: -amplitude...amplitude, using: &generator) }
    }

    /// "Thank you." from `say`, converted to 16 kHz mono (Tests/IronPetTests/Fixtures).
    private func spokenThankYou() throws -> [Int16] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "thank-you", withExtension: "wav", subdirectory: "Fixtures"))
        let samples = WAV.samples(of: try Data(contentsOf: url))
        XCTAssertGreaterThan(samples.count, rate / 2)
        return samples
    }

    private func transcriber(responding body: String) -> Transcriber {
        StubProtocol.respond = { _ in (200, Data(body.utf8), nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return Transcriber(baseURL: "http://stub.test/v1", model: "m", apiKey: nil, session: URLSession(configuration: configuration))
    }

    func testHallucinationsOnSilentAndRoomNoiseWindowsAreDropped() async throws {
        let audio = [Int16](repeating: 0, count: 60 * rate) + noise(60, amplitude: 40)
        let body = #"{"text":"x","segments":[{"start":0,"end":30,"text":" Thank you."},{"start":30,"end":59,"text":" Bye."},{"start":60,"end":90,"text":" Thank you."},{"start":90,"end":120,"text":" Some invented sentence that is not a stock phrase."}]}"#
        let segments = try await transcriber(responding: body).transcribeSegments(wav: WAV.encode(audio))
        XCTAssertEqual(segments, [])
    }

    func testSpokenThankYouIsKeptAndSilentOneAroundItIsDropped() async throws {
        let speech = try spokenThankYou()
        let audio = noise(30, amplitude: 30) + speech + noise(30, amplitude: 30)
        let spokenStart = 30.0
        let spokenEnd = spokenStart + Double(speech.count) / Double(rate)
        let body = """
        {"text":"x","segments":[{"start":0,"end":30,"text":" Thank you."},
        {"start":\(spokenStart),"end":\(spokenEnd),"text":" Thank you."},
        {"start":\(spokenEnd),"end":\(spokenEnd + 30),"text":" Thank you."}]}
        """
        let segments = try await transcriber(responding: body).transcribeSegments(wav: WAV.encode(audio))
        XCTAssertEqual(segments.map(\.text), ["Thank you."])
        XCTAssertEqual(segments.first?.start, spokenStart)
    }

    func testQuietStockPhraseIsDroppedButQuietRealSentenceIsKept() {
        let quiet = noise(5, amplitude: 400) // RMS about 230
        let stock = TimedSegment(start: 0, end: 5, text: "Thank you.")
        let sentence = TimedSegment(start: 0, end: 5, text: "Let us move the review to Thursday.")
        XCTAssertFalse(SegmentFilter.keep(stock, samples: quiet))
        XCTAssertTrue(SegmentFilter.keep(sentence, samples: quiet))
    }

    func testServerNoSpeechProbabilityDropsLowConfidenceSegments() async throws {
        let audio = noise(5, amplitude: 5000)
        let body = #"{"text":"x","segments":[{"start":0,"end":2,"text":" Hallucinated.","no_speech_prob":0.9,"avg_logprob":-1.4},{"start":2,"end":4,"text":" Real.","no_speech_prob":0.1,"avg_logprob":-0.3},{"start":4,"end":5,"text":" Unsure.","no_speech_prob":0.9,"avg_logprob":-0.2}]}"#
        let segments = try await transcriber(responding: body).transcribeSegments(wav: WAV.encode(audio))
        XCTAssertEqual(segments.map(\.text), ["Real.", "Unsure."])
    }

    func testTextOnlyAnswerIsNotFiltered() async throws {
        let segments = try await transcriber(responding: #"{"text":"Thank you."}"#)
            .transcribeSegments(wav: WAV.encode(noise(5, amplitude: 5000)))
        XCTAssertEqual(segments.map(\.text), ["Thank you."])
    }

    // Voice notes and Telegram voice messages

    func testVoiceNoteDropsThankYouOverTrailingSilence() async throws {
        let speech = noise(3, amplitude: 5000)
        let audio = speech + [Int16](repeating: 0, count: 5 * rate)
        let body = #"{"text":"x","segments":[{"start":0,"end":3,"text":" Remind me at noon."},{"start":3,"end":8,"text":" Thank you."}]}"#
        let text = try await transcriber(responding: body).transcribe(wav: WAV.encode(audio))
        XCTAssertEqual(text, "Remind me at noon.")
    }

    func testSpokenThankYouVoiceNoteIsKept() async throws {
        let speech = try spokenThankYou()
        let end = Double(speech.count) / Double(rate)
        let body = #"{"text":"x","segments":[{"start":0,"end":\#(end),"text":" Thank you."}]}"#
        let text = try await transcriber(responding: body).transcribe(wav: WAV.encode(speech))
        XCTAssertEqual(text, "Thank you.")
    }

    func testVoiceNoteFallsBackToPlainJSONWhenVerboseIsRejected() async throws {
        var formats: [String] = []
        StubProtocol.respond = { request in
            let body = String(decoding: request.httpBodyStream.map { stream -> Data in
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                return data
            } ?? Data(), as: UTF8.self)
            formats.append(body.contains("verbose_json") ? "verbose_json" : "json")
            return formats.count == 1 ? (400, Data(#"{"error":"bad format"}"#.utf8), nil) : (200, Data(#"{"text":"hello there"}"#.utf8), nil)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let t = Transcriber(baseURL: "http://stub.test/v1", model: "m", apiKey: nil, session: URLSession(configuration: configuration))
        let text = try await t.transcribe(wav: WAV.encode(noise(2, amplitude: 5000)))
        XCTAssertEqual(text, "hello there")
        XCTAssertEqual(formats, ["verbose_json", "json"])
    }

    func testFullySilentVoiceNoteIsEmptyForSegmentsAndForTextOnlyAnswers() async throws {
        let silence = WAV.encode([Int16](repeating: 0, count: 3 * rate))
        let segmented = #"{"text":"x","segments":[{"start":0,"end":3,"text":" Thank you."}]}"#
        let a = try await transcriber(responding: segmented).transcribe(wav: silence)
        XCTAssertEqual(a, "")
        let b = try await transcriber(responding: #"{"text":"Thank you."}"#).transcribe(wav: silence)
        XCTAssertEqual(b, "")
    }

    func testNonWAVAudioIsTranscribedUnfiltered() async throws {
        let text = try await transcriber(responding: #"{"text":"Thank you."}"#)
            .transcribe(audio: Data("OggS-not-a-wav".utf8), filename: "v.ogg", mime: "audio/ogg")
        XCTAssertEqual(text, "Thank you.")
    }
}
