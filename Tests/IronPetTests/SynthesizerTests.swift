import XCTest
@testable import IronPet

final class SynthesizerTests: XCTestCase {
    private let audio = WAV.encode([Int16](repeating: 100, count: 64))

    private func synthesizer(baseURL: String = "http://stub.test/v1", key: String? = nil, speed: Double = 1) -> Synthesizer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return Synthesizer(baseURL: baseURL, model: "some/tts", voice: "am_puck", speed: speed, apiKey: key,
                           session: URLSession(configuration: configuration))
    }

    override func setUp() {
        StubProtocol.requests = []
        StubProtocol.bodies = []
        let audio = audio
        StubProtocol.respond = { _ in (200, audio, nil) }
    }

    func testPostsJSONToSpeechAndReturnsTheAudio() async throws {
        let data = try await synthesizer(baseURL: "http://stub.test/v1/").speak("Hi there.")
        XCTAssertEqual(data, audio)
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://stub.test/v1/audio/speech")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StubProtocol.bodies[0]) as? NSDictionary)
        XCTAssertEqual(body, ["model": "some/tts", "input": "Hi there.", "voice": "am_puck", "speed": 1, "response_format": "wav"])
    }

    func testSendsTheSpeed() async throws {
        _ = try await synthesizer(speed: 1.6).speak("a")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StubProtocol.bodies[0]) as? [String: Any])
        XCTAssertEqual(body["speed"] as? Double, 1.6)
    }

    func testBearerOnlyWhenKeySet() async throws {
        _ = try await synthesizer().speak("a")
        XCTAssertNil(StubProtocol.requests[0].value(forHTTPHeaderField: "Authorization"))
        _ = try await synthesizer(key: "sk-test").speak("a")
        XCTAssertEqual(StubProtocol.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    private func failure(_ status: Int, _ body: Data = Data()) async -> SpeechError? {
        StubProtocol.respond = { _ in (status, body, nil) }
        do {
            _ = try await synthesizer().speak("a")
            return nil
        } catch {
            return error as? SpeechError
        }
    }

    func testEmptyAudioNamesTheMissingPackage() async {
        let error = await failure(200)
        XCTAssertEqual(error, .noAudio)
        XCTAssertTrue(error?.localizedDescription.contains("misaki") == true)
    }

    func testServerErrorNamesTheStatus() async {
        let error = await failure(500, Data(#"{"detail":"model crashed"}"#.utf8))
        XCTAssertEqual(error, .http(status: 500, detail: "model crashed"))
        let missing = await failure(404)
        XCTAssertTrue(missing?.localizedDescription.contains("/audio/speech") == true)
    }

    func testConnectionRefusedNamesTheHost() async {
        StubProtocol.respond = { _ in (0, Data(), URLError(.cannotConnectToHost)) }
        do {
            _ = try await synthesizer(baseURL: "http://localhost:9/v1").speak("a")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("localhost:9"), error.localizedDescription)
        }
    }

    func testInvalidBaseURL() async {
        do {
            _ = try await synthesizer(baseURL: "ftp://x").speak("a")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SpeechError, .invalidURL("ftp://x"))
        }
    }

    func testVoicesAreListedForTheModel() async throws {
        StubProtocol.respond = { _ in (200, Data(#"{"object":"list","data":[{"id":"af_heart"},{"id":"am_puck"}]}"#.utf8), nil) }
        let voices = await synthesizer().voices()
        XCTAssertEqual(voices, ["af_heart", "am_puck"])
        XCTAssertEqual(StubProtocol.requests[0].url?.absoluteString, "http://stub.test/v1/audio/voices?model=some/tts")
    }

    func testKokoroVoiceNamesAreReadable() {
        XCTAssertEqual(Synthesizer.label(for: "am_puck"), "Puck (American, male)")
        XCTAssertEqual(Synthesizer.label(for: "bf_emma"), "Emma (British, female)")
        XCTAssertEqual(Synthesizer.label(for: "nova"), "nova")
        XCTAssertEqual(Synthesizer.label(for: "xx_name"), "xx_name")
        XCTAssertEqual(Synthesizer.label(for: "am_"), "am_")
    }

    func testNoVoicesEndpointGivesAnEmptyList() async {
        StubProtocol.respond = { _ in (404, Data(), nil) }
        let voices = await synthesizer().voices()
        XCTAssertEqual(voices, [])
    }
}
