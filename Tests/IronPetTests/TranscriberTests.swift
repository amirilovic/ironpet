import XCTest
@testable import IronPet

/// Answers every request with a canned response (or error) and keeps what it was sent.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: (URLRequest) -> (Int, Data, Error?) = { _ in (200, Data(), nil) }
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        Self.requests.append(request)
        Self.bodies.append(body ?? Data())
        let (status, data, error) = Self.respond(request)
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class TranscriberTests: XCTestCase {
    private let wav = WAV.encode([0, 100, -100, 200])

    private func transcriber(baseURL: String = "http://stub.test/v1", key: String? = nil) -> Transcriber {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return Transcriber(baseURL: baseURL, model: "some/model", apiKey: key, session: URLSession(configuration: configuration))
    }

    override func setUp() {
        StubProtocol.requests = []
        StubProtocol.bodies = []
        StubProtocol.respond = { _ in (200, Data(#"{"text":"hello"}"#.utf8), nil) }
    }

    func testPostsMultipartToTranscriptionsAndReturnsText() async throws {
        let text = try await transcriber(baseURL: "http://stub.test/v1/").transcribe(wav: wav)
        XCTAssertEqual(text, "hello")
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://stub.test/v1/audio/transcriptions")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: StubProtocol.bodies[0], as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nsome/model"))
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\njson"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"voice-note.wav\""))
        XCTAssertTrue(body.contains("RIFF"))
        XCTAssertNotNil(StubProtocol.bodies[0].range(of: wav))
    }

    func testBearerOnlyWhenKeySet() async throws {
        _ = try await transcriber().transcribe(wav: wav)
        XCTAssertNil(StubProtocol.requests[0].value(forHTTPHeaderField: "Authorization"))
        _ = try await transcriber(key: "  ").transcribe(wav: wav)
        XCTAssertNil(StubProtocol.requests[1].value(forHTTPHeaderField: "Authorization"))
        _ = try await transcriber(key: "sk-test").transcribe(wav: wav)
        XCTAssertEqual(StubProtocol.requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    private func failure(_ status: Int, _ body: String = "") async -> TranscriptionError? {
        StubProtocol.respond = { _ in (status, Data(body.utf8), nil) }
        do {
            _ = try await transcriber().transcribe(wav: wav)
            return nil
        } catch {
            return error as? TranscriptionError
        }
    }

    func testServerErrorNamesTheStatus() async {
        let error = await failure(500, #"{"error":{"message":"model crashed"}}"#)
        XCTAssertEqual(error, .http(status: 500, detail: "model crashed"))
        XCTAssertTrue(error?.localizedDescription.contains("HTTP 500") == true)
    }

    func testUnauthorizedMentionsTheKey() async {
        let error = await failure(401)
        XCTAssertEqual(error, .http(status: 401, detail: ""))
        XCTAssertTrue(error?.localizedDescription.contains("HTTP 401") == true)
        XCTAssertTrue(error?.localizedDescription.contains("API key") == true)
    }

    func testMalformedJSONIsReported() async {
        let notJSON = await failure(200, "not json")
        let noText = await failure(200, #"{"words":"x"}"#)
        XCTAssertEqual(notJSON, .malformedResponse)
        XCTAssertEqual(noText, .malformedResponse)
    }

    func testTimeoutIsReported() async {
        StubProtocol.respond = { _ in (0, Data(), URLError(.timedOut)) }
        do {
            _ = try await transcriber().transcribe(wav: wav)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .timedOut)
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
    }

    func testConnectionRefusedNamesTheHost() async {
        StubProtocol.respond = { _ in (0, Data(), URLError(.cannotConnectToHost)) }
        do {
            _ = try await transcriber(baseURL: "http://localhost:9/v1").transcribe(wav: wav)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("localhost:9"), error.localizedDescription)
        }
    }

    func testInvalidBaseURL() async {
        do {
            _ = try await transcriber(baseURL: "not a url").transcribe(wav: wav)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .invalidURL("not a url"))
        }
    }
}

final class WAVTests: XCTestCase {
    func testHeaderDescribes16kMono16Bit() {
        let data = WAV.encode([1, 2, 3, 4])
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(data.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 16_000)
        XCTAssertEqual(WAV.duration(of: WAV.encode([Int16](repeating: 0, count: 16_000))), 1)
    }
}

final class VoiceSettingsTests: XCTestCase {
    func testVoiceIsOffAndHasNoHotkeyByDefault() {
        XCTAssertFalse(Config().voice.enabled)
        XCTAssertNil(VoiceController.hotkey(in: Config()))
    }

    func testHotkeyRegistersOnlyWithVoiceOn() {
        var config = Config()
        config.voice.enabled = true
        XCTAssertEqual(VoiceController.hotkey(in: config), "cmd+opt+v")
        config.hotkeys.voice = ""
        XCTAssertNil(VoiceController.hotkey(in: config))
    }

    func testDefaultVoiceHotkeyDoesNotCollide() {
        let hotkeys = Config().hotkeys
        let all = [hotkeys.chat, hotkeys.captureWindow, hotkeys.captureRegion, hotkeys.voice].compactMap(Shortcut.init)
        XCTAssertEqual(all.count, 4)
        for (index, shortcut) in all.enumerated() {
            XCTAssertFalse(all.enumerated().contains { $0.offset != index && $0.element == shortcut })
        }
    }

    @MainActor
    func testStartIsIgnoredWhileDisabled() {
        let voice = VoiceController()
        voice.isEnabled = { false }
        voice.start()
        XCTAssertEqual(voice.phase, .idle)
        XCTAssertFalse(voice.isBusy)
    }

    func testLevelsAreSilentBelowTheFloor() {
        XCTAssertEqual(PCMConverter.level(of: [Float](repeating: 0, count: 100)[...]), 0)
        XCTAssertGreaterThan(PCMConverter.level(of: [Float](repeating: 0.5, count: 100)[...]), 0.8)
    }
}

final class MeetingTranscriptionTests: XCTestCase {
    private let wav = WAV.encode([0, 100, -100, 200])

    private func transcriber() -> Transcriber {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return Transcriber(baseURL: "http://stub.test/v1", model: "some/model", apiKey: nil, session: URLSession(configuration: configuration))
    }

    private func formats() -> [String] {
        StubProtocol.bodies.map { body in
            let text = String(decoding: body, as: UTF8.self)
            guard let range = text.range(of: "name=\"response_format\"\r\n\r\n") else { return "" }
            return text[range.upperBound...].components(separatedBy: "\r\n")[0]
        }
    }

    override func setUp() {
        StubProtocol.requests = []
        StubProtocol.bodies = []
    }

    func testWhisperSegmentsAreTimed() async throws {
        StubProtocol.respond = { _ in
            (200, Data(#"{"text":"Hello there. Bye.","segments":[{"id":0,"start":0.0,"end":1.5,"text":" Hello there."},{"id":1,"start":2.25,"end":3,"text":" Bye."}]}"#.utf8), nil)
        }
        let segments = try await transcriber().transcribeSegments(wav: wav)
        XCTAssertEqual(segments, [TimedSegment(start: 0, end: 1.5, text: "Hello there."),
                                  TimedSegment(start: 2.25, end: 3, text: "Bye.")])
        XCTAssertEqual(formats(), ["verbose_json"])
        XCTAssertTrue(String(decoding: StubProtocol.bodies[0], as: UTF8.self).contains("filename=\"meeting.wav\""))
    }

    func testParakeetSentencesAreTimed() async throws {
        // The shape mlx-audio prints for Parakeet: `sentences`, each with tokens that are not needed here.
        StubProtocol.respond = { _ in
            (200, Data(#"{"text":"Can we ship it? Yes.","sentences":[{"text":" Can we ship it?","start":0.0,"end":1.52,"duration":1.52,"tokens":[{"id":1,"text":" Can","start":0,"end":0.24}]},{"text":" Yes.","start":1.52,"end":2.0,"duration":0.48,"tokens":[]}]}"#.utf8), nil)
        }
        let segments = try await transcriber().transcribeSegments(wav: wav)
        XCTAssertEqual(segments.map(\.text), ["Can we ship it?", "Yes."])
        XCTAssertEqual(segments.map(\.start), [0, 1.52])
        XCTAssertEqual(segments.map(\.end), [1.52, 2.0])
    }

    func testNewlineDelimitedSentencesAreRead() throws {
        let body = #"{"text":"Hi."}"# + "\n" + #"{"text":"Hi.","sentences":[{"text":" Hi.","start":0.5,"end":0.9}]}"#
        let segments = try Transcriber.parseSegments(Data(body.utf8))
        XCTAssertEqual(segments, [TimedSegment(start: 0.5, end: 0.9, text: "Hi.")])
    }

    func testTextOnlyBecomesOneSegmentAtTheStart() async throws {
        StubProtocol.respond = { _ in (200, Data(#"{"text":" All of it. In one go. "}"#.utf8), nil) }
        let segments = try await transcriber().transcribeSegments(wav: wav)
        XCTAssertEqual(segments, [TimedSegment(start: 0, end: 0, text: "All of it. In one go.")])
    }

    func testEmptyTextGivesNoSegments() async throws {
        StubProtocol.respond = { _ in (200, Data(#"{"text":"  "}"#.utf8), nil) }
        let segments = try await transcriber().transcribeSegments(wav: wav)
        XCTAssertEqual(segments, [])
    }

    func testRejectedVerboseJSONRetriesOnceWithPlainJSON() async throws {
        StubProtocol.respond = { request in
            let body = String(decoding: request.httpBodyStream.map { stream -> Data in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 8192)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                return data
            } ?? Data(), as: UTF8.self)
            if body.contains("verbose_json") {
                return (400, Data(#"{"error":{"message":"response_format 'verbose_json' is not compatible with model"}}"#.utf8), nil)
            }
            return (200, Data(#"{"text":"plain answer"}"#.utf8), nil)
        }
        let segments = try await transcriber().transcribeSegments(wav: wav)
        XCTAssertEqual(segments.map(\.text), ["plain answer"])
        XCTAssertEqual(formats(), ["verbose_json", "json"])
    }

    func testOtherErrorsAreNotRetried() async {
        StubProtocol.respond = { _ in (500, Data("boom".utf8), nil) }
        do {
            _ = try await transcriber().transcribeSegments(wav: wav)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .http(status: 500, detail: "boom"))
        }
        XCTAssertEqual(formats(), ["verbose_json"])
    }

    func testVoiceNotesStillSendPlainJSON() async throws {
        StubProtocol.respond = { _ in (200, Data(#"{"text":"hello"}"#.utf8), nil) }
        _ = try await transcriber().transcribe(wav: wav)
        XCTAssertEqual(formats(), ["json"])
        XCTAssertTrue(String(decoding: StubProtocol.bodies[0], as: UTF8.self).contains("filename=\"voice-note.wav\""))
    }
}
