import AppKit
import Carbon
import Combine

/// Voice mode in the app: the conversation, its pill by the pet, Esc to end it, Wispr Flow's dictation in Wispr mode,
/// and job updates said out loud for jobs started by voice.
@MainActor
final class VoiceModeController {
    let conversation: VoiceConversation
    let frontDesk: FrontDesk

    /// The pet's frame, to place the pill next to it.
    var petFrame: () -> CGRect = { .zero }
    /// Why the pet must not talk or listen now ("a call", "a meeting recording"), or nil.
    var quietReason: () -> String? = { nil }
    /// True while the user has been away from the Mac long enough that a spoken update would go unheard.
    var isAway: () -> Bool = { false }
    var isFromVoice: (String) -> Bool = { _ in false }
    /// The chat's own Wispr bridge pauses during a Wispr conversation, so one dictation is not sent twice.
    var pauseChatDictation: (Bool) -> Void = { _ in }
    var onStateChange: () -> Void = {}

    private lazy var pill = VoicePillPanel(conversation: conversation, petName: { ConfigStore.shared.config.pet.name },
                                           onEnd: { [weak self] in self?.conversation.end() })
    private let wispr = WisprBridge()
    private var escape: HotKey?
    private var previousApp: NSRunningApplication?
    private let updates: SpeechPlayer = {
        let player = SpeechPlayer()
        player.isEnabled = { true }
        return player
    }()
    /// The state each voice job was last seen in, so one change is said once.
    private var announced: [String: JobState] = [:]
    private var cancellables: Set<AnyCancellable> = []

    static let escapeHotKeyID: UInt32 = 11

    init(frontDesk: FrontDesk) {
        self.frontDesk = frontDesk
        conversation = VoiceConversation(frontDesk: frontDesk)
        conversation.quietReason = { [weak self] in self?.quietReason() }
        conversation.onStarted = { [weak self] mode in self?.started(mode) }
        conversation.onEnded = { [weak self] in self?.ended() }
        wispr.onDictation = { [weak self] text in self?.conversation.receive(text) }
        conversation.$state
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.onStateChange() } }
            .store(in: &cancellables)
    }

    /// The voice-mode shortcut to register: nil when voice mode is off or the shortcut is cleared.
    nonisolated static func hotkey(in config: Config) -> String? {
        guard config.voiceMode.enabled, !config.hotkeys.voiceMode.isEmpty else { return nil }
        return config.hotkeys.voiceMode
    }

    func toggle() {
        if !conversation.isActive {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        }
        conversation.toggle()
    }

    private func started(_ mode: VoiceConversation.Mode) {
        escape = HotKey(keyCode: kVK_Escape, modifiers: 0, id: Self.escapeHotKeyID) { [weak self] in
            MainActor.assumeIsolated { self?.conversation.end() }
        }
        if mode == .wispr {
            pauseChatDictation(true)
            wispr.start()
        }
        pill.present(near: petFrame(), focus: mode == .wispr)
    }

    private func ended() {
        escape = nil
        pill.dismiss()
        if conversation.mode == .wispr {
            wispr.stop()
            pauseChatDictation(false)
            if NSApp.isActive { previousApp?.activate() }
        }
        previousApp = nil
    }

    // MARK: Job updates

    /// A job changed. A job started by voice says when it is done, failed or needs an OK, unless the user is on a call,
    /// in a recorded meeting or away. Its bubble shows either way.
    func jobChanged(_ job: Job) {
        let settings = ConfigStore.shared.config.voiceMode
        guard isFromVoice(job.id) else { return }
        let previous = announced.updateValue(job.state, forKey: job.id)
        guard settings.enabled, settings.speakJobUpdates, [.done, .failed, .needsApproval].contains(job.state),
              previous != job.state, quietReason() == nil, !isAway(), let line = Self.update(for: job) else { return }
        if !conversation.announce(line) {
            let updates = updates
            Task { try? await updates.say(line) }
        }
    }

    nonisolated static func update(for job: Job) -> String? {
        switch job.state {
        case .done:
            return "\(job.title) is done." + (job.summary.map { " \($0)" } ?? "")
        case .failed:
            return "\(job.title) didn't work." + (job.error.flatMap { AgentSession.firstSentence($0) }.map { " \($0)" } ?? "")
        case .needsApproval:
            let what = job.waitingFor.map { " to \($0.prefix(1).lowercased() + $0.dropFirst())" } ?? ""
            return "\(job.title) needs your OK\(what). Click Allow in its bubble."
        default:
            return nil
        }
    }

    // MARK: Test mode

    /// `--test-mode`: no microphone and no speech server. Utterances come from `/test/voice-mode/utterance`, the pet's
    /// voice is a short pause, and the front desk answers with `reply` when one is set.
    func useTestDoubles(reply: String?) {
        conversation.makeMic = { SilentMic() }
        conversation.microphoneAllowed = { true }
        conversation.makeSpeaker = { _ in SilentSpeaker() }
        conversation.transcribe = { wav in String(decoding: wav, as: UTF8.self) }
        frontDesk.stubReply = reply
    }

    func testSnapshot() -> [String: Any] {
        ["ok": true, "state": conversation.state.rawValue, "mode": conversation.mode.rawValue,
         "heard": conversation.heard ?? "", "reply": conversation.reply ?? "", "pill": pill.panel.isVisible]
    }
}

/// The test-mode microphone: it hears nothing; `/test/voice-mode/utterance` speaks for the user.
@MainActor
final class SilentMic: ConversationListening {
    var onEvent: ((ConversationMic.Event) -> Void)?
    let levels = LevelBuffer()
    let player: ClipPlaying = SilentSpeaker()
    func start() throws {}
    func stop() {}
    func setPlayback(_ on: Bool) {}
}

/// The test-mode voice: a short pause per line instead of the speech server.
@MainActor
final class SilentSpeaker: ConversationSpeaker, ClipPlaying {
    private var waiting: Task<Void, Error>?

    func say(_ text: String) async throws {
        let task = Task { try await Task.sleep(for: .milliseconds(200)) }
        waiting = task
        try await task.value
    }

    func play(_ audio: Data) async throws { try await say("") }

    func stop() {
        waiting?.cancel()
        waiting = nil
    }
}
