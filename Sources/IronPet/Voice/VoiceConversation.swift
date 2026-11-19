import Foundation

/// Speaks a line and returns when it has been heard. `SpeechPlayer` is the real one.
@MainActor
protocol ConversationSpeaker: AnyObject {
    /// Throws `CancellationError` when `stop()` cut it short, or what the speech server answered.
    func say(_ text: String) async throws
    func stop()
}

extension SpeechPlayer: ConversationSpeaker {}

/// Voice mode: a spoken back-and-forth with the pet. Listening, then transcribing what was said, thinking (the front
/// desk's turn), speaking the reply, and listening again, until the user says goodbye, presses the shortcut or Esc,
/// or says nothing for `silenceSeconds`. Talking over the pet cuts it off. With Wispr Flow, its dictation arrives as
/// text and there is no microphone of ironpet's own.
@MainActor
final class VoiceConversation: ObservableObject {
    enum State: String { case idle, listening, transcribing, thinking, speaking }
    enum Mode: String { case microphone, wispr }

    @Published private(set) var state: State = .idle
    @Published private(set) var mode: Mode = .microphone
    /// The last thing the user said, and the pet's last reply, for the pill.
    @Published private(set) var heard: String?
    @Published private(set) var reply: String?

    var isEnabled: () -> Bool = { ConfigStore.shared.config.voiceMode.enabled }
    var listenMode: () -> Mode = {
        ConfigStore.shared.config.voiceMode.listenWith == Config.VoiceMode.wispr ? .wispr : .microphone
    }
    var silenceSeconds: () -> TimeInterval = { TimeInterval(ConfigStore.shared.config.voiceMode.silenceSeconds) }
    /// Why the pet must not listen right now ("a call", "a meeting recording"), or nil.
    var quietReason: () -> String? = { nil }
    var microphoneAllowed: () async -> Bool = { await VoiceController.microphoneAllowed() }
    var makeMic: () -> ConversationListening = { ConversationMic() }
    var transcribe: (Data) async throws -> String = { wav in
        let voice = ConfigStore.shared.config.voice
        return try await Transcriber(baseURL: voice.baseUrl, model: voice.model, apiKey: VoiceKey.load(), timeout: 30,
                                     usageFeature: .voiceTranscription).transcribe(wav: wav)
    }
    /// The voice for the conversation: through the microphone's engine when there is one, so echo cancellation can hear it.
    var makeSpeaker: (ConversationListening?) -> ConversationSpeaker = { mic in
        let player = SpeechPlayer(player: mic?.player)
        player.isEnabled = { true }
        return player
    }
    /// Stops the voice job still waiting out its hold, for "cancel that".
    var cancelHeldJob: () -> Job? = { nil }
    /// The pet has finished saying its reply, or the conversation ended: held voice jobs may count down.
    var releaseHeldJobs: () -> Void = {}
    var onStarted: (Mode) -> Void = { _ in }
    var onEnded: () -> Void = {}
    /// Something went wrong that the user should see in a bubble.
    var onFailure: (String) -> Void = { _ in }
    /// A filler line is spoken when the reply has not started this long after the user stopped talking.
    var fillerDelay: TimeInterval = 1.2
    var quietCheckInterval: TimeInterval = 2

    static let fillers = ["One sec, checking.", "Let me look.", "One moment."]

    let frontDesk: FrontDeskTalking
    private(set) var mic: ConversationListening?
    private var speaker: ConversationSpeaker?
    private var work: Task<Void, Never>?
    private var silence: Task<Void, Never>?
    private var quietWatch: Task<Void, Never>?
    private var queuedAudio: [Data] = []
    private var announcements: [String] = []
    /// Bumped by every interruption and by the end, so work that was overtaken drops its result.
    private var generation = 0
    private var starting = false
    private var endRequested = false
    /// The microphone heard speech start and has not cut it yet; job updates wait.
    private var userSpeaking = false
    private let idleLevels = LevelBuffer()

    init(frontDesk: FrontDeskTalking) {
        self.frontDesk = frontDesk
    }

    var isActive: Bool { state != .idle || starting }
    var levels: LevelBuffer { mic?.levels ?? idleLevels }

    var mood: PetMood? {
        switch state {
        case .idle: return nil
        case .listening, .speaking: return .listening
        case .transcribing, .thinking: return .working
        }
    }

    /// The voice-mode shortcut: starts a conversation, or ends the one in progress.
    func toggle() {
        isActive ? end() : start()
    }

    func start() {
        guard !isActive, isEnabled() else { return }
        if let reason = quietReason() { return onFailure("Voice mode doesn't listen during \(reason).") }
        let mode = listenMode()
        starting = true
        endRequested = false
        Task { [weak self] in
            guard let self else { return }
            defer { starting = false }
            var mic: ConversationListening?
            if mode == .microphone {
                guard await microphoneAllowed() else {
                    return onFailure("ironpet can't use the microphone. Allow it under System Settings → Privacy & Security → Microphone, then try again.")
                }
                guard !endRequested, isEnabled() else { return }
                let opened = makeMic()
                opened.onEvent = { [weak self] event in self?.micEvent(event) }
                do {
                    try opened.start()
                } catch {
                    return onFailure("Could not open the microphone: \(error.localizedDescription)")
                }
                mic = opened
            }
            guard !endRequested else { mic?.stop(); return }
            self.mic = mic
            self.mode = mode
            speaker = makeSpeaker(mic)
            heard = nil
            reply = nil
            frontDesk.prepare()
            state = .listening
            armSilence()
            watchQuiet()
            onStarted(mode)
        }
    }

    func end() {
        if starting { endRequested = true }
        guard state != .idle else { return }
        generation += 1
        work?.cancel()
        work = nil
        silence?.cancel()
        quietWatch?.cancel()
        if state == .thinking { frontDesk.cancel() }
        speaker?.stop()
        speaker = nil
        mic?.stop()
        mic = nil
        queuedAudio = []
        announcements = []
        userSpeaking = false
        state = .idle
        releaseHeldJobs()
        frontDesk.finish()
        onEnded()
    }

    /// Text from Wispr Flow, sent the moment it lands.
    func receive(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state != .idle, !text.isEmpty else { return }
        silence?.cancel()
        if state == .thinking || state == .speaking { interrupt() }
        let current = generation
        work = Task { await respond(to: text, generation: current) }
    }

    /// Says a job update. Returns false when no conversation is running; the caller speaks it some other way. During a
    /// reply it waits until the pet is listening again.
    @discardableResult
    func announce(_ text: String) -> Bool {
        guard state != .idle else { return false }
        if state == .listening, work == nil, !userSpeaking {
            silence?.cancel()
            let current = generation
            work = Task { await speak(text, generation: current) }
        } else {
            announcements.append(text)
        }
        return true
    }

    /// Shows a state for preview renders. Nothing listens or runs.
    func loadPreview(state: State, mode: Mode, heard: String?) {
        self.state = state
        self.mode = mode
        self.heard = heard
    }

    /// `--test-mode`: an utterance as if the microphone had just cut it.
    func hear(_ audio: Data) {
        micEvent(.speechStarted)
        micEvent(.utterance(audio))
    }

    // MARK: Listening

    private func micEvent(_ event: ConversationMic.Event) {
        guard state != .idle else { return }
        switch event {
        case .speechStarted:
            userSpeaking = true
            silence?.cancel()
            if state == .thinking || state == .speaking { interrupt() }
        case .utterance(let wav):
            userSpeaking = false
            heardAudio(wav)
        case .discarded:
            userSpeaking = false
            if state == .listening, work == nil { listenAgain() }
        case .failed(let message):
            onFailure(message)
            end()
        }
    }

    /// Talking over the pet: the reply in progress and its voice stop, and the pet listens.
    private func interrupt() {
        generation += 1
        work?.cancel()
        work = nil
        if state == .thinking { frontDesk.cancel() }
        speaker?.stop()
        mic?.setPlayback(false)
        state = .listening
    }

    private func heardAudio(_ wav: Data) {
        if state == .transcribing { return queuedAudio.append(wav) }
        guard state == .listening else { return }
        state = .transcribing
        let current = generation
        work = Task {
            var parts: [String] = []
            var audio = [wav]
            while !audio.isEmpty {
                do {
                    let text = try await transcribe(audio.removeFirst())
                    if !text.isEmpty { parts.append(text) }
                } catch is CancellationError {
                    return
                } catch {
                    guard current == generation else { return }
                    return await speak("Sorry, I couldn't make that out. \(error.localizedDescription)", generation: current)
                }
                guard current == generation else { return }
                audio += queuedAudio
                queuedAudio = []
            }
            let text = parts.joined(separator: " ")
            guard !text.isEmpty else { return listenAgain() }
            await respond(to: text, generation: current)
        }
    }

    // MARK: Replying

    private func respond(to text: String, generation current: Int) async {
        heard = text
        if Self.isCancel(text), let job = cancelHeldJob() {
            return await speak("Okay, I cancelled \(job.title).", generation: current)
        }
        if Self.isGoodbye(text) {
            await speak("Talk soon.", generation: current)
            if current == generation { end() }
            return
        }
        state = .thinking
        let filler = Task { [weak self, fillerDelay] in
            try? await Task.sleep(for: .seconds(fillerDelay))
            guard let self, !Task.isCancelled, state == .thinking, current == generation else { return }
            mic?.setPlayback(true)
            try? await speaker?.say(Self.fillers.randomElement() ?? "One sec.")
            mic?.setPlayback(false)
        }
        do {
            let answer = try await frontDesk.reply(to: text)
            filler.cancel()
            await filler.value
            guard current == generation else { return }
            reply = answer
            await speak(answer.isEmpty ? "Done." : answer, generation: current)
        } catch {
            filler.cancel()
            await filler.value
            guard current == generation, !(error is CancellationError) else { return }
            await speak("Sorry, that didn't work. \(error.localizedDescription)", generation: current)
        }
    }

    private func speak(_ text: String, generation current: Int) async {
        guard current == generation else { return }
        state = .speaking
        mic?.setPlayback(true)
        do {
            try await speaker?.say(text)
        } catch is CancellationError {
        } catch {
            onFailure("The voice server could not speak: \(error.localizedDescription)")
        }
        guard current == generation else { return }
        mic?.setPlayback(false)
        releaseHeldJobs()
        listenAgain()
    }

    /// Back to listening, with any job update that came in meanwhile said first, unless the user is talking.
    private func listenAgain() {
        work = nil
        state = .listening
        guard !userSpeaking else { return }
        guard announcements.isEmpty else {
            let text = announcements.removeFirst()
            let current = generation
            work = Task { await speak(text, generation: current) }
            return
        }
        armSilence()
    }

    private func armSilence() {
        silence?.cancel()
        let seconds = silenceSeconds()
        silence = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, state == .listening, work == nil, !userSpeaking else { return }
            end()
        }
    }

    /// Ends the conversation when a call or a meeting recording starts.
    private func watchQuiet() {
        quietWatch?.cancel()
        let interval = quietCheckInterval
        quietWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled, state != .idle else { return }
                if let reason = quietReason() {
                    onFailure("Voice mode stopped: \(reason) started.")
                    return end()
                }
            }
        }
    }

    // MARK: Phrases

    private nonisolated static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "'" }
            .split(separator: " ").joined(separator: " ")
    }

    /// "Cancel that", "no, wait", "never mind": said right after a job was started, it stops that job.
    nonisolated static func isCancel(_ text: String) -> Bool {
        let said = normalized(text)
        let phrases = ["cancel that", "cancel it", "no wait", "wait no", "never mind", "nevermind", "stop that", "scratch that",
                       "don't do that", "dont do that"]
        return phrases.contains { said == $0 || said.hasPrefix($0 + " ") }
    }

    /// Ends the conversation: only a short sign-off on its own, so "bye" inside a request does not.
    nonisolated static func isGoodbye(_ text: String) -> Bool {
        let said = normalized(text)
        let phrases = ["bye", "bye bye", "goodbye", "good bye", "thats all", "that's all", "that's it", "thats it", "thanks that's all",
                       "thank you that's all", "stop listening", "see you", "talk later", "talk to you later", "that's all for now"]
        return phrases.contains(said)
    }
}
