import CryptoKit
import XCTest
@testable import IronPet

/// A unit vector in 256 dimensions whose cosine with `unit(0)` is `cosine`, and 0 with the other axes.
private func vector(cosine: Float, axis: Int = 1) -> [Float] {
    var v = [Float](repeating: 0, count: 256)
    v[0] = cosine
    v[axis] = (1 - cosine * cosine).squareRoot()
    return v
}

private func unit(_ axis: Int) -> [Float] {
    var v = [Float](repeating: 0, count: 256)
    v[axis] = 1
    return v
}

final class SpeakerMatcherTests: XCTestCase {
    private let marko = VoiceCandidate(id: "m", name: "Marko", centroid: unit(0))
    private let ana = VoiceCandidate(id: "a", name: "Ana", centroid: unit(5))

    func testHighScoreWithNobodyElseCloseIsLabelled() {
        // 0.8 to Marko, about 0.3 to Ana.
        var embedding = vector(cosine: 0.8, axis: 5)
        embedding = SpeakerMatcher.normalized(embedding.enumerated().map { $0.offset == 5 ? 0.3 : $0.element })
        let score = SpeakerMatcher.cosine(embedding, marko.centroid)
        XCTAssertGreaterThan(score, 0.7)
        guard case .known(_, let name, _) = SpeakerMatcher.match(embedding, against: [marko, ana]) else { return XCTFail("not labelled") }
        XCTAssertEqual(name, "Marko")
    }

    func testMiddleScoreIsASuggestion() {
        guard case .suggestion(_, let name, _) = SpeakerMatcher.match(vector(cosine: 0.6), against: [marko, ana]) else { return XCTFail() }
        XCTAssertEqual(name, "Marko")
    }

    func testLowScoreIsUnknown() {
        XCTAssertEqual(SpeakerMatcher.match(vector(cosine: 0.4), against: [marko, ana]), .unknown)
    }

    func testTwoCloseCandidatesAreOnlyASuggestion() {
        let a = VoiceCandidate(id: "a", name: "A", centroid: vector(cosine: 0.75, axis: 7))
        let b = VoiceCandidate(id: "b", name: "B", centroid: vector(cosine: 0.72, axis: 8))
        // The embedding is unit(0): cosine 0.75 to A and 0.72 to B, a margin of 0.03.
        guard case .suggestion = SpeakerMatcher.match(unit(0), against: [a, b]) else { return XCTFail("margin rule") }
    }

    func testNoVoicesMeansUnknown() {
        XCTAssertEqual(SpeakerMatcher.match(unit(0), against: []), .unknown)
    }

    func testMergeWeightsBySecondsAndCaps() {
        let merged = SpeakerMatcher.merge(unit(0), oldSeconds: 10_000, unit(1), newSeconds: 600)
        // Both weights are capped at 600, so the result is halfway between them.
        XCTAssertEqual(merged[0], merged[1], accuracy: 1e-5)
        XCTAssertEqual(SpeakerMatcher.cosine(merged, merged), 1, accuracy: 1e-5)
    }
}

final class VoiceStoreTests: XCTestCase {
    private var dir: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-voices-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func store(modelId: String = "m1") -> VoiceStore {
        VoiceStore(url: dir.appendingPathComponent("voices.enc"), key: { [key] in key }, modelId: modelId)
    }

    func testEnrollsAndReadsBack() throws {
        let s = store()
        XCTAssertNotNil(s.enroll(name: "Marko", embedding: unit(0), seconds: 30))
        XCTAssertEqual(store().voices().map(\.name), ["Marko"])
        XCTAssertEqual(store().voices().first?.confirmedMeetings, 1)
    }

    func testFileIsEncrypted() throws {
        let s = store()
        s.enroll(name: "Marko", embedding: unit(0), seconds: 30)
        let raw = try Data(contentsOf: dir.appendingPathComponent("voices.enc"))
        XCTAssertNil(raw.range(of: Data("Marko".utf8)))
        // Another key cannot read it.
        let other = VoiceStore(url: dir.appendingPathComponent("voices.enc"), key: { SymmetricKey(size: .bits256) }, modelId: "m1")
        XCTAssertTrue(other.voices().isEmpty)
    }

    func testClustersUnderTenSecondsDoNotUpdateTheStore() {
        let s = store()
        XCTAssertNil(s.enroll(name: "Marko", embedding: unit(0), seconds: 9.9))
        XCTAssertTrue(s.voices().isEmpty)
        s.enroll(name: "Marko", embedding: unit(0), seconds: 20)
        let before = s.voices()[0]
        XCTAssertNil(s.enroll(name: "Marko", embedding: unit(1), seconds: 5))
        XCTAssertEqual(s.voices()[0], before)
    }

    func testSameNameUpdatesTheCentroid() {
        let s = store()
        s.enroll(name: "Marko", embedding: unit(0), seconds: 20)
        s.enroll(name: "marko", embedding: unit(1), seconds: 20)
        let voices = s.voices()
        XCTAssertEqual(voices.count, 1)
        XCTAssertEqual(voices[0].seconds, 40)
        XCTAssertEqual(voices[0].confirmedMeetings, 2)
        XCTAssertEqual(voices[0].centroid[0], voices[0].centroid[1], accuracy: 1e-5)
    }

    func testForgetOneVoiceRemovesItFromTheFile() {
        let s = store()
        s.enroll(name: "Marko", embedding: unit(0), seconds: 20)
        s.enroll(name: "Ana", embedding: unit(1), seconds: 20)
        let id = s.voices().first { $0.name == "Marko" }!.id
        s.forget(id: id)
        XCTAssertEqual(store().voices().map(\.name), ["Ana"])
    }

    func testForgetAllDeletesTheFile() {
        let s = store()
        s.enroll(name: "Marko", embedding: unit(0), seconds: 20)
        s.forgetAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("voices.enc").path))
        XCTAssertTrue(store().voices().isEmpty)
    }

    func testForgettingTheLastVoiceDeletesTheFile() {
        let s = store()
        s.enroll(name: "Marko", embedding: unit(0), seconds: 20)
        s.forget(id: s.voices()[0].id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("voices.enc").path))
    }

    func testAChangedModelIdInvalidatesTheCentroids() {
        store(modelId: "m1").enroll(name: "Marko", embedding: unit(0), seconds: 20)
        XCTAssertTrue(store(modelId: "m2").voices().isEmpty)
    }
}

final class SpeakerLinesTests: XCTestCase {
    private let turns = [SpeakerTurn(speakerId: 1, start: 0, end: 5), SpeakerTurn(speakerId: 2, start: 5, end: 10)]

    private func line(_ start: Double, _ end: Double) -> MeetingLine {
        MeetingTranscript.lines(from: [TimedSegment(start: start, end: end, text: "hi")], track: .them, offset: 100, turns: turns)[0]
    }

    func testEachSegmentGetsTheSpeakerWithMostOverlap() {
        XCTAssertEqual(line(0, 4).speakerId, 1)
        XCTAssertEqual(line(6, 9).speakerId, 2)
        XCTAssertEqual(line(2.5, 7.5).speakerId, 1, "2.5 s each ties to the lower id")
        XCTAssertEqual(line(4, 7.5).speakerId, 2, "2.5 of 3.5 s")
    }

    func testLessThanHalfOverlapStaysThem() {
        // 2 s of speaker 1, 5 s of speaker 2 and 4 s of nobody: the best has 5 of 11 s.
        XCTAssertNil(line(3, 14).speakerId)
        XCTAssertNil(line(20, 25).speakerId)
        XCTAssertNil(line(20, 25).speaker)
    }

    func testMeTrackNeverGetsASpeaker() {
        let lines = MeetingTranscript.lines(from: [TimedSegment(start: 0, end: 4, text: "hi")], track: .me, offset: 0, turns: turns)
        XCTAssertNil(lines[0].speakerId)
    }

    func testRenderUsesTheNameThenSpeakerNThenTheTrack() {
        let start = Date(timeIntervalSince1970: 0)
        let tz = TimeZone(identifier: "UTC")!
        let lines = [
            MeetingLine(track: .them, start: 0, text: "a", speakerId: 1, speaker: "Marko"),
            MeetingLine(track: .them, start: 1, text: "b", speakerId: 2, speaker: "Speaker 2"),
            MeetingLine(track: .them, start: 2, text: "c"),
            MeetingLine(track: .me, start: 3, text: "d"),
        ]
        let text = MeetingTranscript.render(startedAt: start, appName: "x", lines: lines, timeZone: tz)
        XCTAssertTrue(text.contains("] Marko: a"))
        XCTAssertTrue(text.contains("] Speaker 2: b"))
        XCTAssertTrue(text.contains("] Them: c"))
        XCTAssertTrue(text.contains("] Me: d"))
    }

    func testGroupWeightsEmbeddingsByDuration() {
        let result = FluidDiarizer.group([
            (speaker: "S1", start: 0, end: 3, embedding: unit(0)),
            (speaker: "S2", start: 3, end: 4, embedding: unit(1)),
            (speaker: "S1", start: 4, end: 5, embedding: unit(1)),
        ])
        XCTAssertEqual(result.speakers.map(\.localId), ["S1", "S2"])
        XCTAssertEqual(result.speakers[0].seconds, 4)
        XCTAssertGreaterThan(result.speakers[0].embedding[0], result.speakers[0].embedding[1])
    }
}

final class MeetingSpeakerTableTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/them-001.wav")

    private func chunk(_ speakers: [(String, [Float], Double)]) -> ChunkDiarization {
        ChunkDiarization(speakers: speakers.map { ChunkSpeaker(localId: $0.0, embedding: $0.1, turns: [0...$0.2]) })
    }

    func testTheSameVoiceInTwoChunksIsOneSpeaker() {
        var table = MeetingSpeakerTable()
        let first = table.link(chunk([("0", unit(0), 10), ("1", unit(1), 5)]), chunkURL: url, store: [])
        let second = table.link(chunk([("1", vector(cosine: 0.95), 8), ("0", unit(1), 4)]), chunkURL: url, store: [])
        XCTAssertEqual(table.speakers.count, 2)
        XCTAssertEqual(first["0"], second["1"])
        XCTAssertEqual(first["1"], second["0"])
        XCTAssertEqual(table.speaker(first["0"]!)?.seconds, 18)
    }

    func testStoredVoiceNamesASpeaker() {
        var table = MeetingSpeakerTable()
        let ids = table.link(chunk([("0", unit(0), 10)]), chunkURL: url,
                             store: [VoiceCandidate(id: "p", name: "Marko", centroid: vector(cosine: 0.9))])
        XCTAssertEqual(table.speaker(ids["0"]!)?.name, "Marko")
    }

    func testSuggestionKeepsTheSpeakerUnnamed() {
        var table = MeetingSpeakerTable()
        let ids = table.link(chunk([("0", unit(0), 10)]), chunkURL: url,
                             store: [VoiceCandidate(id: "p", name: "Marko", centroid: vector(cosine: 0.6))])
        let speaker = table.speaker(ids["0"]!)!
        XCTAssertNil(speaker.name)
        XCTAssertEqual(speaker.suggestion, "Marko")
        XCTAssertEqual(speaker.displayName, "Speaker 1")
    }

    func testUnknownVoicesAreNumbered() {
        var table = MeetingSpeakerTable()
        _ = table.link(chunk([("0", unit(0), 10), ("1", unit(1), 5)]), chunkURL: url, store: [])
        XCTAssertEqual(table.speakers.map(\.displayName), ["Speaker 1", "Speaker 2"])
    }

    func testRelinkNamesEarlyChunksAndMergesDuplicates() {
        var table = MeetingSpeakerTable()
        // Two near-identical voices that stayed apart (cosine 0.6 between chunks), then the store learns who both are.
        _ = table.link(chunk([("0", unit(0), 10)]), chunkURL: url, store: [])
        _ = table.link(chunk([("0", vector(cosine: 0.6), 10)]), chunkURL: url, store: [])
        XCTAssertEqual(table.speakers.count, 2)
        // A stored centroid between the two, so both score above 0.7 against it.
        var between = [Float](repeating: 0, count: 256)
        between[0] = 1
        between[1] = 0.45
        let remap = table.relink(store: [VoiceCandidate(id: "p", name: "Marko", centroid: SpeakerMatcher.normalized(between))])
        XCTAssertEqual(table.speakers.count, 1)
        XCTAssertEqual(table.speakers[0].name, "Marko")
        XCTAssertEqual(remap, [2: 1])
    }

    func testDifferentlyNamedVoicesAreNeverMerged() {
        var table = MeetingSpeakerTable()
        _ = table.link(chunk([("0", unit(0), 10)]), chunkURL: url, store: [])
        _ = table.link(chunk([("0", vector(cosine: 0.6), 10)]), chunkURL: url, store: [])
        table.setName(1, "Marko")
        table.setName(2, "Ana")
        XCTAssertTrue(table.relink(store: []).isEmpty)
        XCTAssertEqual(table.speakers.count, 2)
    }
}

@MainActor
final class SpeakerModelsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "ironpet-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testFirstToggleDownloadsOnceAndReportsProgress() async {
        var calls = 0
        var present = false
        let models = SpeakerModels(defaults: defaults(), cachePresent: { present }, download: { progress in
            calls += 1
            progress(0.5)
            try await Task.sleep(for: .milliseconds(50))
            present = true
        })
        XCTAssertEqual(models.state, .notDownloaded)
        XCTAssertFalse(models.isReady)
        models.prepare()
        models.prepare()
        if case .downloading = models.state {} else { XCTFail("expected downloading, got \(models.state)") }
        await models.waitUntilSettled()
        XCTAssertEqual(models.state, .ready)
        XCTAssertTrue(models.isReady)
        models.prepare()
        await models.waitUntilSettled()
        XCTAssertEqual(calls, 1, "a second toggle must not download again")
    }

    func testReadyStateSurvivesARestartWhileTheFilesExist() async {
        let d = defaults()
        let first = SpeakerModels(defaults: d, cachePresent: { true }, download: { _ in })
        first.prepare()
        await first.waitUntilSettled()
        XCTAssertEqual(SpeakerModels(defaults: d, cachePresent: { true }, download: { _ in }).state, .ready)
        XCTAssertEqual(SpeakerModels(defaults: d, cachePresent: { false }, download: { _ in }).state, .notDownloaded)
    }

    func testAFailedDownloadCanBeRetried() async {
        var fail = true
        let models = SpeakerModels(defaults: defaults(), cachePresent: { true }, download: { _ in
            if fail { throw URLError(.notConnectedToInternet) }
        })
        models.prepare()
        await models.waitUntilSettled()
        if case .failed = models.state {} else { XCTFail("expected failed") }
        XCTAssertFalse(models.isReady)
        fail = false
        models.prepare()
        await models.waitUntilSettled()
        XCTAssertEqual(models.state, .ready)
    }

    func testSpeakerRecognitionIsOffByDefault() {
        XCTAssertFalse(Config().meetings.recogniseSpeakers)
    }
}
