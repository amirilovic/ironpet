import XCTest
@testable import IronPet

final class ChunkerTests: XCTestCase {
    private let rate = WAV.sampleRate

    /// `seconds` of a loud square wave, or of silence.
    private func tone(_ seconds: Double) -> [Int16] {
        (0..<Int(seconds * Double(rate))).map { $0 / 20 % 2 == 0 ? 8000 : -8000 }
    }

    private func silence(_ seconds: Double) -> [Int16] {
        [Int16](repeating: 0, count: Int(seconds * Double(rate)))
    }

    private func chunker(min: Double, max: Double) -> Chunker {
        Chunker(minSamples: Int(min * Double(rate)), maxSamples: Int(max * Double(rate)))
    }

    private func run(_ audio: [Int16], min: Double, max: Double, pushSize: Int = 1000) -> [[Int16]] {
        var chunker = chunker(min: min, max: max)
        var chunks: [[Int16]] = []
        var index = 0
        while index < audio.count {
            let end = Swift.min(index + pushSize, audio.count)
            chunks += chunker.push(Array(audio[index..<end]))
            index = end
        }
        if let rest = chunker.flush() { chunks.append(rest) }
        return chunks
    }

    func testCutsAtTheFirstSilenceAfterTheMinimum() {
        // 3 s of sound, a 1 s pause, 2 s of sound, a 1 s pause, 1 s of sound. With a 2 s minimum, the first pause
        // closes a chunk once it has lasted half a second.
        let audio = tone(3) + silence(1) + tone(2) + silence(1) + tone(1)
        let chunks = run(audio, min: 2, max: 20)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(Double(chunks[0].count) / Double(rate), 3.5, accuracy: 0.03)
        XCTAssertEqual(Double(chunks[1].count) / Double(rate), 2.5 + 0.5, accuracy: 0.03)
        XCTAssertEqual(Double(chunks[2].count) / Double(rate), 1 + 0.5, accuracy: 0.03)
    }

    func testDoesNotCutOnSilenceBeforeTheMinimum() {
        // The first pause ends at 1.7 s, inside the 2.5 s minimum, so the chunk goes on to the next pause.
        let audio = tone(1) + silence(0.7) + tone(2) + silence(1) + tone(0.5)
        let chunks = run(audio, min: 2.5, max: 20)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(Double(chunks[0].count) / Double(rate), 4.2, accuracy: 0.03)
    }

    func testCutsHardAtTheMaximumWhenNobodyPauses() {
        let chunks = run(tone(12.5), min: 2, max: 5)
        XCTAssertEqual(chunks.map { Double($0.count) / Double(rate) }, [5, 5, 2.5])
    }

    func testChunkLengthsAddUpToTheInput() {
        let audio = tone(3.3) + silence(0.9) + tone(7.1) + silence(2) + tone(1.7)
        for pushSize in [1, 777, 4096, 100_000] {
            let chunks = run(audio, min: 2, max: 5, pushSize: pushSize)
            XCTAssertEqual(chunks.reduce(0) { $0 + $1.count }, audio.count, "push size \(pushSize)")
            XCTAssertEqual(Array(chunks.joined()), audio, "samples are kept in order, push size \(pushSize)")
            XCTAssertTrue(chunks.allSatisfy { $0.count <= Int(5 * Double(rate)) })
        }
    }

    func testOffsetsOfConsecutiveChunksAreTheirRunningTotal() {
        let chunks = run(tone(2.2) + silence(1) + tone(6) + silence(0.6), min: 2, max: 5)
        var offset = 0
        for chunk in chunks { offset += chunk.count }
        XCTAssertEqual(Double(offset) / Double(rate), 9.8, accuracy: 0.001)
    }

    func testFlushOnEmptyChunkerReturnsNil() {
        var chunker = chunker(min: 2, max: 5)
        XCTAssertNil(chunker.flush())
    }

    func testSilentChunkIsRecognised() {
        XCTAssertTrue(Chunker.isSilent(silence(2)))
        XCTAssertTrue(Chunker.isSilent((0..<1000).map { _ in Int16.random(in: -20...20) }))
        XCTAssertFalse(Chunker.isSilent(tone(1)))
    }
}

final class MeetingTranscriptTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-11-14 14:00:00 UTC
    private var start: Date { Date(timeIntervalSince1970: 1_794_664_800) }

    private func segments(_ list: [(Double, String)]) -> [TimedSegment] {
        list.map { TimedSegment(start: $0.0, end: $0.0 + 1, text: $0.1) }
    }

    func testMergesBothTracksInTimeOrderWithAbsoluteTimes() {
        // Two chunks per track. Chunk offsets move each segment to meeting time.
        var lines: [MeetingLine] = []
        lines += MeetingTranscript.lines(from: segments([(2, "Can we ship the fix today?"), (30, "Also the docs.")]), track: .me, offset: 128)
        lines += MeetingTranscript.lines(from: segments([(5, "Yes, after the review.")]), track: .them, offset: 128)
        lines += MeetingTranscript.lines(from: segments([(0, "Morning everyone.")]), track: .me, offset: 0)
        lines += MeetingTranscript.lines(from: segments([(1, "Hi, thanks for joining.")]), track: .them, offset: 0)
        let text = MeetingTranscript.render(startedAt: start, appName: "Zoom", lines: lines, timeZone: utc)
        XCTAssertEqual(text, """
            # Meeting 2026-11-14 14:00 (Zoom)
            [14:00:00] Me: Morning everyone.
            [14:00:01] Them: Hi, thanks for joining.
            [14:02:10] Me: Can we ship the fix today?
            [14:02:13] Them: Yes, after the review.
            [14:02:38] Me: Also the docs.

            """)
    }

    func testTheExampleFromTheBrief() {
        let lines = [MeetingLine(track: .them, start: 135, text: "Yes, after the review."),
                     MeetingLine(track: .me, start: 130, text: "Can we ship the fix today?")]
        let text = MeetingTranscript.render(startedAt: start, appName: "Zoom", lines: lines, timeZone: utc)
        XCTAssertTrue(text.contains("[14:02:10] Me: Can we ship the fix today?\n[14:02:15] Them: Yes, after the review.\n"))
    }

    func testEmptyAndSilenceOnlySegmentsAreDropped() {
        let dropped = ["", "   ", "...", "[BLANK_AUDIO]", "(silence)", "*Music*", "[ Silence ]", "—"]
        let kept = MeetingTranscript.lines(from: segments(dropped.enumerated().map { (Double($0.offset), $0.element) } + [(20, "Real words.")]),
                                           track: .me, offset: 0)
        XCTAssertEqual(kept.map(\.text), ["Real words."])
    }

    func testWordsThatMentionSilenceAreKept() {
        XCTAssertFalse(MeetingTranscript.isSilenceOnly("Silence is golden."))
        XCTAssertFalse(MeetingTranscript.isSilenceOnly("Music to my ears"))
    }

    func testTextOnlySegmentSitsAtTheChunkStart() {
        let lines = MeetingTranscript.lines(from: [TimedSegment(start: 0, end: 0, text: "All of it.")], track: .them, offset: 254.9)
        XCTAssertEqual(lines.first?.start, 254.9)
        let text = MeetingTranscript.render(startedAt: start, appName: "Zoom", lines: lines, timeZone: utc)
        XCTAssertTrue(text.contains("[14:04:14] Them: All of it."))
    }

    func testFailedRangesAreListedInTimeOrder() {
        let lines = [MeetingLine(track: .me, start: 5, text: "Before."), MeetingLine(track: .me, start: 400, text: "After.")]
        let missed = [MissedRange(track: .me, start: 120, end: 245.5, reason: "Could not reach the transcription server"),
                      MissedRange(track: .them, start: 120, end: 245.5, reason: "Could not reach the transcription server")]
        let text = MeetingTranscript.render(startedAt: start, appName: "Teams", lines: lines, missed: missed, timeZone: utc)
        XCTAssertEqual(text, """
            # Meeting 2026-11-14 14:00 (Teams)
            [14:00:05] Me: Before.
            [14:02:00–14:04:05] (not transcribed: Could not reach the transcription server)
            [14:06:40] Me: After.

            """)
    }

    func testFolderNameHasMinutePrecision() {
        XCTAssertEqual(MeetingTranscript.folderName(start, timeZone: utc), "2026-11-14-1400")
    }
}

final class AudioAppsTests: XCTestCase {
    private func app(_ id: String, _ name: String? = nil) -> AudioApp { AudioApp(bundleID: id, name: name ?? id) }

    func testIronPetItselfIsNotListed() {
        let list = AudioApps.candidates(from: [app("dev.ironpet.app", "ironpet"), app("com.apple.Music", "Music")], ownBundleID: "dev.ironpet.app")
        XCTAssertEqual(list.map(\.bundleID), ["com.apple.Music"])
    }

    func testMeetingAppsComeFirstThenBrowsersThenTheRest() {
        let list = AudioApps.candidates(from: [app("com.apple.Music", "Music"), app("com.google.Chrome", "Chrome"), app("com.apple.Notes", "Notes"),
                                               app("us.zoom.xos", "zoom.us"), app("org.mozilla.firefox", "Firefox")], ownBundleID: nil)
        XCTAssertEqual(list.map(\.bundleID), ["us.zoom.xos", "com.google.Chrome", "org.mozilla.firefox", "com.apple.Music", "com.apple.Notes"])
    }

    func testZoomIsPreselected() {
        let apps = [app("com.google.Chrome"), app("us.zoom.xos"), app("com.apple.Music")]
        XCTAssertEqual(AudioApps.preselect(from: apps, remembered: ""), .app(app("us.zoom.xos")))
    }

    func testMeetingAppOrderFollowsTheList() {
        let apps = [app("com.apple.FaceTime"), app("com.tinyspeck.slackmacgap"), app("com.microsoft.teams2")]
        XCTAssertEqual(AudioApps.preselect(from: apps, remembered: ""), .app(app("com.microsoft.teams2")))
        XCTAssertEqual(AudioApps.preselect(from: Array(apps.dropFirst(0).filter { $0.bundleID != "com.microsoft.teams2" }), remembered: ""),
                       .app(app("com.tinyspeck.slackmacgap")))
    }

    func testBrowserIsPreselectedWhenNoMeetingAppRuns() {
        let apps = [app("com.apple.Music"), app("com.apple.Safari"), app("com.google.Chrome")]
        XCTAssertEqual(AudioApps.preselect(from: apps, remembered: ""), .app(app("com.google.Chrome")))
    }

    func testRememberedChoiceBeatsABrowserButNotAMeetingApp() {
        let apps = [app("com.apple.Music"), app("com.google.Chrome")]
        XCTAssertEqual(AudioApps.preselect(from: apps, remembered: "com.apple.Music"), .app(app("com.apple.Music")))
        XCTAssertEqual(AudioApps.preselect(from: apps + [app("us.zoom.xos")], remembered: "com.apple.Music"), .app(app("us.zoom.xos")))
        XCTAssertEqual(AudioApps.preselect(from: apps, remembered: AudioApps.allKey), .allSystemAudio)
    }

    func testFallsBackToAllSystemAudio() {
        XCTAssertEqual(AudioApps.preselect(from: [app("com.apple.Music")], remembered: "com.gone.App"), .allSystemAudio)
        XCTAssertEqual(AudioApps.preselect(from: [], remembered: ""), .allSystemAudio)
    }

    func testChoiceKeys() {
        XCTAssertEqual(AudioChoice.allSystemAudio.key, "all")
        XCTAssertEqual(AudioChoice.app(app("us.zoom.xos")).key, "us.zoom.xos")
    }
}

final class MeetingSettingsTests: XCTestCase {
    func testMeetingsAreOffWithSafeDefaults() {
        let meetings = Config().meetings
        XCTAssertFalse(meetings.enabled)
        XCTAssertTrue(meetings.autoSummary)
        XCTAssertNil(meetings.summaryModel)
        XCTAssertEqual(meetings.lastApp, "")
        XCTAssertEqual(Config().hotkeys.meeting, "")
    }

    func testNoHotkeyUnlessEnabledAndBound() {
        var config = Config()
        XCTAssertNil(MeetingController.hotkey(in: config))
        config.hotkeys.meeting = "cmd+opt+m"
        XCTAssertNil(MeetingController.hotkey(in: config), "bound but meetings are off")
        config.meetings.enabled = true
        XCTAssertEqual(MeetingController.hotkey(in: config), "cmd+opt+m")
        config.hotkeys.meeting = ""
        XCTAssertNil(MeetingController.hotkey(in: config))
    }

    @MainActor
    func testStartingIsIgnoredWhileDisabled() {
        let meeting = MeetingController()
        meeting.isEnabled = { false }
        meeting.showPicker()
        XCTAssertEqual(meeting.phase, .idle)
    }

    @MainActor
    func testPickerPreselectsTheRunningMeetingApp() {
        let meeting = MeetingController()
        meeting.isEnabled = { true }
        meeting.meetingConfig = { Config.Meetings() }
        meeting.runningApps = { [AudioApp(bundleID: "com.apple.Music", name: "Music"), AudioApp(bundleID: "us.zoom.xos", name: "zoom.us")] }
        meeting.showPicker()
        XCTAssertEqual(meeting.phase, .choosing)
        XCTAssertEqual(meeting.choice, .app(AudioApp(bundleID: "us.zoom.xos", name: "zoom.us")))
        meeting.dismiss()
        XCTAssertEqual(meeting.phase, .idle)
    }
}

final class SummaryRequestTests: XCTestCase {
    func testEveryPermissionRequestFromTheSummaryAgentIsRefused() {
        XCTAssertFalse(MeetingController.summaryDecision.allow)
        let options: [[String: Any]] = [["kind": "allow_once", "optionId": "yes"], ["kind": "reject_once", "optionId": "no"]]
        let outcome = ACPBackend.outcome(MeetingController.summaryDecision, options: options)
        XCTAssertEqual((outcome["outcome"] as? [String: Any])?["optionId"] as? String, "no")
    }

    func testDefaultSummaryAgentIsInTheCatalog() {
        XCTAssertNotNil(AgentCatalog.agent(id: Config.Meetings().summaryAgent))
    }

    func testPromptAsksForTheThreeSectionsAndEmbedsTheTranscript() async {
        let prompt = await MeetingController.summaryPrompt(transcript: "# Meeting\n[14:00:00] Me: hi\n")
        for part in ["## Summary", "## Decisions", "## Action items", "owner:", "due:", "[14:00:00] Me: hi", "do not change any files"] {
            XCTAssertTrue(prompt.contains(part), part)
        }
    }
}
