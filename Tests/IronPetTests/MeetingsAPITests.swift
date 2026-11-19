import XCTest
@testable import IronPet

/// Drives meetings and transcripts only through `IronPetAPI`. The library and the controller are passed to the helper only to
/// give them a temporary folder and a stub summary agent.
@MainActor
final class MeetingsAPITests: XCTestCase {
    private var events: APIEventBus!
    private var seen: [APIEvent] = []
    private var root: URL!
    private var library: MeetingLibrary!
    private var controller: MeetingController!
    private var api: IronPetAPI!

    override func setUp() async throws {
        events = APIEventBus()
        seen = []
        events.subscribe { [unowned self] in seen.append($0) }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-meetings-api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeMeeting("2026-11-14-1400", summary: "## Summary\nPlanned the launch.\n", transcript: "# Meeting\n[14:00:00] Me: hello\n")
        try makeMeeting("2026-11-15-1000", summary: nil, transcript: "# Meeting\n[10:00:00] Me: second\n")
        library = MeetingLibrary(root: root)
        library.regenerator.summarize = { _, _, _ in "## Summary\nRebuilt.\n" }
        controller = MeetingController()
        api = APITestSupport.makeAPI(events: events, meeting: controller, meetingLibrary: library)
        api.meetings.reload()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func makeMeeting(_ name: String, summary: String?, transcript: String?) throws {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let summary { try summary.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8) }
        if let transcript { try transcript.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8) }
    }

    func testListShowsMeetingsNewestFirstWithWhatEachHas() throws {
        let list = api.meetings.list()
        XCTAssertEqual(list.map(\.id), ["2026-11-15-1000", "2026-11-14-1400"])
        XCTAssertEqual(list[1].preview, "Planned the launch.")
        XCTAssertTrue(list[1].hasSummary)
        XCTAssertFalse(list[0].hasSummary)
        XCTAssertFalse(list[0].hasAudio)
        XCTAssertThrowsError(try api.meetings.get("nope")) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
    }

    func testSummaryAndTranscriptText() async throws {
        let summary = try await api.meetings.text(MeetingTextRequest(id: "2026-11-14-1400", kind: .summary))
        XCTAssertEqual(summary, "## Summary\nPlanned the launch.\n")
        let transcript = try await api.meetings.text(MeetingTextRequest(id: "2026-11-14-1400", kind: .transcript))
        XCTAssertTrue(try XCTUnwrap(transcript).contains("Me: hello"))
        let none = try await api.meetings.text(MeetingTextRequest(id: "2026-11-15-1000", kind: .summary))
        XCTAssertNil(none)
        do { _ = try await api.meetings.text(MeetingTextRequest(id: "nope", kind: .summary)); XCTFail("read a missing meeting") } catch {
            XCTAssertEqual((error as? APIError)?.code, .notFound)
        }
    }

    func testRegenerateSummaryOnlyKeepsTheTranscriptAndKeepsTheOldSummary() async throws {
        try await api.meetings.regenerate(RegenerateMeetingRequest(id: "2026-11-14-1400", mode: .summaryOnly))
        let summary = try await api.meetings.text(MeetingTextRequest(id: "2026-11-14-1400", kind: .summary))
        XCTAssertEqual(summary, "## Summary\nRebuilt.\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-11-14-1400/summary.prev.md").path))
    }

    func testRegenerateIsBlockedWithoutAudioForAFullRebuild() async {
        XCTAssertNotNil(api.meetings.regenerationBlocked("2026-11-14-1400", mode: .full))
        XCTAssertNil(api.meetings.regenerationBlocked("2026-11-14-1400", mode: .summaryOnly))
        do { try await api.meetings.regenerate(RegenerateMeetingRequest(id: "2026-11-14-1400", mode: .full)); XCTFail("rebuilt without audio") } catch {
            XCTAssertEqual((error as? APIError)?.code, .failed)
        }
    }

    func testAskHandsTheFilesToTheChat() throws {
        var files: [URL] = []
        XCTAssertThrowsError(try api.meetings.ask("2026-11-14-1400")) { XCTAssertEqual(($0 as? APIError)?.code, .unavailable) }
        api.meetings.askHandler = { files = $0 }
        try api.meetings.ask("2026-11-14-1400")
        XCTAssertEqual(files.map(\.lastPathComponent).sorted(), ["summary.md", "transcript.md"])
        XCTAssertThrowsError(try api.meetings.ask("nope")) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
    }

    func testDeleteMovesTheFolderToTheTrash() throws {
        try api.meetings.delete("2026-11-15-1000")
        XCTAssertEqual(api.meetings.list().map(\.id), ["2026-11-14-1400"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-11-15-1000").path))
        XCTAssertThrowsError(try api.meetings.delete("2026-11-15-1000")) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
    }

    func testStopRecordingWithNothingRecordingIsAConflict() {
        XCTAssertEqual(api.meetings.status.phase, "idle")
        XCTAssertThrowsError(try api.meetings.stopRecording()) { XCTAssertEqual(($0 as? APIError)?.code, .conflict) }
    }

    func testNamingASpeakerThatDoesNotExistIsNotFound() {
        XCTAssertThrowsError(try api.meetings.nameSpeaker(NameSpeakerRequest(speaker: 9, name: "Ana"))) {
            XCTAssertEqual(($0 as? APIError)?.code, .notFound)
        }
        XCTAssertThrowsError(try api.meetings.dismissSpeaker(DismissSpeakerRequest(speaker: 9))) {
            XCTAssertEqual(($0 as? APIError)?.code, .notFound)
        }
    }

    func testMeetingChangesArriveOnTheBus() {
        controller.isEnabled = { true }
        controller.meetingConfig = { Config.Meetings() }
        controller.runningApps = { [] }
        controller.showPicker()
        XCTAssertEqual(api.meetings.status.phase, "choosing")
        XCTAssertTrue(seen.contains { $0.kind == .meetingsChanged })
    }

    func testTypesRoundTripAsJSON() throws {
        let info = try XCTUnwrap(api.meetings.list().first)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(MeetingInfo.self, from: encoder.encode(info)).id, info.id)
        let request = RegenerateMeetingRequest(id: "x", mode: .summaryOnly)
        XCTAssertEqual(try decoder.decode(RegenerateMeetingRequest.self, from: encoder.encode(request)), request)
    }
}
