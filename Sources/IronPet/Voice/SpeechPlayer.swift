import AVFoundation
import Foundation

/// Where audio goes: the local speaker (`ClipPlayer`), or a test. It plays one clip at a time. A client that is not this
/// Mac takes the chunks from `SpeechProducer` and plays them itself.
@MainActor
protocol ClipPlaying: AnyObject {
    /// Returns when the clip ended; throws `CancellationError` when `stop()` cut it short.
    func play(_ audio: Data) async throws
    func stop()
}

/// Turns text into audio chunks and plays nothing. The first chunk is one sentence so audio starts early, and the next chunk is
/// synthesized while the caller handles the current one.
struct SpeechProducer {
    var synthesize: (String) async throws -> Data

    /// The prose of a markdown reply, in the chunks that are synthesized one by one.
    func chunks(of markdown: String) -> [String] { SpeechText.chunks(of: markdown) }

    /// Reads `chunks` in order. Call `next()` for each audio chunk, and `cancel()` to drop the one being prepared.
    @MainActor
    func reader(for chunks: [String]) -> SpeechChunkReader { SpeechChunkReader(chunks: chunks, synthesize: synthesize) }
}

/// One pass over a reply's chunks, always one chunk ahead of the caller.
@MainActor
final class SpeechChunkReader {
    private let chunks: [String]
    private let synthesize: (String) async throws -> Data
    private var index = 0
    private var prefetch: Task<Data, Error>?

    init(chunks: [String], synthesize: @escaping (String) async throws -> Data) {
        self.chunks = chunks
        self.synthesize = synthesize
        prefetch = chunks.first.map { first in Task { try await synthesize(first) } }
    }

    /// The next audio chunk, or nil at the end. Throws what the server answered, or `CancellationError` after `cancel()`.
    func next() async throws -> Data? {
        guard let pending = prefetch else { return nil }
        let audio = try await pending.value
        try Task.checkCancellation()
        index += 1
        let synthesize = synthesize
        prefetch = index < chunks.count ? Task { [text = chunks[index]] in try await synthesize(text) } : nil
        return audio
    }

    func cancel() {
        prefetch?.cancel()
        prefetch = nil
    }
}

/// Reads replies aloud: synthesizes the first chunk, plays it while the next one is synthesized, and so on, so
/// speech starts after one sentence instead of after the whole reply.
@MainActor
final class SpeechPlayer: ObservableObject {
    enum Phase: String { case idle, preparing, playing }

    @Published private(set) var phase: Phase = .idle
    /// The chat item being read, so its speaker button shows Stop.
    @Published private(set) var speakingID: UUID?
    /// A failed request, shown in the chat. Not called for a stop.
    var onFailure: ((String) -> Void)?

    var isEnabled: () -> Bool = { ConfigStore.shared.config.speech.enabled }
    var synthesize: (String) async throws -> Data = { try await SpeechPlayer.synthesizer().speak($0) }
    private let player: ClipPlaying
    private var reading: Task<Void, Never>?
    private var previewing: Task<Void, Error>?
    private var reader: SpeechChunkReader?

    init(player: ClipPlaying? = nil) {
        self.player = player ?? ClipPlayer()
    }

    /// The synthesizer for the saved settings: the voice server's URL and key with the speech model and voice.
    static func synthesizer(model: String? = nil, voice: String? = nil) -> Synthesizer {
        let config = ConfigStore.shared.config
        return Synthesizer(baseURL: config.voice.baseUrl, model: model ?? config.speech.model,
                           voice: voice ?? config.speech.voice, speed: config.speech.speed, apiKey: VoiceKey.load())
    }

    var isSpeaking: Bool { speakingID != nil }

    /// Reads a reply's prose. Does nothing with spoken replies off or when the reply has no prose.
    func speak(_ markdown: String, id: UUID) {
        stop()
        guard isEnabled() else { return }
        let chunks = SpeechProducer(synthesize: synthesize).chunks(of: markdown)
        guard !chunks.isEmpty else { return }
        speakingID = id
        phase = .preparing
        reading = Task { [weak self] in
            await self?.read(chunks)
            // A stopped read must not clear the state of the reply that replaced it.
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    /// Speaks one short line regardless of the switch, for Settings' Preview. Throws what the server answered, or
    /// `CancellationError` when `stop()` or a reply cut it short.
    func preview(_ text: String, using synthesizer: Synthesizer) async throws {
        stop()
        phase = .preparing
        let player = player
        let task = Task { [weak self] in
            let audio = try await synthesizer.speak(text)
            try Task.checkCancellation()
            self?.phase = .playing
            try await player.play(audio)
        }
        previewing = task
        defer {
            // A reply that started meanwhile owns the phase now.
            if speakingID == nil { phase = .idle }
        }
        try await task.value
    }

    /// Shows a reply as being read, for preview renders. Nothing plays.
    func loadPreview(speaking id: UUID) {
        speakingID = id
        phase = .playing
    }

    func stop() {
        previewing?.cancel()
        previewing = nil
        reading?.cancel()
        reading = nil
        reader?.cancel()
        reader = nil
        player.stop()
        finish()
    }

    private func read(_ chunks: [String]) async {
        let reader = SpeechProducer(synthesize: synthesize).reader(for: chunks)
        self.reader = reader
        while true {
            do {
                guard !Task.isCancelled, let audio = try await reader.next() else { return }
                phase = .playing
                try await player.play(audio)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                onFailure?(error.localizedDescription)
                return
            }
        }
    }

    private func finish() {
        reader?.cancel()
        reader = nil
        speakingID = nil
        phase = .idle
    }
}

/// `AVAudioPlayer` behind `ClipPlaying`. The player is kept until it ends, since it stops when released.
@MainActor
final class ClipPlayer: NSObject, ClipPlaying, AVAudioPlayerDelegate {
    private var current: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Error>?

    func play(_ audio: Data) async throws {
        stop()
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: audio)
        } catch {
            throw SpeechError.noAudio
        }
        player.delegate = self
        current = player
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            if !player.play() { end(player, throwing: SpeechError.noAudio) }
        }
    }

    func stop() {
        guard let current else { return }
        current.stop()
        end(current, throwing: CancellationError())
    }

    private func end(_ player: AVAudioPlayer, throwing error: Error?) {
        guard player === current else { return }
        current = nil
        let continuation = continuation
        self.continuation = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.end(player, throwing: nil) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.end(player, throwing: SpeechError.noAudio) }
    }
}
