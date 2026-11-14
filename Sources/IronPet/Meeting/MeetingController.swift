import AppKit
import AVFoundation
import Foundation

/// One chunk on its way through transcription.
struct MeetingJob: Equatable {
    enum State: Equatable {
        /// Waiting for its first attempt, or for the next one after a failure.
        case waiting(attempts: Int, lastError: String?, notBefore: Date)
        case running(attempts: Int)
        case done
        case failed(reason: String)
    }

    var chunk: ChunkInfo
    var state: State
}

/// The state machine behind meeting transcripts: choosing a source, recording, transcribing what is left,
/// summarizing, done. The panel, the menu, the hotkey and the `--test-mode` endpoints all drive this one object.
@MainActor
final class MeetingController: ObservableObject {
    enum Phase: String { case idle, choosing, recording, finishing, summarizing, done }

    /// Minimum and maximum chunk length. Tests and `--test-mode` override them.
    struct ChunkLengths {
        var minSeconds: Double = Double(Chunker.defaultMin) / Double(WAV.sampleRate)
        var maxSeconds: Double = Double(Chunker.defaultMax) / Double(WAV.sampleRate)

        /// A test chunk length: closes at the first silence after 60% of it, and never runs past it.
        static func test(_ seconds: Double) -> ChunkLengths { ChunkLengths(minSeconds: seconds * 0.6, maxSeconds: seconds) }
    }

    enum SummaryState: Equatable {
        case none, running, ready(URL), failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var apps: [AudioApp] = []
    @Published var choice: AudioChoice = .allSystemAudio
    /// Shown in the picker, for example when system audio could not be started.
    @Published private(set) var notice: String?
    @Published private(set) var lines: [MeetingLine] = []
    @Published private(set) var jobs: [MeetingJob] = []
    @Published private(set) var summary: SummaryState = .none
    @Published private(set) var appName = ""
    private(set) var startedAt: Date?
    private(set) var folder: URL?
    let myLevels = LevelBuffer()
    let theirLevels = LevelBuffer()

    var isEnabled: () -> Bool = { ConfigStore.shared.config.meetings.enabled }
    var makeTranscriber: () -> Transcriber = {
        let voice = ConfigStore.shared.config.voice
        return Transcriber(baseURL: voice.baseUrl, model: voice.model, apiKey: KeyCache.key())
    }

    /// Reads the Keychain once per meeting, off the main thread. A Keychain approval dialog would otherwise
    /// freeze the app, and would reappear for every chunk.
    enum KeyCache {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var loaded: String??

        static func key() -> String? {
            lock.lock()
            defer { lock.unlock() }
            if let loaded { return loaded }
            let key = VoiceKey.load()
            loaded = .some(key)
            return key
        }

        static func forget() {
            lock.lock()
            loaded = nil
            lock.unlock()
        }
    }
    var meetingConfig: () -> Config.Meetings = { ConfigStore.shared.config.meetings }
    var rememberChoice: (String) -> Void = { key in ConfigStore.shared.update { $0.meetings.lastApp = key } }
    /// Seconds to wait before retrying a chunk that failed `attempts` times. Tests shorten it.
    var backoff: (Int) -> TimeInterval = { min(60, 5 * pow(2, Double($0 - 1))) }
    /// Shows the one-time consent notice; true to go on. `--test-mode` skips it.
    var confirmConsent: () -> Bool = { MeetingController.askConsent() }
    var runningApps: () -> [AudioApp] = { AudioApps.running() }
    /// The panel appears and disappears with the phase.
    var onSummaryReady: ((URL) -> Void)?
    var onOpenInChat: ((URL, [URL]) -> Void)?
    var onChange: (() -> Void)?
    /// Agent and model of the last summary run, for `GET /test/meeting`.
    private(set) var lastSummaryRequest: (agent: String, model: String?)?
    private(set) var summaryNotified: [String] = []

    private var recorders: [MeetingTrack: TrackRecorder] = [:]
    private var sources: [MeetingTrack: TrackSource] = [:]
    private var chunkLengths = ChunkLengths()
    private var timer: Timer?
    private var pumping = false
    private var inFlight: Task<Void, Never>?
    private var summaryRunner: ACPBackend?
    private var summaryTimeout: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var starting = false
    /// Bumped by `reset()`, so a request still in flight for a discarded meeting is ignored when it answers.
    private var generation = 0
    /// Failed chunks are retried by the user after the meeting; this makes one try per chunk then.
    private var finalPass = false

    static let consentKey = "meetingConsentShown"

    nonisolated static func hotkey(in config: Config) -> String? {
        guard config.meetings.enabled, !config.hotkeys.meeting.isEmpty else { return nil }
        return config.hotkeys.meeting
    }

    var isRecording: Bool { phase == .recording || phase == .finishing }
    var isBusy: Bool { phase != .idle && phase != .done }
    var transcriptURL: URL? { folder?.appendingPathComponent("transcript.md") }
    var summaryURL: URL? { folder?.appendingPathComponent("summary.md") }

    var counts: (done: Int, waiting: Int, failed: Int) {
        var result = (done: 0, waiting: 0, failed: 0)
        for job in jobs {
            switch job.state {
            case .done: result.done += 1
            case .waiting, .running: result.waiting += 1
            case .failed: result.failed += 1
            }
        }
        return result
    }

    /// The newest transcript lines, for the panel.
    var recentLines: [MeetingLine] {
        Array(lines.sorted { $0.start < $1.start }.suffix(4))
    }

    // MARK: Start

    /// Opens the source picker. Nothing is recorded, and no permission is asked for, until the user starts.
    func showPicker() {
        guard isEnabled(), phase == .idle || phase == .done else { return }
        reset()
        apps = runningApps()
        choice = AudioApps.preselect(from: apps, remembered: meetingConfig().lastApp)
        notice = nil
        setPhase(.choosing)
    }

    /// Closes the picker without recording.
    func dismiss() {
        guard phase == .choosing || phase == .done else { return }
        reset()
        setPhase(.idle)
    }

    /// Starts recording from the picker: the microphone as Me and `choice` as Them.
    func start() {
        guard phase == .choosing, !starting else { return }
        if !UserDefaults.standard.bool(forKey: Self.consentKey) {
            guard confirmConsent() else { return }
            UserDefaults.standard.set(true, forKey: Self.consentKey)
        }
        let picked = choice
        let expected = generation
        starting = true
        Task {
            defer { starting = false }
            guard isEnabled() else { return }
            guard await VoiceController.microphoneAllowed() else {
                // The user closed the picker while the permission prompt was open.
                guard expected == generation else { return }
                return fail("ironpet can't use the microphone. Allow it under System Settings → Privacy & Security → Microphone, then try again.")
            }
            if !ScreenCapture.hasPermission {
                ScreenCapture.requestPermission()
                return fail(MeetingError.captureDenied.localizedDescription)
            }
            guard expected == generation else { return }
            let system = SystemAudioSource(choice: picked)
            system.onStop = { [weak self] error in
                Task { @MainActor in self?.sourceStopped(.them, error) }
            }
            await begin(mic: LocalTrack(MicrophoneSource()), them: system, appName: picked.name, lengths: ChunkLengths(), expected: expected)
            if phase == .recording { rememberChoice(picked.key) }
        }
    }

    /// `--test-mode`: records from WAV files instead of live sources, through the same pipeline. With `them` nil,
    /// the Them track is real: all system audio through ScreenCaptureKit.
    func startTest(mic: URL, them: URL?, appName: String, lengths: ChunkLengths) throws {
        guard isEnabled(), phase == .idle || phase == .done || phase == .choosing else { return }
        reset()
        let micSource = try FileSource(url: mic)
        let themTrack: TrackSource
        if let them {
            themTrack = LocalTrack(try FileSource(url: them))
        } else {
            guard ScreenCapture.hasPermission else { throw MeetingError.captureDenied }
            themTrack = SystemAudioSource(choice: .allSystemAudio)
        }
        setPhase(.choosing)
        let expected = generation
        starting = true
        Task {
            defer { starting = false }
            await begin(mic: LocalTrack(micSource), them: themTrack, appName: appName, lengths: lengths, expected: expected)
        }
    }

    private func begin(mic: TrackSource, them: TrackSource, appName: String, lengths: ChunkLengths, expected: Int) async {
        // Cancelled while permissions were being checked.
        guard expected == generation else { return }
        let start = Date()
        let folder = Self.newFolder(for: start)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return fail("Could not create \(folder.path): \(error.localizedDescription)")
        }
        reset()
        let started = generation
        self.folder = folder
        self.startedAt = start
        self.appName = appName
        chunkLengths = lengths
        let pairs: [(MeetingTrack, TrackSource, LevelBuffer)] = [(.me, mic, myLevels), (.them, them, theirLevels)]
        for (track, source, _) in pairs {
            let recorder = TrackRecorder(track: track, folder: folder, chunker: Chunker(
                minSamples: Int(lengths.minSeconds * Double(WAV.sampleRate)),
                maxSamples: Int(lengths.maxSeconds * Double(WAV.sampleRate))))
            recorder.onChunk = { [weak self] info in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.chunkClosed(info) } }
            }
            recorders[track] = recorder
            sources[track] = source
        }
        do {
            for (track, source, levels) in pairs {
                guard let recorder = recorders[track] else { continue }
                try await source.start(level: { levels.record($0) }, samples: { recorder.ingest($0) })
                recorder.start()
            }
        } catch {
            for source in pairs.map(\.1) { source.stop() }
            for recorder in recorders.values { recorder.onChunk = nil; recorder.finish { _ in } }
            recorders = [:]
            sources = [:]
            try? FileManager.default.removeItem(at: folder)
            self.folder = nil
            self.startedAt = nil
            return fail("Could not start recording: \(error.localizedDescription)")
        }
        // The user cancelled while the sources were starting: stop them, and keep nothing.
        guard started == generation else {
            for (_, source, _) in pairs { source.stop() }
            for recorder in pairs.compactMap({ recorders[$0.0] }) { recorder.onChunk = nil; recorder.finish { _ in } }
            try? FileManager.default.removeItem(at: folder)
            return
        }
        notice = nil
        writeTranscript()
        let timer = Timer(timeInterval: LevelBuffer.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        setPhase(.recording)
    }

    private func fail(_ message: String) {
        notice = message
        // Back to the picker, so the user can pick again or cancel.
        if phase != .choosing { setPhase(.choosing) } else { objectWillChange.send(); onChange?() }
    }

    private var tickCount = 0

    private func tick() {
        myLevels.tick()
        theirLevels.tick()
        tickCount += 1
        // Housekeeping once a second: retries whose back-off has passed.
        if tickCount % Int(1 / LevelBuffer.tickInterval) == 0 { pump() }
    }

    // MARK: Stop

    /// Ends the recording, transcribes what is left, and then summarizes.
    func stop() {
        guard phase == .recording else { return }
        setPhase(.finishing)
        timer?.invalidate()
        timer = nil
        for source in sources.values { source.stop() }
        sources = [:]
        let recorders = self.recorders
        self.recorders = [:]
        let generation = self.generation
        Task {
            for recorder in recorders.values {
                let info: ChunkInfo? = await withCheckedContinuation { continuation in
                    recorder.finish { continuation.resume(returning: $0) }
                }
                // Hop through the main queue so chunks that closed a moment ago are queued first.
                if let info { await MainActor.run { chunkClosed(info) } }
            }
            // Cancelled, or a new meeting started, while the recorders finished.
            guard generation == self.generation else { return }
            finalPass = true
            makeAllDue()
            pump()
        }
    }

    /// Stops recording and deletes the meeting folder. No agent runs.
    func discard() {
        guard phase == .recording || phase == .finishing else { return }
        timer?.invalidate()
        timer = nil
        for source in sources.values { source.stop() }
        sources = [:]
        let recorders = self.recorders
        self.recorders = [:]
        inFlight?.cancel()
        let folder = self.folder
        reset()
        // Delete only after every recorder's queue has finished its last write.
        let group = DispatchGroup()
        for recorder in recorders.values {
            recorder.onChunk = nil
            group.enter()
            recorder.finish { _ in group.leave() }
        }
        group.notify(queue: .global()) {
            if let folder { try? FileManager.default.removeItem(at: folder) }
        }
        setPhase(.idle)
    }

    /// The panel's Cancel button: asks first.
    func confirmDiscard() {
        let alert = NSAlert()
        alert.messageText = "Discard this meeting?"
        alert.informativeText = "The recording, the transcript and everything transcribed so far are deleted."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Recording")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { discard() }
    }

    /// For quitting the app mid-meeting: writes the audio captured so far, and marks what was not yet transcribed.
    func prepareForQuit() {
        guard phase == .recording || phase == .finishing else { return }
        timer?.invalidate()
        for source in sources.values { source.stop() }
        let reason = "ironpet quit before it was transcribed"
        for index in jobs.indices {
            switch jobs[index].state {
            case .waiting, .running: jobs[index].state = .failed(reason: reason)
            default: break
            }
        }
        for recorder in recorders.values {
            recorder.onChunk = nil
            let box = ChunkBox()
            let semaphore = DispatchSemaphore(value: 0)
            recorder.finish { info in
                box.info = info
                semaphore.signal()
            }
            semaphore.wait()
            if let info = box.info { jobs.append(MeetingJob(chunk: info, state: .failed(reason: reason))) }
        }
        writeTranscript()
    }

    private final class ChunkBox: @unchecked Sendable { var info: ChunkInfo? }

    // MARK: Chunks

    private func chunkClosed(_ info: ChunkInfo) {
        guard folder != nil, phase == .recording || phase == .finishing else { return }
        if info.silent {
            jobs.append(MeetingJob(chunk: info, state: .done))
        } else {
            jobs.append(MeetingJob(chunk: info, state: .waiting(attempts: 0, lastError: nil, notBefore: Date())))
        }
        pump()
    }

    private func makeAllDue() {
        for index in jobs.indices {
            if case .waiting(let attempts, let error, _) = jobs[index].state {
                jobs[index].state = .waiting(attempts: attempts, lastError: error, notBefore: .distantPast)
            }
        }
    }

    /// Starts the next chunk that is due. One request at a time, oldest chunk first.
    private func pump() {
        guard !pumping, phase == .recording || phase == .finishing || phase == .done || phase == .summarizing else { return }
        let now = Date()
        let due = jobs.indices.filter {
            if case .waiting(_, _, let notBefore) = jobs[$0].state { return notBefore <= now }
            return false
        }.min { jobs[$0].chunk.offset < jobs[$1].chunk.offset }
        guard let index = due, case .waiting(let attempts, _, _) = jobs[index].state else {
            settleIfFinished()
            return
        }
        pumping = true
        jobs[index].state = .running(attempts: attempts)
        let chunk = jobs[index].chunk
        let make = makeTranscriber
        let generation = self.generation
        inFlight = Task.detached { [weak self] in
            let result: Result<[TimedSegment], Error>
            do {
                let transcriber = make()
                let wav = try Data(contentsOf: chunk.url)
                result = .success(try await transcriber.transcribeSegments(wav: wav))
            } catch {
                result = .failure(error)
            }
            await self?.completed(chunk, attempts: attempts, generation: generation, result)
        }
    }

    private func completed(_ chunk: ChunkInfo, attempts: Int, generation: Int, _ result: Result<[TimedSegment], Error>) {
        guard generation == self.generation else { return }
        pumping = false
        guard let index = jobs.firstIndex(where: { $0.chunk.url == chunk.url }), phase != .idle else { return }
        switch result {
        case .success(let segments):
            jobs[index].state = .done
            lines += MeetingTranscript.lines(from: segments, track: chunk.track, offset: chunk.offset)
            writeTranscript()
        case .failure(let error) where error is CancellationError:
            jobs[index].state = .waiting(attempts: attempts, lastError: nil, notBefore: .distantPast)
        case .failure(let error):
            let reason = error.localizedDescription
            if finalPass {
                jobs[index].state = .failed(reason: reason)
                writeTranscript()
            } else {
                jobs[index].state = .waiting(attempts: attempts + 1, lastError: reason,
                                             notBefore: Date().addingTimeInterval(backoff(attempts + 1)))
            }
        }
        objectWillChange.send()
        onChange?()
        pump()
    }

    /// When recording has ended and no chunk is left to try, finishes the meeting.
    private func settleIfFinished() {
        guard !pumping, finalPass else { return }
        let open = jobs.contains {
            switch $0.state {
            case .waiting, .running: return true
            default: return false
            }
        }
        guard !open else { return }
        if phase == .finishing { conclude() }
    }

    /// Tries every failed chunk again, once. For the panel's Retry button.
    func retryFailed() {
        guard phase == .done || phase == .summarizing, counts.failed > 0 else { return }
        for index in jobs.indices {
            if case .failed = jobs[index].state {
                jobs[index].state = .waiting(attempts: 0, lastError: nil, notBefore: .distantPast)
            }
        }
        finalPass = true
        pump()
        objectWillChange.send()
    }

    // MARK: Transcript

    private func writeTranscript() {
        guard let folder, let startedAt else { return }
        let missed = jobs.compactMap { job -> MissedRange? in
            guard case .failed(let reason) = job.state else { return nil }
            return MissedRange(track: job.chunk.track, start: job.chunk.offset,
                               end: job.chunk.offset + job.chunk.duration, reason: reason)
        }
        let text = MeetingTranscript.render(startedAt: startedAt, appName: appName, lines: lines, missed: missed)
        do {
            try text.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        } catch {
            NSLog("ironpet: could not write transcript.md: \(error)")
        }
    }

    // MARK: Summary

    private func conclude() {
        writeTranscript()
        let config = meetingConfig()
        guard config.autoSummary, !lines.isEmpty else {
            setPhase(.done)
            return
        }
        summarize(config)
    }

    /// Runs the chosen agent on the transcript and writes its answer to `summary.md`.
    func summarize(_ config: Config.Meetings? = nil) {
        guard let folder, let transcriptURL, let text = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return }
        let config = config ?? meetingConfig()
        lastSummaryRequest = (config.summaryAgent, config.summaryModel)
        summary = .running
        setPhase(.summarizing)
        guard let agent = AgentCatalog.agent(id: config.summaryAgent) else {
            return summaryFinished("", error: "The summary agent \"\(config.summaryAgent)\" is not available. Pick another in Settings → Meetings.")
        }
        let runner = ACPBackend(agent: agent)
        // Only the meeting folder is shared, and every permission request is refused, so the agent can read and answer
        // but not change files or run commands. ironpet writes summary.md itself.
        runner.restricted = true
        runner.onPermission = { _, respond in respond(Self.summaryDecision) }
        summaryRunner = runner
        let turn = ACPTurn(prompt: Self.summaryPrompt(transcript: text), preamble: nil, workspace: folder, resume: nil,
                           model: config.summaryModel, images: [], files: [])
        var answer = ""
        summaryTask = Task { [weak self] in
            await runner.runTurn(turn) { event in
                switch event {
                case .assistant(let chunk): answer += chunk
                case .finished(let error): self?.summaryFinished(answer, error: error)
                case .needsSignIn: self?.summaryFinished("", error: "\(agent.name) needs you to sign in. Open it in the chat once, then try again.")
                case .needsRuntime: self?.summaryFinished("", error: "\(agent.name) needs Node 22 or Bun. Open it in the chat once to set that up.")
                default: break
                }
            }
        }
        summaryTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            self?.summaryFinished("", error: "The agent did not answer within 10 minutes.")
        }
    }

    /// Every permission request from the summary agent is refused.
    nonisolated static let summaryDecision = ApprovalDecision.deny("Meeting summaries are read-only")

    private func summaryFinished(_ answer: String, error: String?) {
        guard phase == .summarizing, let url = summaryURL else { return }
        summaryTimeout?.cancel()
        summaryTask?.cancel()
        summaryTask = nil
        summaryRunner?.cancel()
        summaryRunner?.shutdown()
        summaryRunner = nil
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error {
            summary = .failed(error)
        } else if text.isEmpty {
            summary = .failed("The agent returned no text.")
        } else {
            do {
                try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
                summary = .ready(url)
                summaryNotified.append(url.path)
                onSummaryReady?(url)
            } catch {
                summary = .failed("Could not write summary.md: \(error.localizedDescription)")
            }
        }
        setPhase(.done)
    }

    static func summaryPrompt(transcript: String) -> String {
        let limit = 300_000
        var body = transcript
        var note = ""
        if body.count > limit {
            body = String(body.suffix(limit))
            note = "\n(The start of a very long transcript was cut here. The full text is in transcript.md.)\n"
        }
        return """
            Below is the transcript of a meeting. "Me" is the person who recorded it. "Them" is everyone else on the \
            call, recorded from one app, so several people can appear as "Them".

            Do not use any tools and do not change any files. Answer in Markdown, in exactly these three sections:

            ## Summary
            Three to six sentences on what the meeting was about and how it ended.

            ## Decisions
            One bullet per decision that was made. Write "None." if there were none.

            ## Action items
            A checklist of open action items, one per line, as `- [ ] <task> (owner: <Me, Them, or the name if \
            someone said it>, due: <date, only if one was mentioned>)`. Leave out "due" when no date was mentioned. \
            Write "None." if there were none.

            Use only what is in the transcript. Transcripts can contain recognition errors, so do not guess names.
            \(note)
            --- transcript.md ---
            \(body)
            """
    }

    // MARK: After the meeting

    func openTranscript() {
        if let url = transcriptURL { NSWorkspace.shared.open(url) }
    }

    func openSummary() {
        if let url = summaryURL, FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
    }

    /// A new chat with the transcript (and the summary, if there is one) attached.
    func openInChat() {
        guard let folder, let transcript = transcriptURL else { return }
        var files = [transcript]
        if let summary = summaryURL, FileManager.default.fileExists(atPath: summary.path) { files.append(summary) }
        onOpenInChat?(folder, files)
    }

    // MARK: Plumbing

    private func sourceStopped(_ track: MeetingTrack, _ error: Error) {
        guard phase == .recording else { return }
        NSLog("ironpet: \(track.rawValue) audio stopped: \(error.localizedDescription)")
        notice = "\(track.rawValue == "Me" ? "The microphone" : appName) stopped sending audio: \(error.localizedDescription)"
        objectWillChange.send()
    }

    private func setPhase(_ next: Phase) {
        phase = next
        onChange?()
    }

    private func reset() {
        generation += 1
        KeyCache.forget()
        inFlight?.cancel()
        timer?.invalidate()
        timer = nil
        summaryTimeout?.cancel()
        summaryTask?.cancel()
        summaryTask = nil
        summaryRunner?.cancel()
        summaryRunner?.shutdown()
        summaryRunner = nil
        recorders = [:]
        sources = [:]
        lines = []
        jobs = []
        summary = .none
        folder = nil
        startedAt = nil
        appName = ""
        finalPass = false
        pumping = false
        tickCount = 0
        myLevels.reset()
        theirLevels.reset()
        lastSummaryRequest = nil
        summaryNotified = []
        notice = nil
    }

    private static func newFolder(for date: Date) -> URL {
        let base = MeetingTranscript.folderName(date)
        var url = Paths.meetings.appendingPathComponent(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Paths.meetings.appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        return url
    }

    /// The one-time notice before the first meeting.
    static func askConsent() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Tell the people on the call"
        alert.informativeText = """
            ironpet records your microphone and the audio of the app you pick, sends it to the transcription \
            server from Settings → Voice, and writes a transcript to ~/.ironpet/meetings. The audio files stay \
            there too.

            Recording other people without their consent is illegal in many places. Tell everyone on the call \
            before you start. The meeting panel stays on screen for as long as ironpet is recording.
            """
        alert.addButton(withTitle: "I Will Tell Them")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
