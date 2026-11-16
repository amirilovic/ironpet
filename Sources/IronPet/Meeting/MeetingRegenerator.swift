import Foundation

enum RegenerationMode: Equatable {
    /// Transcribe every saved chunk again, then summarise the new transcript.
    case full
    /// Summarise the transcript.md that is already there, for example after a speaker was named.
    case summaryOnly
}

struct RegenerationProgress: Equatable {
    enum Stage: Equatable {
        case reading
        case transcribing(chunk: Int, of: Int)
        case summarising
    }

    var stage: Stage

    var label: String {
        switch stage {
        case .reading: return "Reading audio"
        case .transcribing(let chunk, let total): return "Transcribing chunk \(chunk) of \(total)"
        case .summarising: return "Summarising"
        }
    }
}

struct RegenerationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// What a finished regeneration changed, for the caller that offers the new action items as tasks.
struct MeetingReplacement {
    var folder: URL
    var mode: RegenerationMode
    var previousSummary: String?
    var summary: String
}

/// Reads a meeting folder's audio chunks and the facts the transcript header needs.
enum MeetingFolderScan {
    struct Result {
        var chunks: [ChunkInfo]
        var startedAt: Date
        var appName: String
    }

    /// `mic-001.wav` or `them-012.wav` gives the track and chunk number; any other name gives nil.
    static func chunkName(_ name: String) -> (track: MeetingTrack, index: Int)? {
        let parts = name.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, parts[1].hasSuffix(".wav"), let index = Int(parts[1].dropLast(4)),
              let track = MeetingTrack.allCases.first(where: { $0.filePrefix == parts[0] }) else { return nil }
        return (track, index)
    }

    /// Chunks of both tracks in meeting order. Offsets are the summed lengths of the earlier chunks of the same
    /// track, which is how `TrackRecorder` counted them. Reads every file, so call it off the main thread.
    static func scan(_ folder: URL) throws -> Result {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        var chunks: [ChunkInfo] = []
        var firstWritten: [Date] = []
        for track in MeetingTrack.allCases {
            var offset: TimeInterval = 0
            let files = names.compactMap { name in chunkName(name).flatMap { $0.track == track ? ($0.index, name) : nil } }.sorted { $0.0 < $1.0 }
            for (number, (index, name)) in files.enumerated() {
                let url = folder.appendingPathComponent(name)
                let samples = WAV.samples(of: try Data(contentsOf: url))
                let duration = Double(samples.count) / Double(WAV.sampleRate)
                chunks.append(ChunkInfo(track: track, index: index, url: url, offset: offset, duration: duration,
                                        silent: Chunker.isSilent(samples) || samples.count < WAV.sampleRate / 4))
                // A chunk's file is written when it closes, so its time minus its length is when the recording began.
                if number == 0, let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    firstWritten.append(written.addingTimeInterval(-duration))
                }
                offset += duration
            }
        }
        chunks.sort { ($0.offset, $0.track) < ($1.offset, $1.track) }
        let minute = MeetingLibrary.date(folderName: folder.lastPathComponent) ?? Date()
        // The folder name only knows the minute. The files know the second, which keeps the clock times of a new
        // transcript equal to the old one. A time outside that minute means the files were copied, so it is ignored.
        let exact = firstWritten.min().flatMap { $0 >= minute && $0 < minute.addingTimeInterval(60) ? $0 : nil }
        let old = try? String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        return Result(chunks: chunks, startedAt: exact ?? minute, appName: appName(fromTranscript: old))
    }

    /// The app in `# Meeting 2026-11-14 14:00 (Zoom)`.
    static func appName(fromTranscript text: String?) -> String {
        guard let first = text?.components(separatedBy: "\n").first, first.hasPrefix("# Meeting "), first.hasSuffix(")"),
              let open = first.firstIndex(of: "(") else { return "unknown app" }
        let name = first[first.index(after: open)..<first.index(before: first.endIndex)]
        return name.isEmpty ? "unknown app" : String(name)
    }
}

/// Rebuilds a past meeting's transcript and summary with the settings in force now: the transcription model, the
/// voices in the store and the summary agent. Nothing in the folder changes until everything succeeded, and the files
/// it replaces stay as `transcript.prev.md` and `summary.prev.md`.
@MainActor
final class MeetingRegenerator: ObservableObject {
    /// The meeting being rebuilt. One at a time.
    @Published private(set) var activeID: String?
    @Published private(set) var progress: RegenerationProgress?
    /// The last failure for each meeting, until it is tried again.
    @Published private(set) var errors: [String: String] = [:]
    /// Counts finished runs, so a view knows when the files on disk changed.
    @Published private(set) var completed = 0

    var makeTranscriber: () -> Transcriber = {
        let voice = ConfigStore.shared.config.voice
        return Transcriber(baseURL: voice.baseUrl, model: voice.model, apiKey: MeetingController.KeyCache.key(), usageFeature: .meetingTranscription)
    }
    var diarizer: SpeakerDiarizing = FluidDiarizer()
    var voiceStore: VoiceStore = .shared
    var recogniseSpeakers: () -> Bool = { ConfigStore.shared.config.meetings.recogniseSpeakers }
    var speakerModelsReady: () -> Bool = { MainActor.assumeIsolated { SpeakerModels.shared.isReady } }
    var meetingConfig: () -> Config.Meetings = { ConfigStore.shared.config.meetings }
    /// Runs the summary agent on a transcript and returns its answer. Tests replace it.
    var summarize: @MainActor (_ transcript: String, _ config: Config.Meetings, _ folder: URL) async throws -> String = MeetingSummaryRun.run
    /// Called after the files were replaced.
    var onReplaced: ((MeetingReplacement) -> Void)?

    /// Why the Regenerate button is disabled for this meeting, or nil when it can run. `activeFolder` is the meeting
    /// being recorded or summarised right now.
    func unavailableReason(for meeting: MeetingRecord, activeFolder: URL?, requiresAudio: Bool = true) -> String? {
        if let activeFolder, activeFolder.standardizedFileURL.path == meeting.folder.standardizedFileURL.path {
            return "This meeting is still being recorded or summarised."
        }
        if let activeID { return activeID == meeting.id ? "This meeting is being regenerated." : "Another meeting is being regenerated." }
        if requiresAudio, !meeting.hasAudio { return "This meeting has no saved audio to transcribe again." }
        return nil
    }

    /// Rebuilds the meeting. Returns false, with the reason in `errors`, when it could not start or failed.
    @discardableResult
    func regenerate(_ meeting: MeetingRecord, mode: RegenerationMode, activeFolder: URL? = nil) async -> Bool {
        if let reason = unavailableReason(for: meeting, activeFolder: activeFolder, requiresAudio: mode == .full) {
            errors[meeting.id] = reason
            return false
        }
        activeID = meeting.id
        errors[meeting.id] = nil
        progress = RegenerationProgress(stage: .reading)
        defer {
            activeID = nil
            progress = nil
            completed += 1
        }
        do {
            let replacement = try await rebuild(meeting, mode: mode)
            onReplaced?(replacement)
            return true
        } catch {
            errors[meeting.id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// For the preview renderer: shows a run in progress without doing any work.
    func loadPreview(active meeting: String, _ stage: RegenerationProgress.Stage) {
        activeID = meeting
        progress = RegenerationProgress(stage: stage)
    }

    func clearPreview() {
        activeID = nil
        progress = nil
    }

    private func rebuild(_ meeting: MeetingRecord, mode: RegenerationMode) async throws -> MeetingReplacement {
        let folder = meeting.folder
        let previous = try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
        var transcript: String?
        let text: String
        switch mode {
        case .full:
            MeetingController.KeyCache.forget()
            let found = try await Self.scan(folder)
            let lines = try await transcribe(found.chunks)
            guard !lines.isEmpty else { throw RegenerationError(message: "The new transcript has no speech in it, so nothing was replaced.") }
            text = MeetingTranscript.render(startedAt: found.startedAt, appName: found.appName, lines: lines)
            transcript = text
        case .summaryOnly:
            guard let existing = try? String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8),
                  !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RegenerationError(message: "This meeting has no transcript to summarise.")
            }
            text = existing
        }
        progress = RegenerationProgress(stage: .summarising)
        let answer = try await summarize(text, meetingConfig(), folder).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw RegenerationError(message: "The agent returned no text, so nothing was replaced.") }
        var summary = answer + "\n"
        if let previous { summary = ActionItems.carryChecked(from: previous, into: summary) }
        try Self.replace(in: folder, transcript: transcript, summary: summary)
        return MeetingReplacement(folder: folder, mode: mode, previousSummary: previous, summary: summary)
    }

    /// Transcribes the chunks in meeting order, and when speaker recognition is on, names the voices on the Them track.
    private func transcribe(_ chunks: [ChunkInfo]) async throws -> [MeetingLine] {
        let work = chunks.filter { !$0.silent }
        let diarize = recogniseSpeakers() && speakerModelsReady()
        var table = MeetingSpeakerTable()
        var lines: [MeetingLine] = []
        for (number, chunk) in work.enumerated() {
            progress = RegenerationProgress(stage: .transcribing(chunk: number + 1, of: work.count))
            let splitter: SpeakerDiarizing? = chunk.track == .them && diarize ? diarizer : nil
            let segments: [TimedSegment]
            let speakers: ChunkDiarization?
            do {
                (segments, speakers) = try await Self.transcribe(chunk, make: makeTranscriber, diarizer: splitter)
            } catch {
                throw RegenerationError(message: "Could not transcribe \(chunk.url.lastPathComponent): "
                    + "\(error.localizedDescription) The transcript and summary are unchanged.")
            }
            var turns: [SpeakerTurn] = []
            if let speakers {
                let ids = table.link(speakers, chunkURL: chunk.url, store: voiceStore.candidates)
                for speaker in speakers.speakers {
                    guard let id = ids[speaker.localId] else { continue }
                    turns += speaker.turns.map { SpeakerTurn(speakerId: id, start: $0.lowerBound, end: $0.upperBound) }
                }
            }
            lines += MeetingTranscript.lines(from: segments, track: chunk.track, offset: chunk.offset, turns: turns)
        }
        if !table.speakers.isEmpty {
            // The same last pass a live meeting makes: a voice recognised late is named in the early chunks too.
            let remap = table.relink(store: voiceStore.candidates)
            for index in lines.indices {
                if let id = lines[index].speakerId, let to = remap[id] { lines[index].speakerId = to }
                if let id = lines[index].speakerId, let speaker = table.speaker(id) { lines[index].speaker = speaker.displayName }
            }
        }
        return lines
    }

    private nonisolated static func scan(_ folder: URL) async throws -> MeetingFolderScan.Result {
        try MeetingFolderScan.scan(folder)
    }

    /// A diarization failure is not a transcription failure: the lines stay "Them", as in a live meeting.
    private nonisolated static func transcribe(_ chunk: ChunkInfo, make: () -> Transcriber,
                                               diarizer: SpeakerDiarizing?) async throws -> ([TimedSegment], ChunkDiarization?) {
        let transcriber = make()
        let segments = try await transcriber.transcribeSegments(wav: try Data(contentsOf: chunk.url))
        let speakers = diarizer == nil ? nil : try? await diarizer?.diarize(wav: chunk.url)
        return (segments, speakers)
    }

    /// Writes the new files next to the old ones, then swaps. When a swap fails, the ones already made are undone.
    nonisolated static func replace(in folder: URL, transcript: String?, summary: String,
                                    move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        let fm = FileManager.default
        var parts: [(name: String, text: String)] = [("summary", summary)]
        if let transcript { parts.insert(("transcript", transcript), at: 0) }
        func url(_ name: String, _ suffix: String) -> URL { folder.appendingPathComponent("\(name)\(suffix).md") }
        do {
            for part in parts { try part.text.write(to: url(part.name, ".new"), atomically: true, encoding: .utf8) }
        } catch {
            for part in parts { try? fm.removeItem(at: url(part.name, ".new")) }
            throw error
        }
        var swapped: [(name: String, hadOld: Bool)] = []
        do {
            for part in parts {
                let hadOld = fm.fileExists(atPath: url(part.name, "").path)
                if hadOld {
                    try? fm.removeItem(at: url(part.name, ".prev"))
                    try move(url(part.name, ""), url(part.name, ".prev"))
                }
                swapped.append((part.name, hadOld))
                try move(url(part.name, ".new"), url(part.name, ""))
            }
        } catch {
            for done in swapped.reversed() {
                try? fm.removeItem(at: url(done.name, ""))
                if done.hadOld { try? move(url(done.name, ".prev"), url(done.name, "")) }
            }
            for part in parts { try? fm.removeItem(at: url(part.name, ".new")) }
            throw RegenerationError(message: "Could not replace the files: \(error.localizedDescription) The old ones were put back.")
        }
    }
}

/// Runs the summary agent once, the way `MeetingController.summarize` does: read-only, every permission refused.
@MainActor
enum MeetingSummaryRun {
    static func run(transcript: String, config: Config.Meetings, folder: URL) async throws -> String {
        guard let agent = AgentCatalog.agent(id: config.summaryAgent) else {
            throw RegenerationError(message: "The summary agent \"\(config.summaryAgent)\" is not available. Pick another in Settings → Meetings.")
        }
        let runner = MeetingController.makeSummaryRunner(agent)
        let turn = ACPTurn(prompt: MeetingController.summaryPrompt(transcript: transcript), preamble: nil, workspace: folder,
                           resume: nil, model: config.summaryModel, images: [], files: [])
        var tasks: [Task<Void, Never>] = []
        defer {
            tasks.forEach { $0.cancel() }
            runner.cancel()
            runner.shutdown()
        }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = Gate(continuation)
            var answer = ""
            tasks.append(Task {
                await runner.runTurn(turn) { event in
                    switch event {
                    case .assistant(let chunk): answer += chunk
                    case .finished(let error):
                        gate.finish(error.map { .failure(RegenerationError(message: $0)) } ?? .success(answer))
                    case .needsSignIn:
                        gate.finish(.failure(RegenerationError(message: "\(agent.name) needs you to sign in. Open it in the chat once, then try again.")))
                    case .needsRuntime:
                        gate.finish(.failure(RegenerationError(message: "\(agent.name) needs Node 22 or Bun. Open it in the chat once to set that up.")))
                    default: break
                    }
                }
            })
            tasks.append(Task {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { return }
                gate.finish(.failure(RegenerationError(message: "The agent did not answer within 10 minutes.")))
            })
        }
    }

    /// Resumes the continuation once, whichever of the answer, an error or the timeout comes first.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Error>?

        init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }

        func finish(_ result: Result<String, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }
}
