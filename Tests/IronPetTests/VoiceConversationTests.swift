import XCTest
@testable import IronPet

@MainActor
private final class FakeMic: ConversationListening {
    var onEvent: ((ConversationMic.Event) -> Void)?
    let levels = LevelBuffer()
    let player: ClipPlaying = SilentSpeaker()
    private(set) var started = false
    private(set) var stopped = false
    private(set) var playback: [Bool] = []

    func start() throws { started = true }
    func stop() { stopped = true }
    func setPlayback(_ on: Bool) { playback.append(on) }

    func say(_ text: String) {
        onEvent?(.speechStarted)
        onEvent?(.utterance(Data(text.utf8)))
    }
}

@MainActor
private final class FakeSpeaker: ConversationSpeaker {
    var said: [String] = []
    var stops = 0
    /// Lines wait for `release()` instead of ending at once.
    var hold = false
    private var gate: CheckedContinuation<Void, Error>?
    var isSpeaking: Bool { gate != nil }

    func say(_ text: String) async throws {
        said.append(text)
        guard hold else { return }
        try await withCheckedThrowingContinuation { gate = $0 }
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func stop() {
        stops += 1
        gate?.resume(throwing: CancellationError())
        gate = nil
    }
}

@MainActor
private final class FakeFrontDesk: FrontDeskTalking {
    var asked: [String] = []
    var answer = "All quiet and two jobs are running."
    var error: JobError?
    var hold = false
    private(set) var prepared = 0
    private(set) var cancels = 0
    private(set) var finishes = 0
    private var gate: CheckedContinuation<Void, Error>?
    var isWaiting: Bool { gate != nil }

    func prepare() { prepared += 1 }

    /// The reply's pieces, streamed in order; nil streams the whole answer at once.
    var chunks: [String]?
    /// Waits after the pieces are streamed, until `release()`.
    var holdAfterChunks = false

    func reply(to text: String, onText: @escaping (String) -> Void) async throws -> String {
        asked.append(text)
        if hold { try await withCheckedThrowingContinuation { gate = $0 } }
        if let error { throw error }
        for piece in chunks ?? [answer] {
            onText(piece)
            try? await Task.sleep(for: .milliseconds(20))
        }
        if holdAfterChunks { try await withCheckedThrowingContinuation { gate = $0 } }
        return answer
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func cancel() {
        cancels += 1
        gate?.resume(throwing: CancellationError())
        gate = nil
    }

    func finish() { finishes += 1 }
}

@MainActor
final class VoiceConversationTests: XCTestCase {
    private var mic: FakeMic!
    private var speaker: FakeSpeaker!
    private var desk: FakeFrontDesk!
    private var failures: [String] = []
    private var events: [String] = []

    private func conversation(mode: VoiceConversation.Mode = .microphone, silence: TimeInterval = 30) -> VoiceConversation {
        mic = FakeMic()
        speaker = FakeSpeaker()
        desk = FakeFrontDesk()
        failures = []
        events = []
        let conversation = VoiceConversation(frontDesk: desk)
        conversation.isEnabled = { true }
        conversation.listenMode = { mode }
        conversation.silenceSeconds = { silence }
        conversation.microphoneAllowed = { true }
        conversation.makeMic = { [unowned self] in mic }
        conversation.makeSpeaker = { [unowned self] _ in speaker }
        conversation.transcribe = { String(decoding: $0, as: UTF8.self) }
        conversation.fillerDelay = 10
        conversation.onFailure = { [unowned self] in failures.append($0) }
        conversation.onStarted = { [unowned self] mode in events.append("started \(mode.rawValue)") }
        conversation.onEnded = { [unowned self] in events.append("ended") }
        return conversation
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func started(_ mode: VoiceConversation.Mode = .microphone, silence: TimeInterval = 30) async -> VoiceConversation {
        let conversation = conversation(mode: mode, silence: silence)
        conversation.start()
        await until { conversation.state == .listening }
        return conversation
    }

    func testAnUtteranceIsAnsweredAloudAndThePetListensAgain() async {
        let conversation = await started()
        XCTAssertTrue(mic.started)
        XCTAssertEqual(desk.prepared, 1)
        XCTAssertEqual(events, ["started microphone"])
        XCTAssertEqual(conversation.mood, .attentive)

        mic.say("what's going on")
        await until { conversation.state == .listening && !speaker.said.isEmpty }
        XCTAssertEqual(desk.asked, ["what's going on"])
        XCTAssertEqual(speaker.said, ["All quiet and two jobs are running."])
        XCTAssertEqual(conversation.heard, "what's going on")
        XCTAssertEqual(conversation.reply, "All quiet and two jobs are running.")
        // The pet's voice raised the bar for barge-in, and lowered it again.
        XCTAssertEqual(mic.playback, [true, false])
    }

    func testTalkingOverThePetCutsItOff() async {
        let conversation = await started()
        speaker.hold = true
        mic.say("tell me about my day")
        await until { speaker.isSpeaking }
        XCTAssertEqual(conversation.state, .speaking)

        speaker.hold = false
        mic.say("actually, just the meetings")
        await until { desk.asked.count == 2 && conversation.state == .listening }
        XCTAssertGreaterThanOrEqual(speaker.stops, 1)
        XCTAssertEqual(desk.asked.last, "actually, just the meetings")
        XCTAssertEqual(speaker.said.last, desk.answer)
        // Cutting the pet off lowers the barge-in bar at once, not after the next reply.
        XCTAssertEqual(mic.playback, [true, false, true, false])
    }

    func testTheTalkKeyInterruptsThePetWhileItSpeaksAndEndsTheConversationWhenListening() async {
        let conversation = await started()
        speaker.hold = true
        mic.say("tell me about my day")
        await until { speaker.isSpeaking }

        conversation.pressTalk()
        await until { conversation.state == .listening }
        XCTAssertTrue(conversation.isActive)
        XCTAssertGreaterThanOrEqual(speaker.stops, 1)
        XCTAssertEqual(events, ["started microphone"])

        conversation.pressTalk()
        XCTAssertFalse(conversation.isActive)
        XCTAssertEqual(events, ["started microphone", "ended"])
    }

    func testEachSentenceIsSaidAsTheReplyWritesIt() async {
        let conversation = await started()
        desk.chunks = ["Two jobs are done. ", "The review is still", " waiting for you."]
        desk.answer = desk.chunks!.joined()
        desk.holdAfterChunks = true
        mic.say("status")
        await until { speaker.said.count == 1 && conversation.state == .speaking }
        XCTAssertEqual(speaker.said, ["Two jobs are done."])
        XCTAssertEqual(conversation.state, .speaking)
        XCTAssertEqual(conversation.mood, .idle)

        await until { desk.isWaiting }
        desk.release()
        await until { conversation.state == .listening && speaker.said.count == 2 }
        XCTAssertEqual(speaker.said, ["Two jobs are done.", "The review is still waiting for you."])
        XCTAssertEqual(conversation.reply, desk.answer)
        XCTAssertEqual(mic.playback, [true, false])
    }

    func testTalkingOverAStreamedReplyDropsTheRestOfIt() async {
        let conversation = await started()
        desk.chunks = ["First point is clear. ", "Second point is still coming."]
        desk.answer = desk.chunks!.joined()
        desk.holdAfterChunks = true
        mic.say("tell me")
        await until { speaker.said.count == 1 }

        // The agent keeps sending text for a moment after the user talks over it; none of it may be said.
        mic.say("is the lint fixed")
        desk.holdAfterChunks = false
        desk.chunks = ["The lint is fixed."]
        desk.answer = "The lint is fixed."
        await until { desk.asked.count == 2 && conversation.state == .listening && speaker.said.count == 2 }
        XCTAssertEqual(speaker.said, ["First point is clear.", "The lint is fixed."])
    }

    func testHeldJobsCountDownOnceThePetHasAnswered() async {
        let conversation = await started()
        var releases = 0
        conversation.releaseHeldJobs = { releases += 1 }
        speaker.hold = true
        mic.say("fix the login test")
        await until { speaker.isSpeaking }
        XCTAssertEqual(releases, 0, "the pet is still saying what it started")
        speaker.release()
        await until { conversation.state == .listening && releases == 1 }
        conversation.end()
        XCTAssertEqual(releases, 2)
    }

    func testAJobUpdateWaitsWhileTheUserIsTalking() async {
        let conversation = await started()
        mic.onEvent?(.speechStarted)
        XCTAssertTrue(conversation.announce("Lint is done."))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(speaker.said.isEmpty, "the update does not talk over the user")
        mic.onEvent?(.utterance(Data("what about the tests".utf8)))
        await until { speaker.said.count == 2 && conversation.state == .listening }
        XCTAssertEqual(desk.asked, ["what about the tests"])
        XCTAssertEqual(speaker.said, [desk.answer, "Lint is done."])
    }

    func testSpeakingWhileThePetThinksCancelsTheTurn() async {
        let conversation = await started()
        desk.hold = true
        mic.say("start the tests")
        await until { desk.isWaiting }
        XCTAssertEqual(conversation.state, .thinking)
        XCTAssertEqual(conversation.mood, .working)

        desk.hold = false
        mic.say("no, the lint")
        await until { desk.asked.count == 2 && conversation.state == .listening }
        XCTAssertEqual(desk.cancels, 1)
        XCTAssertEqual(speaker.said, [desk.answer], "the cancelled turn says nothing")
    }

    func testAFillerLineCoversASlowReply() async {
        let conversation = await started()
        conversation.fillerDelay = 0.02
        desk.hold = true
        mic.say("what failed in CI")
        await until { speaker.said.count == 1 }
        XCTAssertTrue(VoiceConversation.fillers.contains(speaker.said[0]))
        XCTAssertEqual(conversation.state, .thinking)
        desk.release()
        await until { speaker.said.count == 2 && conversation.state == .listening }
        XCTAssertEqual(speaker.said[1], desk.answer)
    }

    func testSilenceEndsTheConversation() async {
        let conversation = await started(silence: 0.05)
        await until { conversation.state == .idle }
        XCTAssertTrue(mic.stopped)
        XCTAssertEqual(desk.finishes, 1)
        XCTAssertEqual(events, ["started microphone", "ended"])
    }

    func testGoodbyeEndsTheConversation() async {
        let conversation = await started()
        mic.say("Thanks, that's all.")
        await until { conversation.state == .idle }
        XCTAssertEqual(speaker.said, ["Talk soon."])
        XCTAssertTrue(desk.asked.isEmpty)
    }

    func testCancelThatStopsTheHeldJobWithoutAskingTheAgent() async {
        let conversation = await started()
        var cancelled = 0
        conversation.cancelHeldJob = {
            cancelled += 1
            return Job(id: "job-1", title: "Fix the login test", prompt: "", folder: "/tmp", agent: "claude", created: Date())
        }
        mic.say("No, wait, cancel that")
        await until { !speaker.said.isEmpty }
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(speaker.said, ["Okay, I cancelled Fix the login test."])
        XCTAssertTrue(desk.asked.isEmpty)
    }

    func testCancelThatWithNothingHeldGoesToTheAgent() async {
        let conversation = await started()
        conversation.cancelHeldJob = { nil }
        mic.say("cancel that")
        await until { desk.asked == ["cancel that"] }
    }

    func testAFailedReplyIsSpokenAndListeningGoesOn() async {
        let conversation = await started()
        desk.error = JobError(message: "Claude needs you to sign in.")
        mic.say("anything need me")
        await until { conversation.state == .listening && !speaker.said.isEmpty }
        XCTAssertEqual(speaker.said, ["Sorry, that didn't work. Claude needs you to sign in."])
    }

    func testACallKeepsVoiceModeFromStartingAndEndsIt() async {
        let conversation = conversation()
        conversation.quietReason = { "a call" }
        conversation.start()
        XCTAssertEqual(conversation.state, .idle)
        XCTAssertEqual(failures, ["Voice mode doesn't listen during a call."])

        var onCall = false
        conversation.quietReason = { onCall ? "a call" : nil }
        conversation.quietCheckInterval = 0.02
        conversation.start()
        await until { conversation.state == .listening }
        onCall = true
        await until { conversation.state == .idle }
        XCTAssertEqual(failures.last, "Voice mode stopped: a call started.")
    }

    func testWisprTextIsAnsweredWithoutAMicrophone() async {
        let conversation = await started(.wispr)
        XCTAssertFalse(mic.started)
        XCTAssertEqual(conversation.mode, .wispr)
        conversation.receive("what's on my calendar")
        await until { conversation.state == .listening && !speaker.said.isEmpty }
        XCTAssertEqual(desk.asked, ["what's on my calendar"])
    }

    func testAJobUpdateWaitsForTheReplyToEnd() async {
        let conversation = await started()
        XCTAssertFalse(VoiceConversation(frontDesk: desk).announce("ignored"), "no conversation, so the caller speaks it")

        desk.hold = true
        mic.say("how are the jobs")
        await until { desk.isWaiting }
        XCTAssertTrue(conversation.announce("Fix the login test is done."))
        desk.release()
        await until { speaker.said.count == 2 && conversation.state == .listening }
        XCTAssertEqual(speaker.said, [desk.answer, "Fix the login test is done."])

        XCTAssertTrue(conversation.announce("Lint is done."))
        await until { speaker.said.count == 3 }
    }

    func testEndStopsEverything() async {
        let conversation = await started()
        desk.hold = true
        mic.say("start a job")
        await until { desk.isWaiting }
        conversation.end()
        XCTAssertEqual(conversation.state, .idle)
        XCTAssertEqual(desk.cancels, 1)
        XCTAssertEqual(desk.finishes, 1)
        XCTAssertTrue(mic.stopped)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(speaker.said.isEmpty)
    }

    func testPhrases() {
        XCTAssertTrue(VoiceConversation.isCancel("Cancel that."))
        XCTAssertTrue(VoiceConversation.isCancel("no wait, don't"))
        XCTAssertTrue(VoiceConversation.isCancel("Never mind"))
        XCTAssertFalse(VoiceConversation.isCancel("cancel my 3pm meeting"))
        XCTAssertTrue(VoiceConversation.isGoodbye("Bye!"))
        XCTAssertTrue(VoiceConversation.isGoodbye("That’s all"))
        XCTAssertFalse(VoiceConversation.isGoodbye("say bye to the team in Slack"))
    }

    func testJobUpdateLines() {
        var job = Job(id: "job-1", title: "Fix the login test", prompt: "", folder: "/tmp", agent: "claude", created: Date())
        job.state = .done
        job.summary = "It waited on a fixed sleep."
        XCTAssertEqual(VoiceModeController.update(for: job), "Fix the login test is done. It waited on a fixed sleep.")
        job.state = .needsApproval
        job.waitingFor = "Run rm -rf build"
        XCTAssertEqual(VoiceModeController.update(for: job), "Fix the login test needs your OK to run rm -rf build. Click Allow in its bubble.")
        job.state = .running
        XCTAssertNil(VoiceModeController.update(for: job))
    }
}

@MainActor
final class SpeechTextStreamingTests: XCTestCase {
    func testOnlyCompleteSentencesAreReleased() {
        let partial = SpeechText.completeSentences("Two jobs are done. The review is", final: false)
        XCTAssertEqual(partial.sentences, ["Two jobs are done."])
        XCTAssertEqual(partial.rest, "The review is")
    }

    func testAFinishedSentenceWithATrailingSpaceIsReleased() {
        let streamed = SpeechText.completeSentences("Two jobs are done. ", final: false)
        XCTAssertEqual(streamed.sentences, ["Two jobs are done."])
        XCTAssertEqual(streamed.rest, "")
    }

    func testTheLastSentenceIsReleasedWhenTheReplyEnds() {
        let end = SpeechText.completeSentences("The review is still waiting", final: true)
        XCTAssertEqual(end.sentences, ["The review is still waiting"])
        XCTAssertEqual(end.rest, "")
    }

    func testCompletedLinesAreReleasedWithTheirMarkupCleaned() {
        let lines = SpeechText.completeSentences("**Done** with the lint.\n- Review is waiting", final: false)
        XCTAssertEqual(lines.sentences, ["Done with the lint."])
        XCTAssertEqual(lines.rest, "- Review is waiting")
    }
}
