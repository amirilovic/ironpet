import AVFoundation
import Foundation

/// What `VoiceConversation` needs from the microphone. `ConversationMic` is the real one; tests send events by hand.
@MainActor
protocol ConversationListening: AnyObject {
    var onEvent: ((ConversationMic.Event) -> Void)? { get set }
    var levels: LevelBuffer { get }
    /// Plays the pet's voice. Through the microphone's own engine, so echo cancellation knows what to take out.
    var player: ClipPlaying { get }
    func start() throws
    func stop()
    /// True while the pet speaks: speech must then be louder and longer to count, so the pet does not interrupt itself.
    func setPlayback(_ on: Bool)
}

/// The microphone for a voice conversation. One `AVAudioEngine` with voice processing on, so the pet's voice coming
/// out of the speakers is cancelled from what the microphone hears. Each buffer goes to a serial queue, where an
/// `UtteranceCutter` finds where the user starts and stops talking; only those moments reach the main actor.
@MainActor
final class ConversationMic: ConversationListening {
    enum Event: Equatable {
        case speechStarted
        /// One utterance as a 16 kHz mono WAV.
        case utterance(Data)
        /// Something too short to be speech ended.
        case discarded
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?
    let levels = LevelBuffer()
    private(set) lazy var player: ClipPlaying = EngineClipPlayer(engine: engine, node: playerNode)

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let cutting = CuttingState()
    private var observer: NSObjectProtocol?
    private var levelTimer: Timer?
    private var running = false

    func start() throws {
        guard !running else { return }
        try catchingObjCException {
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            // Voice processing ducks other apps' audio by default, which would make music drop whenever the mic opens.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            if playerNode.engine == nil { engine.attach(playerNode) }
            engine.connect(playerNode, to: engine.mainMixerNode, format: EngineClipPlayer.format)
        }
        try installTapAndStart()
        running = true
        levels.reset()
        let timer = Timer(timeInterval: LevelBuffer.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.levels.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    private func installTapAndStart() throws {
        let cutting = cutting
        let levels = levels
        let converter = AdaptiveConverter()
        try catchingObjCException {
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noInput }
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                let floats = converter.convert(buffer)
                guard !floats.isEmpty else { return }
                let level = PCMConverter.level(of: floats[...])
                levels.record(level)
                cutting.feed(PCMConverter.int16(floats), level: level) { event in
                    Task { @MainActor in self?.onEvent?(event) }
                }
            }
            engine.prepare()
            try engine.start()
        }
    }

    /// A device change (headphones plugged in, a Bluetooth headset switching profile) stops the engine. Starts it again on
    /// the new device, dropping the utterance in progress.
    private func restart() {
        guard running else { return }
        player.stop()
        try? catchingObjCException { engine.inputNode.removeTap(onBus: 0) }
        try? catchingObjCException { engine.stop() }
        // After the reset on the cutter's queue, so no event from before the change arrives after it.
        cutting.reset { [weak self] in
            Task { @MainActor in self?.onEvent?(.discarded) }
        }
        do {
            try installTapAndStart()
            NSLog("ironpet: conversation microphone restarted after a configuration change")
        } catch {
            NSLog("ironpet: conversation microphone could not restart: \(error.localizedDescription)")
            onEvent?(.failed("The microphone stopped and could not be restarted. Check the input device and try again."))
        }
    }

    func stop() {
        guard running else { return }
        running = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        levelTimer?.invalidate()
        levelTimer = nil
        player.stop()
        try? catchingObjCException { engine.inputNode.removeTap(onBus: 0) }
        try? catchingObjCException { engine.stop() }
        try? catchingObjCException { try engine.inputNode.setVoiceProcessingEnabled(false) }
        cutting.reset()
    }

    func setPlayback(_ on: Bool) {
        cutting.setPlayback(on)
    }
}

/// The cutter and its playback flag, used only on their own serial queue.
private final class CuttingState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ironpet.conversation-mic")
    private var cutter = UtteranceCutter()

    func feed(_ samples: [Int16], level: Float, emit: @escaping @Sendable (ConversationMic.Event) -> Void) {
        queue.async {
            switch self.cutter.feed(samples, level: level) {
            case .started: emit(.speechStarted)
            case .finished(let wav): emit(.utterance(wav))
            case .discarded: emit(.discarded)
            case nil: break
            }
        }
    }

    func setPlayback(_ on: Bool) {
        queue.async { self.cutter.activity.playback = on }
    }

    func reset(then done: (@Sendable () -> Void)? = nil) {
        queue.async {
            self.cutter.reset()
            done?()
        }
    }
}

/// Plays a clip through an `AVAudioPlayerNode` on the conversation's engine. Clips arrive as WAV from the speech server
/// at its own sample rate, so each is converted to the node's format first.
@MainActor
final class EngineClipPlayer: ClipPlaying {
    nonisolated static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private let engine: AVAudioEngine
    private let node: AVAudioPlayerNode
    private var continuation: CheckedContinuation<Void, Error>?
    private var generation = 0

    init(engine: AVAudioEngine, node: AVAudioPlayerNode) {
        self.engine = engine
        self.node = node
    }

    func play(_ audio: Data) async throws {
        stop()
        guard engine.isRunning, let buffer = Self.buffer(from: audio) else { throw SpeechError.noAudio }
        generation += 1
        let current = generation
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in self?.end(current, throwing: nil) }
            }
            node.play()
        }
    }

    func stop() {
        guard continuation != nil else { return }
        end(generation, throwing: CancellationError())
        node.stop()
    }

    private func end(_ clip: Int, throwing error: Error?) {
        guard clip == generation, let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    /// The clip decoded and converted to `format`.
    nonisolated static func buffer(from audio: Data) -> AVAudioPCMBuffer? {
        guard let source = pcm(wav: audio) else { return nil }
        if source.format == format { return source }
        guard let converter = AVAudioConverter(from: source.format, to: format) else { return nil }
        let capacity = AVAudioFrameCount(Double(source.frameLength) * format.sampleRate / source.format.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    /// A WAV clip read in memory, so a reply's audio never touches the disk: 16-bit integer or 32-bit float PCM, any
    /// rate and channel count. A streamed header's unknown data length (0xFFFFFFFF) reads to the end.
    nonisolated static func pcm(wav: Data) -> AVAudioPCMBuffer? {
        let bytes = [UInt8](wav)
        func word(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func long(_ at: Int) -> Int { word(at) | word(at + 2) << 16 }
        func tag(_ at: Int) -> String { String(decoding: bytes[at..<at + 4], as: UTF8.self) }
        guard bytes.count > 12, tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }
        var offset = 12
        var header: (encoding: Int, channels: Int, rate: Int, bits: Int)?
        var samples: Range<Int>?
        while offset + 8 <= bytes.count, samples == nil {
            let size = long(offset + 4)
            let body = offset + 8
            if tag(offset) == "fmt ", size >= 16, body + 16 <= bytes.count {
                var encoding = word(body)
                if encoding == 0xFFFE, size >= 26, body + 26 <= bytes.count { encoding = word(body + 24) }
                header = (encoding, word(body + 2), long(body + 4), word(body + 14))
            } else if tag(offset) == "data" {
                samples = body..<min(body + size, bytes.count)
            }
            offset = body + size + (size & 1)
        }
        guard let header, let samples, header.channels > 0, header.rate > 0 else { return nil }
        let common: AVAudioCommonFormat
        switch (header.encoding, header.bits) {
        case (1, 16): common = .pcmFormatInt16
        case (3, 32): common = .pcmFormatFloat32
        default: return nil
        }
        let frameBytes = header.channels * header.bits / 8
        let frames = samples.count / frameBytes
        guard frames > 0,
              let format = AVAudioFormat(commonFormat: common, sampleRate: Double(header.rate),
                                         channels: AVAudioChannelCount(header.channels), interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { return nil }
        bytes.withUnsafeBytes { raw in
            destination.copyMemory(from: raw.baseAddress! + samples.lowerBound, byteCount: frames * frameBytes)
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }
}
