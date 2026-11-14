import AVFoundation
import Foundation

/// The state machine behind voice notes: idle, recording, transcribing. The chat UI, the hotkey and the test
/// endpoints all drive this one object, so they show the same states.
@MainActor
final class VoiceController: ObservableObject {
    enum Phase: String { case idle, recording, transcribing }
    enum Source {
        case microphone
        case file(URL)
    }

    /// A voice note is cut off here instead of being split into several uploads (OpenAI accepts 25 MB).
    static let maxDuration: TimeInterval = 300
    /// Shorter recordings are treated as an accidental tap and dropped.
    static let minDuration: TimeInterval = 0.3

    @Published private(set) var phase: Phase = .idle
    let levels = LevelBuffer()
    private(set) var startedAt: Date?
    /// The last recording, kept while its transcription has failed so Retry can re-send it.
    private(set) var retryAudio: Data?

    var onTranscript: ((String) -> Void)?
    /// A message for the chat, and whether Retry makes sense for it.
    var onFailure: ((String, Bool) -> Void)?
    var makeTranscriber: () -> Transcriber = {
        let voice = ConfigStore.shared.config.voice
        return Transcriber(baseURL: voice.baseUrl, model: voice.model, apiKey: VoiceKey.load())
    }
    var isEnabled: () -> Bool = { ConfigStore.shared.config.voice.enabled }

    private var source: AudioSource?
    private var levelTimer: Timer?
    private var capTask: Task<Void, Never>?
    private var transcription: Task<Void, Never>?
    private var starting = false
    private var stopRequested = false

    /// The hold-to-talk shortcut to register: nil when voice notes are off or the shortcut is cleared.
    nonisolated static func hotkey(in config: Config) -> String? {
        guard config.voice.enabled, !config.hotkeys.voice.isEmpty else { return nil }
        return config.hotkeys.voice
    }

    var isBusy: Bool { phase != .idle || starting }

    /// Starts a recording. A first microphone use asks macOS for permission here and nowhere earlier.
    func start(_ kind: Source = .microphone) {
        guard isEnabled(), !isBusy else { return }
        starting = true
        stopRequested = false
        Task {
            if case .microphone = kind, !(await Self.microphoneAllowed()) {
                starting = false
                return onFailure?("ironpet can't use the microphone. Allow it under System Settings → Privacy & Security → Microphone, then try again.", false) ?? ()
            }
            // Voice notes may have been switched off while the permission prompt was up.
            guard isEnabled() else { starting = false; return }
            begin(kind)
        }
    }

    private func begin(_ kind: Source) {
        defer { starting = false }
        let source: AudioSource
        do {
            switch kind {
            case .microphone: source = MicrophoneSource()
            case .file(let url): source = try FileSource(url: url)
            }
            levels.reset()
            let levels = levels
            try source.start { levels.record($0) }
        } catch {
            return onFailure?("Could not start recording: \(error.localizedDescription)", false) ?? ()
        }
        self.source = source
        retryAudio = nil
        startedAt = Date()
        phase = .recording
        let timer = Timer(timeInterval: LevelBuffer.tickInterval, repeats: true) { [weak self] _ in
            self?.levels.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
        capTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxDuration))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
        // The key was let go while the permission prompt was up.
        if stopRequested { cancel() }
    }

    /// Ends the recording and sends it for transcription.
    func stop() {
        if starting { stopRequested = true }
        guard phase == .recording, let source else { return }
        let duration = Date().timeIntervalSince(startedAt ?? Date())
        endRecording()
        let wav = source.finish()
        guard duration >= Self.minDuration else {
            self.source = nil
            phase = .idle
            return
        }
        transcribe(wav)
    }

    /// Discards the recording, or abandons a transcription in flight. Nothing is sent.
    func cancel() {
        stopRequested = starting
        switch phase {
        case .recording:
            endRecording()
            source?.cancel()
            source = nil
            phase = .idle
        case .transcribing:
            transcription?.cancel()
            transcription = nil
            retryAudio = nil
            phase = .idle
        case .idle:
            break
        }
    }

    /// Sends the kept recording again.
    func retry() {
        guard phase == .idle, let audio = retryAudio else { return }
        transcribe(audio)
    }

    private func endRecording() {
        levelTimer?.invalidate()
        levelTimer = nil
        capTask?.cancel()
        capTask = nil
    }

    private func transcribe(_ wav: Data) {
        source = nil
        retryAudio = wav
        phase = .transcribing
        let transcriber = makeTranscriber()
        transcription = Task { [weak self] in
            do {
                let text = try await transcriber.transcribe(wav: wav)
                self?.finished(text)
            } catch is CancellationError {
                // cancel() already reset the state.
            } catch {
                self?.failed(error)
            }
        }
    }

    private func finished(_ text: String) {
        guard phase == .transcribing else { return }
        phase = .idle
        retryAudio = nil
        if text.isEmpty {
            onFailure?("No speech was recognised in the recording.", false)
        } else {
            onTranscript?(text)
        }
    }

    private func failed(_ error: Error) {
        guard phase == .transcribing else { return }
        phase = .idle
        onFailure?(error.localizedDescription, true)
    }

    static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
