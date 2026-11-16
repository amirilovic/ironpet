import CryptoKit
import XCTest
@testable import IronPet

/// A transcription server that answers every request with one numbered segment, and can fail on one of them.
private final class NumberedStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests = 0
    nonisolated(unsafe) private static var _failOn: Int?

    static var requests: Int { lock.lock(); defer { lock.unlock() }; return _requests }
    static func reset(failOn: Int? = nil) { lock.lock(); _requests = 0; _failOn = failOn; lock.unlock() }

    private static func next() -> (number: Int, fail: Bool) {
        lock.lock(); defer { lock.unlock() }
        _requests += 1
        return (_requests, _requests == _failOn)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (number, fail) = Self.next()
        let status = fail ? 500 : 200
        let body = fail ? #"{"error":"boom"}"# : #"{"text":"new words \#(number)","segments":[{"start":0,"end":1,"text":"new words \#(number)"}]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Gives the them track one voice, the unit vector on axis 1, for 2 s of every chunk.
private struct OneVoice: SpeakerDiarizing {
    func diarize(wav: URL) async throws -> ChunkDiarization {
        var embedding = [Float](repeating: 0, count: 256)
        embedding[1] = 1
        return ChunkDiarization(speakers: [ChunkSpeaker(localId: "a", embedding: embedding, turns: [0...2])])
    }
}

@MainActor
final class MeetingRegenerationTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var regenerator: MeetingRegenerator!
    private var summaryInputs: [String] = []

    private let oldTranscript = "# Meeting 2026-11-14 14:00 (Zoom)\n[14:00:00] Me: old words\n"
    private let oldSummary = "## Summary\nOld.\n\n## Action items\n- [x] Send the deck. (owner: Me)\n- [ ] Call Sam (owner: Me)\n"
    private let newSummary = "## Summary\nNew.\n\n## Action items\n- [ ] send the DECK (owner: Me)\n- [ ] Book the room (owner: Me)\n"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-regen-\(UUID().uuidString)")
        folder = root.appendingPathComponent("2026-11-14-1400")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Synthetic audio only: a square wave per chunk, two chunks on each track.
        for name in ["mic-001", "mic-002", "them-001", "them-002"] {
            let samples = (0..<(3 * WAV.sampleRate)).map { Int16($0 / 20 % 2 == 0 ? 8000 : -8000) }
            try WAV.encode(samples).write(to: folder.appendingPathComponent("\(name).wav"))
        }
        try oldTranscript.write(to: file("transcript.md"), atomically: true, encoding: .utf8)
        try oldSummary.write(to: file("summary.md"), atomically: true, encoding: .utf8)

        NumberedStub.reset()
        summaryInputs = []
        regenerator = MeetingRegenerator()
        regenerator.makeTranscriber = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NumberedStub.self]
            return Transcriber(baseURL: "http://stub.test/v1", model: "m", apiKey: nil, session: URLSession(configuration: configuration))
        }
        regenerator.recogniseSpeakers = { false }
        regenerator.speakerModelsReady = { true }
        regenerator.meetingConfig = { Config.Meetings() }
        regenerator.summarize = { [unowned self] transcript, _, _ in
            summaryInputs.append(transcript)
            return newSummary
        }
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
    private func read(_ name: String) -> String? { try? String(contentsOf: file(name), encoding: .utf8) }
    private func record() throws -> MeetingRecord { try XCTUnwrap(MeetingLibrary.record(folder)) }

    // MARK: S1

    func testFullRegenerationReplacesBothFilesAndKeepsTheOldOnes() async throws {
        let replaced = expectation(description: "replaced")
        var seen: MeetingReplacement?
        regenerator.onReplaced = { seen = $0; replaced.fulfill() }

        let ok = await regenerator.regenerate(try record(), mode: .full)
        XCTAssertTrue(ok, regenerator.errors.values.joined())
        await fulfillment(of: [replaced], timeout: 1)

        let transcript = try XCTUnwrap(read("transcript.md"))
        XCTAssertTrue(transcript.hasPrefix("# Meeting 2026-11-14 14:00 (Zoom)\n"), "the header keeps the app")
        XCTAssertEqual(NumberedStub.requests, 4, "every chunk of both tracks is sent")
        for line in ["Me: new words 1", "Them: new words 2", "Me: new words 3", "Them: new words 4"] {
            XCTAssertTrue(transcript.contains(line), line)
        }
        XCTAssertFalse(transcript.contains("old words"))
        XCTAssertTrue(transcript.contains("[14:00:03] Me: new words 3"), "the second chunk starts after the first one's 3 s")
        XCTAssertEqual(summaryInputs, [transcript], "the summary reads the new transcript")
        XCTAssertTrue(try XCTUnwrap(read("summary.md")).contains("New."))
        XCTAssertEqual(read("transcript.prev.md"), oldTranscript)
        XCTAssertEqual(read("summary.prev.md"), oldSummary)
        XCTAssertNil(read("transcript.new.md"))
        XCTAssertNil(read("summary.new.md"))
        XCTAssertEqual(seen?.previousSummary, oldSummary)
        XCTAssertNil(regenerator.activeID)
    }

    func testASecondRegenerationKeepsOnlyOneGenerationOfPreviousFiles() async throws {
        await regenerator.regenerate(try record(), mode: .full)
        let firstTranscript = try XCTUnwrap(read("transcript.md"))
        // The stub keeps counting, so the second run's text differs from the first one's.
        await regenerator.regenerate(try record(), mode: .full)
        XCTAssertEqual(read("transcript.prev.md"), firstTranscript)
        XCTAssertNotEqual(read("transcript.md"), firstTranscript)
        XCTAssertTrue(try XCTUnwrap(read("transcript.md")).contains("new words 5"))
    }

    func testProgressNamesTheChunkAndThenTheSummary() async throws {
        var labels: [String] = []
        regenerator.summarize = { [unowned self] _, _, _ in
            labels.append(regenerator.progress?.label ?? "")
            return newSummary
        }
        await regenerator.regenerate(try record(), mode: .full)
        XCTAssertEqual(labels, ["Summarising"])
        XCTAssertEqual(RegenerationProgress(stage: .transcribing(chunk: 2, of: 4)).label, "Transcribing chunk 2 of 4")
        XCTAssertNil(regenerator.progress, "cleared when the run ends")
    }

    func testSpeakerLabellingUsesTheVoiceStoreWhenOn() async throws {
        let key = SymmetricKey(size: .bits256)
        let store = VoiceStore(url: root.appendingPathComponent("voices.enc"), key: { key }, modelId: "test")
        var voice = [Float](repeating: 0, count: 256)
        voice[1] = 1
        store.enroll(name: "Marko", embedding: voice, seconds: 60)
        regenerator.voiceStore = store
        regenerator.diarizer = OneVoice()
        regenerator.recogniseSpeakers = { true }

        await regenerator.regenerate(try record(), mode: .full)
        let transcript = try XCTUnwrap(read("transcript.md"))
        XCTAssertTrue(transcript.contains("Marko: new words 2"), transcript)
        XCTAssertTrue(transcript.contains("Me: new words 1"), "the microphone stays Me")
    }

    // MARK: S2

    func testAFailingChunkLeavesEverythingAsItWas() async throws {
        NumberedStub.reset(failOn: 2)
        let ok = await regenerator.regenerate(try record(), mode: .full)
        XCTAssertFalse(ok)
        XCTAssertEqual(read("transcript.md"), oldTranscript)
        XCTAssertEqual(read("summary.md"), oldSummary)
        XCTAssertNil(read("transcript.prev.md"))
        XCTAssertNil(read("summary.prev.md"))
        XCTAssertTrue(summaryInputs.isEmpty, "no summary is run for a transcript that was thrown away")
        let message = try XCTUnwrap(regenerator.errors[try record().id])
        XCTAssertTrue(message.contains("them-001.wav"), message)
        XCTAssertNil(regenerator.activeID)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".new.md") }, [])
    }

    func testAFailingSummaryLeavesTheTranscriptAsItWas() async throws {
        regenerator.summarize = { _, _, _ in throw RegenerationError(message: "agent offline") }
        let ok = await regenerator.regenerate(try record(), mode: .full)
        XCTAssertFalse(ok)
        XCTAssertEqual(read("transcript.md"), oldTranscript)
        XCTAssertEqual(read("summary.md"), oldSummary)
        XCTAssertEqual(regenerator.errors[try record().id], "agent offline")
    }

    func testAnEmptyAnswerReplacesNothing() async throws {
        regenerator.summarize = { _, _, _ in "  \n" }
        let result1 = await regenerator.regenerate(try record(), mode: .full)
        XCTAssertFalse(result1)
        XCTAssertEqual(read("summary.md"), oldSummary)
        XCTAssertEqual(read("transcript.md"), oldTranscript)
    }

    func testReplaceRestoresTheFirstFileWhenTheSecondSwapFails() throws {
        // Moves 1 and 2 swap transcript.md, move 3 starts on summary.md and fails.
        var moves = 0
        let flaky: (URL, URL) throws -> Void = { from, to in
            moves += 1
            if moves == 4 { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: from, to: to)
        }
        XCTAssertThrowsError(try MeetingRegenerator.replace(in: folder, transcript: "new transcript\n", summary: "new summary\n", move: flaky))
        XCTAssertEqual(read("transcript.md"), oldTranscript)
        XCTAssertEqual(read("summary.md"), oldSummary)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".new.md") }, [])
    }

    // MARK: S3

    func testSummaryOnlyDoesNotTranscribeAndOnlyChangesTheSummary() async throws {
        let ok = await regenerator.regenerate(try record(), mode: .summaryOnly)
        XCTAssertTrue(ok)
        XCTAssertEqual(NumberedStub.requests, 0)
        XCTAssertEqual(summaryInputs, [oldTranscript], "the summary reads the transcript that is there")
        XCTAssertEqual(read("transcript.md"), oldTranscript)
        XCTAssertNil(read("transcript.prev.md"))
        XCTAssertTrue(try XCTUnwrap(read("summary.md")).contains("New."))
        XCTAssertEqual(read("summary.prev.md"), oldSummary)
    }

    func testSummaryOnlyWithoutATranscriptSaysSo() async throws {
        try FileManager.default.removeItem(at: file("transcript.md"))
        let result2 = await regenerator.regenerate(try record(), mode: .summaryOnly)
        XCTAssertFalse(result2)
        XCTAssertEqual(regenerator.errors[try record().id], "This meeting has no transcript to summarise.")
    }

    // MARK: S4

    func testATickedItemStaysTickedWhenItsTextComesBack() async throws {
        await regenerator.regenerate(try record(), mode: .summaryOnly)
        let summary = try XCTUnwrap(read("summary.md"))
        XCTAssertTrue(summary.contains("- [x] send the DECK (owner: Me)"), "same text apart from case and the full stop")
        XCTAssertTrue(summary.contains("- [ ] Book the room (owner: Me)"))
        XCTAssertFalse(summary.contains("Call Sam"))
    }

    func testCarryCheckedIgnoresOtherSectionsAndKeepsOpenItemsOpen() {
        let old = "## Decisions\n- [x] Ship it\n\n## Action items\n- [ ] Call Sam (owner: Me)\n- [X] Pay the invoice (owner: Me, due: Friday)\n"
        let new = "## Decisions\n- [ ] Ship it\n\n## Action items\n- [ ] Call Sam (owner: Me)\n* [ ] pay the invoice (owner: Them)\n"
        XCTAssertEqual(ActionItems.carryChecked(from: old, into: new),
                       "## Decisions\n- [ ] Ship it\n\n## Action items\n- [ ] Call Sam (owner: Me)\n* [x] pay the invoice (owner: Them)\n")
        XCTAssertEqual(ActionItems.carryChecked(from: "## Action items\nNone.\n", into: new), new)
    }

    func testOnlyNewItemsAreOfferedAsTasksAgain() {
        let new = "## Action items\n- [ ] Send the deck (owner: Me)\n- [ ] Book the room (owner: Me)\n- [ ] Ask Sam (owner: Sam)\n"
        let offered = ActionItems.newSuggestions(old: oldSummary, new: new)
        XCTAssertEqual(offered.map(\.title), ["Book the room", "Ask Sam"])
        XCTAssertEqual(offered.map(\.waitingOn), [nil, "Sam"])
        XCTAssertEqual(ActionItems.newSuggestions(old: nil, new: new).map(\.title), ["Send the deck", "Book the room", "Ask Sam"])
    }

    func testASuggestionThatComesBackIsNotAddedTwice() {
        let store = TaskStore(database: Database.open(path: nil, migrations: TaskStore.migrations).database)
        let meeting = folder!
        XCTAssertEqual(store.suggest([("Send the deck", nil, nil)], meeting: meeting).count, 1)
        XCTAssertEqual(store.suggest([("send the DECK.", nil, nil), ("Book the room", nil, nil)], meeting: meeting).map(\.title), ["Book the room"])
        XCTAssertEqual(store.suggestions.count, 2)
    }

    // MARK: S5

    func testTheButtonIsDisabledWithAReason() throws {
        XCTAssertNil(regenerator.unavailableReason(for: try record(), activeFolder: nil))

        XCTAssertEqual(regenerator.unavailableReason(for: try record(), activeFolder: folder),
                       "This meeting is still being recorded or summarised.")

        for name in ["mic-001.wav", "mic-002.wav", "them-001.wav", "them-002.wav"] {
            try FileManager.default.removeItem(at: file(name))
        }
        let silent = try record()
        XCTAssertFalse(silent.hasAudio)
        XCTAssertEqual(regenerator.unavailableReason(for: silent, activeFolder: nil), "This meeting has no saved audio to transcribe again.")
        XCTAssertNil(regenerator.unavailableReason(for: silent, activeFolder: nil, requiresAudio: false))
    }

    func testRegeneratingWithoutAudioDoesNothing() async throws {
        for name in ["mic-001.wav", "mic-002.wav", "them-001.wav", "them-002.wav"] {
            try FileManager.default.removeItem(at: file(name))
        }
        let result3 = await regenerator.regenerate(try record(), mode: .full)
        XCTAssertFalse(result3)
        XCTAssertEqual(read("transcript.md"), oldTranscript)
        XCTAssertEqual(NumberedStub.requests, 0)
    }

    func testOnlyOneRegenerationRunsAtATime() async throws {
        let other = root.appendingPathComponent("2026-11-13-0900")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try WAV.encode([Int16](repeating: 8000, count: WAV.sampleRate)).write(to: other.appendingPathComponent("mic-001.wav"))
        let otherRecord = try XCTUnwrap(MeetingLibrary.record(other))

        let started = expectation(description: "summary started")
        let release = AsyncGate()
        regenerator.summarize = { [unowned self] _, _, _ in
            started.fulfill()
            await release.wait()
            return newSummary
        }
        let record = try record()
        let running = Task { await regenerator.regenerate(record, mode: .full) }
        await fulfillment(of: [started], timeout: 5)

        XCTAssertEqual(regenerator.unavailableReason(for: otherRecord, activeFolder: nil), "Another meeting is being regenerated.")
        XCTAssertEqual(regenerator.unavailableReason(for: record, activeFolder: nil), "This meeting is being regenerated.")
        let result4 = await regenerator.regenerate(otherRecord, mode: .full)
        XCTAssertFalse(result4)
        XCTAssertEqual(regenerator.progress?.stage, .summarising)

        await release.open()
        let finished = await running.value
        XCTAssertTrue(finished)
        XCTAssertNil(regenerator.unavailableReason(for: otherRecord, activeFolder: nil))
    }

    // MARK: Folder facts

    func testChunkNames() {
        XCTAssertEqual(MeetingFolderScan.chunkName("mic-001.wav")?.track, .me)
        XCTAssertEqual(MeetingFolderScan.chunkName("them-012.wav")?.index, 12)
        XCTAssertNil(MeetingFolderScan.chunkName("mic-001.wav.tmp"))
        XCTAssertNil(MeetingFolderScan.chunkName("summary.md"))
        XCTAssertNil(MeetingFolderScan.chunkName("other-001.wav"))
    }

    func testScanOrdersChunksAndAddsUpOffsetsPerTrack() throws {
        let found = try MeetingFolderScan.scan(folder)
        XCTAssertEqual(found.chunks.map { $0.url.lastPathComponent }, ["mic-001.wav", "them-001.wav", "mic-002.wav", "them-002.wav"])
        XCTAssertEqual(found.chunks.map(\.offset), [0, 0, 3, 3])
        XCTAssertEqual(found.appName, "Zoom")
        XCTAssertFalse(found.chunks.contains(where: \.silent))
    }

    func testAppNameFallsBackWhenTheHeaderIsMissing() {
        XCTAssertEqual(MeetingFolderScan.appName(fromTranscript: nil), "unknown app")
        XCTAssertEqual(MeetingFolderScan.appName(fromTranscript: "no header"), "unknown app")
        XCTAssertEqual(MeetingFolderScan.appName(fromTranscript: "# Meeting 2026-11-14 14:00 (All system audio)\n[x]"), "All system audio")
    }
}

/// Lets a test hold a fake summary open while it looks at the regenerator.
private actor AsyncGate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        opened = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
