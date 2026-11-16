import FluidAudio
import Foundation

/// One speaker found inside a single chunk. The ids are local to the chunk: "1" in one chunk and "1" in the next
/// are unrelated until `MeetingSpeakerTable` links them by voice.
struct ChunkSpeaker: Equatable {
    var localId: String
    /// One embedding for the whole speaker, the duration-weighted mean over their segments.
    var embedding: [Float]
    /// Seconds from the start of the chunk.
    var turns: [ClosedRange<TimeInterval>]

    var seconds: TimeInterval { turns.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
    var longestTurn: ClosedRange<TimeInterval>? { turns.max { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound } }
}

struct ChunkDiarization: Equatable {
    var speakers: [ChunkSpeaker]
}

protocol SpeakerDiarizing: Sendable {
    /// Splits a chunk's WAV into speakers. Throws when the models are missing or the audio cannot be read.
    func diarize(wav: URL) async throws -> ChunkDiarization
}

/// FluidAudio's offline pipeline (a Core ML port of pyannote community-1 with WeSpeaker embeddings). The manager is
/// created on first use and kept, because loading the models costs more than diarizing a chunk.
actor FluidDiarizer: SpeakerDiarizing {
    private var manager: OfflineDiarizerManager?

    func diarize(wav: URL) async throws -> ChunkDiarization {
        let manager = try await loadedManager()
        let result = try await manager.process(wav)
        return Self.group(result.segments.map {
            (speaker: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds), embedding: $0.embedding)
        })
    }

    private func loadedManager() async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        let fresh = OfflineDiarizerManager()
        // Loads from the cache the Settings toggle filled. `SpeakerModels.isReady` is checked before a meeting calls this.
        try await fresh.prepareModels()
        manager = fresh
        return fresh
    }

    /// Groups FluidAudio's segments by speaker. Exposed for tests.
    nonisolated static func group(_ segments: [(speaker: String, start: TimeInterval, end: TimeInterval, embedding: [Float])]) -> ChunkDiarization {
        var order: [String] = []
        var turns: [String: [ClosedRange<TimeInterval>]] = [:]
        var sums: [String: [Float]] = [:]
        var weights: [String: Float] = [:]
        for segment in segments where segment.end > segment.start {
            let length = Float(segment.end - segment.start)
            if turns[segment.speaker] == nil { order.append(segment.speaker) }
            turns[segment.speaker, default: []].append(segment.start...segment.end)
            guard !segment.embedding.isEmpty else { continue }
            var sum = sums[segment.speaker] ?? [Float](repeating: 0, count: segment.embedding.count)
            guard sum.count == segment.embedding.count else { continue }
            for index in sum.indices { sum[index] += segment.embedding[index] * length }
            sums[segment.speaker] = sum
            weights[segment.speaker, default: 0] += length
        }
        let speakers = order.map { id in
            ChunkSpeaker(localId: id, embedding: SpeakerMatcher.normalized(sums[id] ?? []), turns: turns[id] ?? [])
        }
        return ChunkDiarization(speakers: speakers)
    }
}

/// The diarization models (about 21 MB once compiled). They download only when the Settings toggle is first turned on,
/// never when a meeting starts, and a meeting that finds them missing runs as it did before.
@MainActor
final class SpeakerModels: ObservableObject {
    enum State: Equatable {
        case notDownloaded
        case downloading(fraction: Double)
        case ready
        case failed(String)
    }

    static let shared = SpeakerModels()
    static let readyKey = "speakerModelsReady"

    @Published private(set) var state: State
    /// Downloads and compiles the models, reporting progress from 0 to 1. Tests replace it.
    var download: (@escaping @Sendable (Double) -> Void) async throws -> Void
    /// True when the model files are on disk. Tests replace it.
    var cachePresent: () -> Bool
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private(set) var downloadCount = 0

    init(defaults: UserDefaults = .standard,
         cachePresent: @escaping () -> Bool = SpeakerModels.defaultCachePresent,
         download: @escaping (@escaping @Sendable (Double) -> Void) async throws -> Void = SpeakerModels.fluidDownload) {
        self.defaults = defaults
        self.cachePresent = cachePresent
        self.download = download
        state = defaults.bool(forKey: Self.readyKey) && cachePresent() ? .ready : .notDownloaded
    }

    /// Whether a meeting may diarize right now. Cheap, so it can run per chunk.
    var isReady: Bool { state == .ready && cachePresent() }

    /// Starts the download unless the models are ready or already downloading.
    func prepare() {
        switch state {
        case .ready, .downloading: return
        case .notDownloaded, .failed: break
        }
        state = .downloading(fraction: 0)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                downloadCount += 1
                try await download { fraction in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.state { self?.state = .downloading(fraction: min(1, max(0, fraction))) }
                    }
                }
                defaults.set(true, forKey: Self.readyKey)
                state = .ready
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Waits for a running download. For tests.
    func waitUntilSettled() async { await task?.value }

    nonisolated static func fluidDownload(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await OfflineDiarizerModels.load(progressHandler: { progress($0.fractionCompleted) })
    }

    /// FluidAudio keeps each model repo in `Application Support/FluidAudio/Models/<repo folder>`.
    nonisolated static func defaultCachePresent() -> Bool {
        let repo = OfflineDiarizerModels.defaultModelsDirectory().appendingPathComponent(Repo.diarizer.folderName)
        return ModelNames.OfflineDiarizer.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: repo.appendingPathComponent($0).path)
        }
    }
}
