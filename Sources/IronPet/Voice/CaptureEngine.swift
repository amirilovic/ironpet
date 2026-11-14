import AVFoundation

/// The slice of AVAudioEngine that `MicrophoneSource` needs, so tests can fake the engine and its notifications.
protocol CaptureEngine: AnyObject {
    /// Called when the engine reports that the audio hardware configuration changed. AVAudioEngine has stopped itself by then.
    var onConfigurationChange: (@Sendable () -> Void)? { get set }
    /// Installs a tap on the input at the input's current format and returns that format.
    func installTap(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws -> AVAudioFormat
    func removeTap()
    /// Drops cached graph state before a restart, so the next `installTap` reads the new hardware format.
    func reset()
    func start() throws
    func stop()
}

extension CaptureEngine {
    func reset() {}
}

/// Time for `MicrophoneSource`'s debounce and watchdog. Work runs on one serial queue, so restarts never overlap.
protocol CaptureClock: AnyObject {
    var now: TimeInterval { get }
    /// Runs `work` once after `delay`. The returned closure cancels it.
    func after(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> () -> Void
    /// Runs `work` every `interval`. The returned closure cancels it.
    func every(_ interval: TimeInterval, _ work: @escaping @Sendable () -> Void) -> () -> Void
}

final class DispatchCaptureClock: CaptureClock {
    private let queue = DispatchQueue(label: "ironpet.capture-clock")

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func after(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> () -> Void {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    func every(_ interval: TimeInterval, _ work: @escaping @Sendable () -> Void) -> () -> Void {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: work)
        timer.resume()
        return { timer.cancel() }
    }
}

final class AVCaptureEngine: CaptureEngine, @unchecked Sendable {
    var onConfigurationChange: (@Sendable () -> Void)?
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.onConfigurationChange?() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func installTap(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws -> AVAudioFormat {
        try catchingObjCException {
            let input = engine.inputNode
            // The hardware format. `outputFormat` can still describe the previous device after a configuration change.
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noInput }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in handler(buffer) }
            return format
        }
    }

    func removeTap() {
        try? catchingObjCException { engine.inputNode.removeTap(onBus: 0) }
    }

    func reset() {
        try? catchingObjCException { engine.reset() }
    }

    func start() throws {
        try catchingObjCException {
            engine.prepare()
            try engine.start()
        }
    }

    func stop() {
        try? catchingObjCException { engine.stop() }
    }
}
