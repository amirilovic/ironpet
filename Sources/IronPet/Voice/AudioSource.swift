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
    /// Called, from any thread, when capture dies mid-recording and could not be recovered.
    var onFailure: (@Sendable (String) -> Void)? { get set }
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

/// The default input device through AVAudioEngine. Opening a Bluetooth headset's microphone switches it from its
/// stereo profile to the hands-free one. AVAudioEngine then posts a configuration change and stops itself, so the
/// source reinstalls the tap at the new format and starts the engine again, keeping the samples captured so far.
final class MicrophoneSource: StreamingSource, @unchecked Sendable {
    static let restartDelay: TimeInterval = 0.2
    static let retryDelay: TimeInterval = 0.5
    static let silenceLimit: TimeInterval = 1.5
    static let watchdogInterval: TimeInterval = 0.5
    static let maxFailedRestarts = 3

    var sink: (@Sendable ([Int16]) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    private let engine: CaptureEngine
    private let clock: CaptureClock
    private let lock = NSLock()
    /// Held while the engine is rebuilt or stopped, so a restart never overlaps `finish()`.
    private let engineLock = NSRecursiveLock()
    private var samples: [Int16] = []
    private var running = false
    private var level: (@Sendable (Float) -> Void)?
    private var format: AVAudioFormat?
    private var lastBuffer: TimeInterval = 0
    private var failedRestarts = 0
    private var restartPending = false
    private var cancelWatchdog: (() -> Void)?
    private var cancelDebounce: (() -> Void)?

    init(engine: CaptureEngine = AVCaptureEngine(), clock: CaptureClock = DispatchCaptureClock()) {
        self.engine = engine
        self.clock = clock
    }

    func start(level: @escaping @Sendable (Float) -> Void) throws {
        engineLock.lock()
        defer { engineLock.unlock() }
        self.level = level
        let format = try installTap()
        do {
            try engine.start()
        } catch {
            engine.removeTap()
            throw error
        }
        lock.lock()
        running = true
        self.format = format
        lastBuffer = clock.now
        lock.unlock()
        engine.onConfigurationChange = { [weak self] in self?.configurationChanged() }
        cancelWatchdog = clock.every(Self.watchdogInterval) { [weak self] in self?.checkForSilence() }
    }

    private func installTap() throws -> AVAudioFormat {
        let converter = AdaptiveConverter()
        return try engine.installTap { [weak self] buffer in
            guard let self else { return }
            self.lock.lock()
            self.lastBuffer = self.clock.now
            self.failedRestarts = 0
            self.lock.unlock()
            let floats = converter.convert(buffer)
            guard !floats.isEmpty else { return }
            self.level?(PCMConverter.level(of: floats[...]))
            self.append(PCMConverter.int16(floats))
        }
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

    // MARK: Restarting

    private func configurationChanged() {
        lock.lock()
        guard running else { lock.unlock(); return }
        // A headset can post several notifications in a row while it switches profile. Each one pushes the restart back,
        // so one restart runs after the burst ends. A retry already scheduled after a failure is left alone.
        if restartPending && cancelDebounce == nil { lock.unlock(); return }
        restartPending = true
        cancelDebounce?()
        cancelDebounce = clock.after(Self.restartDelay) { [weak self] in
            self?.lock.lock()
            self?.cancelDebounce = nil
            self?.lock.unlock()
            self?.restart(reason: "audio configuration changed")
        }
        lock.unlock()
    }

    private func checkForSilence() {
        lock.lock()
        let silent = running && !restartPending && clock.now - lastBuffer > Self.silenceLimit
        if silent { failedRestarts += 1 }
        let failures = failedRestarts
        lock.unlock()
        guard silent else { return }
        if failures >= Self.maxFailedRestarts {
            giveUp("no audio for \(Self.silenceLimit) s after \(failures - 1) restarts")
        } else {
            restart(reason: "no audio for \(Self.silenceLimit) s")
        }
    }

    private func restart(reason: String) {
        engineLock.lock()
        defer { engineLock.unlock() }
        lock.lock()
        restartPending = false
        let old = format
        let active = running
        lock.unlock()
        guard active else { return }
        engine.removeTap()
        engine.stop()
        engine.reset()
        do {
            let new = try installTap()
            try engine.start()
            lock.lock()
            format = new
            lastBuffer = clock.now
            lock.unlock()
            NSLog("IronPet: microphone restarted (%@), format %@ -> %@", reason, old?.description ?? "none", new.description)
        } catch {
            engine.removeTap()
            lock.lock()
            failedRestarts += 1
            let failures = failedRestarts
            if failures < Self.maxFailedRestarts { restartPending = true }
            lock.unlock()
            NSLog("IronPet: microphone restart failed (%@), attempt %d of %d: %@", reason, failures, Self.maxFailedRestarts,
                  error.localizedDescription)
            if failures >= Self.maxFailedRestarts {
                giveUp("restart failed \(failures) times: \(error.localizedDescription)")
            } else {
                _ = clock.after(Self.retryDelay) { [weak self] in self?.restart(reason: "retry after \(reason)") }
            }
        }
    }

    private func giveUp(_ detail: String) {
        NSLog("IronPet: microphone gave up: %@", detail)
        stopEngine()
        onFailure?("The microphone stopped and could not be restarted. Check the input device and record again.")
    }

    private func stopEngine() {
        engineLock.lock()
        defer { engineLock.unlock() }
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        cancelWatchdog?()
        cancelWatchdog = nil
        lock.lock()
        cancelDebounce?()
        cancelDebounce = nil
        lock.unlock()
        engine.onConfigurationChange = nil
        guard wasRunning else { return }
        engine.removeTap()
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
    var onFailure: (@Sendable (String) -> Void)?
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
