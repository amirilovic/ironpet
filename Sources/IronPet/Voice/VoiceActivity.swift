import Foundation

/// Finds where speech starts and ends in the microphone's loudness, one frame at a time. Loudness is
/// `PCMConverter.level`: 0 at -50 dB and below, 1 at 0 dB. The start threshold sits above the room's noise floor, which
/// it follows while nobody speaks, so a fan or a busy café does not count as talking.
struct VoiceActivity {
    struct Tuning {
        /// Speech starts once the level stays above the start threshold this long.
        var startHold: TimeInterval = 0.12
        /// The lowest start threshold, about -32 dB.
        var minStartLevel: Float = 0.36
        /// How far above the noise floor speech must be to start.
        var startMargin: Float = 0.18
        /// Below this, relative to the start threshold, a frame counts as a pause.
        var endDrop: Float = 0.08
        /// An utterance ends after this much pause. Shorter pauses are a breath between words.
        var hangover: TimeInterval = 0.7
        /// Less voiced time than this is a cough or a click and is dropped.
        var minSpeech: TimeInterval = 0.3
        /// An utterance is cut here even if the talking goes on, so one upload stays small.
        var maxUtterance: TimeInterval = 30
        /// While the pet speaks, the user must be this loud, for this long, to interrupt. Echo cancellation leaves some
        /// of the pet's own voice in the signal, and it must not interrupt itself.
        var bargeInLevel: Float = 0.55
        var bargeInHold: TimeInterval = 0.25
    }

    enum Event: Equatable {
        case started
        /// The utterance ended; `voiced` is how long it was, without the closing pause.
        case ended(voiced: TimeInterval)
        /// Too short to be speech.
        case discarded
    }

    var tuning = Tuning()
    /// True while the pet's voice is playing, which raises the bar for speech to start.
    var playback = false
    private(set) var isSpeaking = false
    private(set) var noiseFloor: Float = 0.1
    private var above: TimeInterval = 0
    private var length: TimeInterval = 0
    private var pause: TimeInterval = 0

    var startLevel: Float {
        let normal = max(tuning.minStartLevel, noiseFloor + tuning.startMargin)
        return playback ? max(normal, tuning.bargeInLevel) : normal
    }

    /// Feeds one frame: its level and how long it lasts. Returns what changed, if anything.
    mutating func feed(level: Float, duration: TimeInterval) -> Event? {
        if isSpeaking { return continueSpeech(level: level, duration: duration) }
        if level >= startLevel {
            above += duration
            if above >= (playback ? tuning.bargeInHold : tuning.startHold) {
                isSpeaking = true
                length = above
                pause = 0
                above = 0
                return .started
            }
        } else {
            above = 0
            // A slow average that falls faster than it rises, so one loud moment does not lift the floor for long.
            let rate: Float = level < noiseFloor ? 0.05 : 0.005
            noiseFloor += (level - noiseFloor) * rate
        }
        return nil
    }

    private mutating func continueSpeech(level: Float, duration: TimeInterval) -> Event? {
        length += duration
        if level >= startLevel - tuning.endDrop { pause = 0 } else { pause += duration }
        guard pause >= tuning.hangover || length >= tuning.maxUtterance else { return nil }
        let voiced = length - pause
        reset()
        return voiced >= tuning.minSpeech ? .ended(voiced: voiced) : .discarded
    }

    /// Forgets the utterance in progress, keeping the noise floor.
    mutating func reset() {
        isSpeaking = false
        above = 0
        length = 0
        pause = 0
    }
}

/// Cuts the microphone's stream into utterances: keeps a short lead-in so the first syllable is not lost, collects the
/// samples while `VoiceActivity` says someone is speaking, and hands back a WAV when they stop.
struct UtteranceCutter {
    enum Cut: Equatable {
        case started
        case finished(Data)
        case discarded
    }

    /// Audio kept from before speech was detected: the detector needs `startHold` to be sure.
    static let leadIn: TimeInterval = 0.35

    var activity = VoiceActivity()
    private var lead: [Int16] = []
    private var utterance: [Int16] = []

    var isSpeaking: Bool { activity.isSpeaking }

    mutating func feed(_ samples: [Int16], level: Float) -> Cut? {
        let duration = Double(samples.count) / Double(WAV.sampleRate)
        let event = activity.feed(level: level, duration: duration)
        if activity.isSpeaking || event != nil && event != .started {
            utterance += samples
        } else {
            lead += samples
            let keep = Int(Self.leadIn * Double(WAV.sampleRate))
            if lead.count > keep { lead.removeFirst(lead.count - keep) }
        }
        switch event {
        case .started:
            utterance = lead + utterance
            lead = []
            return .started
        case .ended:
            defer { utterance = [] }
            return .finished(WAV.encode(utterance))
        case .discarded:
            utterance = []
            return .discarded
        case nil:
            return nil
        }
    }

    /// Drops the utterance in progress, for when the conversation stops listening.
    mutating func reset() {
        activity.reset()
        lead = []
        utterance = []
    }
}
