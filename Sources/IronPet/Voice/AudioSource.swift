import AVFoundation

/// Where a voice note's audio comes from. The microphone in the app; a WAV file in `--test-mode`, so the same
/// recording UI and transcription path can be driven without a person speaking.
protocol AudioSource: AnyObject {
    /// Starts capturing. `level` gets a 0...1 loudness value, from any thread.
    func start(level: @escaping @Sendable (Float) -> Void) throws
    /// Stops and returns everything captured as a 16 kHz mono WAV.
    func finish() -> Data
    /// Stops and drops the audio.
    func cancel()
}

/// A source that can hand over its samples as they arrive, so a long recording never sits in memory (meetings).
/// With `sink` set, `finish()` returns an empty WAV.
protocol StreamingSource: AudioSource {
    var sink: (@Sendable ([Int16]) -> Void)? { get set }
}

enum VoiceError: LocalizedError {
    case noInput
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .noInput: return "No microphone input is available."
        case .unreadable(let path): return "Could not read audio from \(path)."
        }
    }
}

/// Converts any PCM buffer to 16 kHz mono Float32, keeping resampler state between calls.
final class PCMConverter: @unchecked Sendable {
    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(WAV.sampleRate),
                                            channels: 1, interleaved: false)!
    private let converter: AVAudioConverter

    init?(from format: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: format, to: Self.outputFormat) else { return nil }
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = Self.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    static func int16(_ floats: [Float]) -> [Int16] {
        floats.map { Int16(max(-1, min(1, $0)) * 32767) }
    }

    /// Loudness on a 0...1 scale: RMS in dB, with -50 dB and below as silence.
    static func level(of floats: ArraySlice<Float>) -> Float {
        guard !floats.isEmpty else { return 0 }
        let meanSquare = floats.reduce(Float(0)) { $0 + $1 * $1 } / Float(floats.count)
        let decibels = 10 * log10(max(meanSquare, 1e-10))
        return max(0, min(1, (decibels + 50) / 50))
    }
}

/// A `PCMConverter` that follows the format of the buffers it is given. A Bluetooth headset switches from its
/// stereo profile to the 16 kHz hands-free one once the engine starts, so buffers can arrive in a different format
/// than `inputNode.outputFormat` reported earlier. A converter built for the old format returns no samples for them.
final class AdaptiveConverter: @unchecked Sendable {
    private var converter: PCMConverter?
    private var format: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if converter == nil || format != buffer.format {
            converter = PCMConverter(from: buffer.format)
            format = buffer.format
        }
        return converter?.convert(buffer) ?? []
    }
}

/// The default input device through AVAudioEngine.
final class MicrophoneSource: StreamingSource, @unchecked Sendable {
    var sink: (@Sendable ([Int16]) -> Void)?
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var running = false

    func start(level: @escaping @Sendable (Float) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noInput }
        let converter = AdaptiveConverter()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let floats = converter.convert(buffer)
            guard !floats.isEmpty else { return }
            level(PCMConverter.level(of: floats[...]))
            self?.append(PCMConverter.int16(floats))
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    private func append(_ chunk: [Int16]) {
        if let sink {
            sink(chunk)
            return
        }
        lock.lock()
        samples += chunk
        lock.unlock()
    }

    private func stopEngine() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func finish() -> Data {
        stopEngine()
        lock.lock()
        defer { lock.unlock() }
        return WAV.encode(samples)
    }

    func cancel() {
        stopEngine()
    }
}

/// Plays a WAV file as if it were being spoken: levels follow the file in real time, and `finish` returns all of it.
final class FileSource: StreamingSource, @unchecked Sendable {
    var sink: (@Sendable ([Int16]) -> Void)?
    private let samples: [Float]
    private var timer: DispatchSourceTimer?
    private static let tick = 0.04

    init(url: URL) throws {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let converter = PCMConverter(from: file.processingFormat)
        else { throw VoiceError.unreadable(url.path) }
        samples = converter.convert(buffer)
    }

    func start(level: @escaping @Sendable (Float) -> Void) throws {
        let window = Int(Self.tick * Double(WAV.sampleRate))
        var position = 0
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: Self.tick)
        timer.setEventHandler { [samples, sink] in
            let end = min(position + window, samples.count)
            level(position < end ? PCMConverter.level(of: samples[position..<end]) : 0)
            if position < end { sink?(PCMConverter.int16(Array(samples[position..<end]))) }
            position = end
        }
        timer.resume()
        self.timer = timer
    }

    func finish() -> Data {
        cancel()
        return WAV.encode(PCMConverter.int16(samples))
    }

    func cancel() {
        timer?.cancel()
        timer = nil
    }
}
