import CryptoKit
import XCTest
@testable import IronPet

private final class SegmentsStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"text":"hello there general kenobi","segments":[{"start":0,"end":2,"text":"hello there"},{"start":2,"end":4,"text":"general kenobi"}]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class FakeDiarizer: SpeakerDiarizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var fail = false

    private static func unit(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        v[axis] = 1
        return v
    }

    func diarize(wav: URL) async throws -> ChunkDiarization {
        let call = count()
        if fail { throw URLError(.cannotLoadFromNetwork) }
        // Speaker "b" talks for 12 s from second 2 on in every chunk. Speaker "a" talks for 1.2 s in the first chunk
        // only: a voice's seconds add up over chunks, and a slow machine cuts the recording into more of them, so a
        // per-chunk "a" could cross the 3 s naming threshold. The longer talker is linked first, so "b" becomes
        // Speaker 1 and "a" becomes Speaker 2.
        var speakers = [ChunkSpeaker(localId: "b", embedding: Self.unit(1), turns: [2...14])]
        if call == 1 { speakers.insert(ChunkSpeaker(localId: "a", embedding: Self.unit(0), turns: [0...1.2]), at: 0) }
        return ChunkDiarization(speakers: speakers)
    }

    private func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        _calls += 1
        return _calls
    }
}

@MainActor
final class SpeakerPipelineTests: XCTestCase {
    private var dir: URL!
    private var store: VoiceStore!
    private let key = SymmetricKey(size: .bits256)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = VoiceStore(url: dir.appendingPathComponent("voices.enc"), key: { [key] in key }, modelId: "test")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func tone(_ name: String) throws -> URL {
        let samples = (0..<(4 * WAV.sampleRate)).map { Int16($0 / 20 % 2 == 0 ? 8000 : -8000) }
        let url = dir.appendingPathComponent(name)
        try WAV.encode(samples).write(to: url)
        return url
    }

    /// Records 4 s of two tone files through the real pipeline with a stubbed transcription server.
    private func meeting(recognise: Bool, ready: Bool, diarizer: FakeDiarizer) async throws -> MeetingController {
        let controller = MeetingController()
        controller.isEnabled = { true }
        controller.meetingConfig = { var m = Config.Meetings(); m.autoSummary = false; return m }
        controller.meetingsRoot = dir.appendingPathComponent("meetings")
        controller.recogniseSpeakers = { recognise }
        controller.speakerModelsReady = { ready }
        controller.diarizer = diarizer
        controller.voiceStore = store
        controller.makeTranscriber = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SegmentsStub.self]
            return Transcriber(baseURL: "http://stub.test/v1", model: "m", apiKey: nil, session: URLSession(configuration: configuration))
        }
        try controller.startTest(mic: try tone("mic.wav"), them: try tone("them.wav"), appName: "Test", lengths: .test(2))
        try await waitFor { controller.phase == .recording }
        try await Task.sleep(for: .seconds(4.5))
        controller.stop()
        try await waitFor(seconds: 30) { controller.phase == .done }
        return controller
    }

    private func waitFor(seconds: Double = 10, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testFeatureOffNeverCallsTheDiarizerAndKeepsThem() async throws {
        let diarizer = FakeDiarizer()
        let controller = try await meeting(recognise: false, ready: true, diarizer: diarizer)
        XCTAssertEqual(diarizer.calls, 0)
        XCTAssertFalse(controller.lines.isEmpty)
        XCTAssertTrue(controller.lines.allSatisfy { $0.speaker == nil && $0.speakerId == nil })
        let text = try String(contentsOf: controller.transcriptURL!, encoding: .utf8)
        XCTAssertTrue(text.contains("Them: hello there"))
        XCTAssertFalse(text.contains("Speaker"))
    }

    func testModelsNotDownloadedMeansAnOrdinaryMeeting() async throws {
        let diarizer = FakeDiarizer()
        let controller = try await meeting(recognise: true, ready: false, diarizer: diarizer)
        XCTAssertEqual(diarizer.calls, 0)
        XCTAssertEqual(controller.counts.failed, 0)
        XCTAssertNil(controller.notice)
        XCTAssertTrue(try String(contentsOf: controller.transcriptURL!, encoding: .utf8).contains("Them: hello there"))
    }

    func testADiarizerFailureLeavesTheTranscriptAsItWas() async throws {
        let diarizer = FakeDiarizer()
        diarizer.fail = true
        let controller = try await meeting(recognise: true, ready: true, diarizer: diarizer)
        XCTAssertGreaterThan(diarizer.calls, 0)
        XCTAssertEqual(controller.counts.failed, 0)
        XCTAssertNil(controller.notice)
        XCTAssertTrue(try String(contentsOf: controller.transcriptURL!, encoding: .utf8).contains("Them: hello there"))
    }

    func testNamingASpeakerRelabelsEveryLineRewritesTheTranscriptAndEnrols() async throws {
        let diarizer = FakeDiarizer()
        let controller = try await meeting(recognise: true, ready: true, diarizer: diarizer)
        let theirs = controller.lines.filter { $0.track == .them }
        XCTAssertTrue(theirs.contains { $0.speaker == "Speaker 2" && $0.text == "hello there" })
        XCTAssertTrue(theirs.contains { $0.speaker == "Speaker 1" && $0.text == "general kenobi" })
        XCTAssertTrue(controller.lines.filter { $0.track == .me }.allSatisfy { $0.speaker == nil })
        // Speaker 2 spoke 1.2 s per chunk, under the 3 s asking threshold. Speaker 1 spoke 12 s per chunk.
        XCTAssertEqual(controller.speakersToName.map(\.id), [1])
        XCTAssertTrue(store.voices().isEmpty, "nothing is stored before the user names a voice")

        controller.nameSpeaker(1, as: "Marko")
        XCTAssertTrue(controller.lines.filter { $0.speakerId == 1 }.allSatisfy { $0.speaker == "Marko" })
        let text = try String(contentsOf: controller.transcriptURL!, encoding: .utf8)
        XCTAssertTrue(text.contains("Marko: general kenobi"))
        XCTAssertTrue(text.contains("Speaker 2: hello there"))
        XCTAssertEqual(store.voices().map(\.name), ["Marko"])

        // A cluster with under 10 s of speech is named in the transcript but does not reach the store.
        controller.nameSpeaker(2, as: "Ana")
        XCTAssertEqual(store.voices().map(\.name), ["Marko"])
        XCTAssertTrue(controller.namesChangedSinceSummary)
    }

    func testNamingAVoiceOffersRegeneratingTheSummaryAndNeverRunsIt() async throws {
        let controller = try await meeting(recognise: true, ready: true, diarizer: FakeDiarizer())
        var regenerated: [URL] = []
        controller.regenerateSummaryOf = { folder in regenerated.append(folder); return true }
        XCTAssertFalse(controller.canRegenerateSummary, "nothing was named yet")

        controller.nameSpeaker(1, as: "Marko")
        XCTAssertTrue(controller.canRegenerateSummary)
        XCTAssertTrue(regenerated.isEmpty, "the offer is a button, not an automatic run")

        controller.regenerateSummary()
        try await waitFor { !controller.canRegenerateSummary }
        XCTAssertEqual(regenerated, [controller.folder])
        XCTAssertFalse(controller.namesChangedSinceSummary)
        XCTAssertFalse(controller.regeneratingSummary)
    }

    func testTheOfferSurvivesClosingTheBubble() async throws {
        let controller = try await meeting(recognise: true, ready: true, diarizer: FakeDiarizer())
        controller.regenerateSummaryOf = { _ in true }
        controller.dismiss()
        controller.nameSpeaker(1, as: "Marko")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.canRegenerateSummary, "Settings is where the voices are named after the bubble is closed")
    }

    func testAFailedSummaryRegenerationKeepsTheOffer() async throws {
        let controller = try await meeting(recognise: true, ready: true, diarizer: FakeDiarizer())
        controller.regenerateSummaryOf = { _ in false }
        controller.nameSpeaker(1, as: "Marko")
        controller.regenerateSummary()
        try await waitFor { !controller.regeneratingSummary }
        XCTAssertTrue(controller.canRegenerateSummary)
    }

    func testClosingTheBubbleKeepsUnnamedVoicesForSettingsUntilTheNextMeeting() async throws {
        let controller = try await meeting(recognise: true, ready: true, diarizer: FakeDiarizer())
        XCTAssertTrue(controller.hasSpeakersToName)
        controller.dismiss()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.hasSpeakersToName, "Settings still lists the voices")
        controller.nameSpeaker(1, as: "Marko")
        XCTAssertTrue(try String(contentsOf: controller.transcriptURL!, encoding: .utf8).contains("Marko: general kenobi"))
        controller.showPicker()
        XCTAssertFalse(controller.hasSpeakersToName, "a new meeting starts clean")
    }

    func testAStoredVoiceIsNamedInTheNextMeetingAndForgettingItBringsSpeakerNBack() async throws {
        let first = try await meeting(recognise: true, ready: true, diarizer: FakeDiarizer())
        first.nameSpeaker(1, as: "Marko")
        let second = try await meeting(recognise: true, ready: true, diarizer: FakeDiarizer())
        XCTAssertTrue(try String(contentsOf: second.transcriptURL!, encoding: .utf8).contains("Marko: general kenobi"))

        store.forgetAll()
        let third = try await meeting(recognise: true, ready: true, diarizer: FakeDiarizer())
        let text = try String(contentsOf: third.transcriptURL!, encoding: .utf8)
        XCTAssertTrue(text.contains("Speaker 1: general kenobi"))
        XCTAssertFalse(text.contains("Marko"))
    }
}
