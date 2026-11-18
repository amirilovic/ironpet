import AVFoundation
import Foundation

/// Plays one clip at a time. A protocol so tests can play without a sound device.
@MainActor
protocol ClipPlaying: AnyObject {
    /// Returns when the clip ended; throws `CancellationError` when `stop()` cut it short.
    func play(_ audio: Data) async throws
    func stop()
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
    private var prefetch: Task<Data, Error>?

    init(player: ClipPlaying? = nil) {
        self.player = player ?? ClipPlayer()
    }

    /// The synthesizer for the saved settings: the voice server's URL and key with the speech model and voice.
    static func synthesizer(model: String? = nil, voice: String? = nil) -> Synthesizer {
        let config = ConfigStore.shared.config
        return Synthesizer(baseURL: config.voice.baseUrl, model: model ?? config.speech.model,
                           voice: voice ?? config.speech.voice, apiKey: VoiceKey.load())
    }

    var isSpeaking: Bool { speakingID != nil }

    /// Reads a reply's prose. Does nothing with spoken replies off or when the reply has no prose.
    func speak(_ markdown: String, id: UUID) {
        stop()
        guard isEnabled() else { return }
        let chunks = SpeechText.chunks(of: markdown)
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

    /// Speaks one short line regardless of the switch, for Settings' Preview. Throws what the server answered.
    func preview(_ text: String, using synthesizer: Synthesizer) async throws {
        stop()
        phase = .preparing
        defer { phase = .idle }
        let audio = try await synthesizer.speak(text)
        phase = .playing
        try await player.play(audio)
    }

    /// Shows a reply as being read, for preview renders. Nothing plays.
    func loadPreview(speaking id: UUID) {
        speakingID = id
        phase = .playing
    }

    func stop() {
        reading?.cancel()
        reading = nil
        prefetch?.cancel()
        prefetch = nil
        player.stop()
        finish()
    }

    private func read(_ chunks: [String]) async {
        let synthesize = synthesize
        prefetch = Task { try await synthesize(chunks[0]) }
        for index in chunks.indices {
            guard let pending = prefetch, !Task.isCancelled else { return }
            do {
                let audio = try await pending.value
                try Task.checkCancellation()
                prefetch = index + 1 < chunks.count ? Task { [next = chunks[index + 1]] in try await synthesize(next) } : nil
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
        prefetch?.cancel()
        prefetch = nil
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
