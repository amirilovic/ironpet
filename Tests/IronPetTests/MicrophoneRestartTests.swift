import AVFoundation
import XCTest
@testable import IronPet

private func format(rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
}

private func buffer(_ format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(format.channelCount) {
        for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = sin(Float(i) * 0.05) * 0.5 }
    }
    return buffer
}

private final class FakeEngine: CaptureEngine, @unchecked Sendable {
    var onConfigurationChange: (@Sendable () -> Void)?
    var inputFormat = format(rate: 48_000, channels: 2)
    var failStarts = 0
    /// Number of upcoming `installTap` calls that raise an NSException, as AVAudioEngine does on a format mismatch.
    var raiseOnInstall = 0
    private(set) var starts = 0
    private(set) var tapsInstalled = 0
    private(set) var tapFormats: [AVAudioFormat] = []
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func installTap(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws -> AVAudioFormat {
        if raiseOnInstall > 0 {
            raiseOnInstall -= 1
            try catchingObjCException {
                NSException(name: .init("com.apple.coreaudio.avfaudio"), reason: "required condition is false: format.sampleRate == hwFormat.sampleRate", userInfo: nil).raise()
            }
        }
        self.handler = handler
        tapsInstalled += 1
        tapFormats.append(inputFormat)
        return inputFormat
    }
    func removeTap() { handler = nil }
    func start() throws {
        starts += 1
        if failStarts > 0 {
            failStarts -= 1
            throw VoiceError.noInput
        }
    }
    func stop() {}

    /// Delivers half a second of audio in the current input format.
    func deliver() {
        let frames = AVAudioFrameCount(inputFormat.sampleRate / 2)
        handler?(buffer(inputFormat, frames: frames))
    }
}

private final class FakeClock: CaptureClock, @unchecked Sendable {
    private(set) var now: TimeInterval = 0
    private var scheduled: [(id: Int, due: TimeInterval, interval: TimeInterval?, work: @Sendable () -> Void)] = []
    private var nextID = 0

    func after(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> () -> Void {
        add(due: now + delay, interval: nil, work)
    }
    func every(_ interval: TimeInterval, _ work: @escaping @Sendable () -> Void) -> () -> Void {
        add(due: now + interval, interval: interval, work)
    }
    private func add(due: TimeInterval, interval: TimeInterval?, _ work: @escaping @Sendable () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        scheduled.append((id, due, interval, work))
        return { [weak self] in self?.scheduled.removeAll { $0.id == id } }
    }

    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        while let next = scheduled.filter({ $0.due <= end }).min(by: { $0.due < $1.due }) {
            now = next.due
            scheduled.removeAll { $0.id == next.id }
            if let interval = next.interval { scheduled.append((next.id, now + interval, interval, next.work)) }
            next.work()
        }
        now = end
    }
}

private final class Box: @unchecked Sendable { var message: String? }

final class MicrophoneRestartTests: XCTestCase {
    private func makeSource() -> (MicrophoneSource, FakeEngine, FakeClock) {
        let engine = FakeEngine()
        let clock = FakeClock()
        return (MicrophoneSource(engine: engine, clock: clock), engine, clock)
    }

    private func sampleCount(_ wav: Data) -> Int { (wav.count - 44) / 2 }

    func testConfigurationChangeReinstallsTapAndKeepsEarlierSamples() throws {
        let (source, engine, clock) = makeSource()
        try source.start { _ in }
        engine.deliver()
        let before = engine.starts

        // The headset switched to its 16 kHz hands-free profile and the engine stopped.
        engine.inputFormat = format(rate: 16_000, channels: 1)
        engine.onConfigurationChange?()
        engine.onConfigurationChange?()
        clock.advance(by: 0.3)

        XCTAssertEqual(engine.starts, before + 1, "repeated notifications restart once")
        XCTAssertEqual(engine.tapFormats.last?.sampleRate, 16_000)
        engine.deliver()
        // 0.5 s on each side is about 16 000 samples, less what the resampler holds back. One side alone is under 10 000.
        XCTAssertGreaterThan(sampleCount(source.finish()), 10_000)
    }

    func testSamplesBeforeTheChangeAreStillThere() throws {
        let (source, engine, clock) = makeSource()
        try source.start { _ in }
        engine.deliver()
        engine.onConfigurationChange?()
        clock.advance(by: 0.3)
        XCTAssertGreaterThan(sampleCount(source.finish()), 5_000)
    }

    func testGivesUpAfterThreeFailedRestarts() throws {
        let (source, engine, clock) = makeSource()
        let failure = Box()
        source.onFailure = { failure.message = $0 }
        try source.start { _ in }
        engine.failStarts = 10
        engine.onConfigurationChange?()
        clock.advance(by: 0.3)
        XCTAssertNil(failure.message)
        clock.advance(by: 0.5)
        XCTAssertNil(failure.message)
        clock.advance(by: 0.5)
        XCTAssertNotNil(failure.message)
        XCTAssertTrue(failure.message?.contains("microphone stopped") ?? false)
        let starts = engine.starts
        clock.advance(by: 10)
        XCTAssertEqual(engine.starts, starts, "no further attempts after giving up")
    }

    func testWatchdogRestartsOnceWhenNoBuffersArrive() throws {
        let (source, engine, clock) = makeSource()
        try source.start { _ in }
        engine.deliver()
        clock.advance(by: 1.0)
        XCTAssertEqual(engine.starts, 1)
        clock.advance(by: 1.0)
        XCTAssertEqual(engine.starts, 2, "silent for over 1.5 s, one restart")
        engine.deliver()
        clock.advance(by: 1.0)
        XCTAssertEqual(engine.starts, 2)
    }

    func testWatchdogGivesUpWhenRestartsStaySilent() throws {
        let (source, engine, clock) = makeSource()
        let failure = Box()
        source.onFailure = { failure.message = $0 }
        try source.start { _ in }
        clock.advance(by: 30)
        XCTAssertNotNil(failure.message)
        XCTAssertEqual(engine.starts, 3, "the first start plus two watchdog restarts")
    }

    func testFinishCancelsTheWatchdog() throws {
        let (source, engine, clock) = makeSource()
        try source.start { _ in }
        _ = source.finish()
        clock.advance(by: 30)
        XCTAssertEqual(engine.starts, 1)
    }

    func testObjCExceptionBecomesAThrownError() {
        XCTAssertThrowsError(try catchingObjCException { NSException(name: .init("x"), reason: "boom", userInfo: nil).raise() }) {
            XCTAssertEqual($0.localizedDescription, "boom")
        }
        XCTAssertEqual(try catchingObjCException { 7 }, 7)
    }

    func testRaisingInstallTapCountsAsFailedRestartAndRecovers() throws {
        let (source, engine, clock) = makeSource()
        let failure = Box()
        source.onFailure = { failure.message = $0 }
        try source.start { _ in }
        engine.raiseOnInstall = 1
        engine.onConfigurationChange?()
        clock.advance(by: 0.3)
        XCTAssertNil(failure.message, "one failure is retried, not fatal")
        clock.advance(by: 0.5)
        XCTAssertEqual(engine.tapsInstalled, 2, "the retry installed the tap")
        engine.deliver()
        XCTAssertGreaterThan(sampleCount(source.finish()), 5_000)
    }

    func testRaisingInstallTapEveryTimeGivesUpWithANotice() throws {
        let (source, engine, clock) = makeSource()
        let failure = Box()
        source.onFailure = { failure.message = $0 }
        try source.start { _ in }
        engine.raiseOnInstall = 10
        engine.onConfigurationChange?()
        clock.advance(by: 2)
        XCTAssertTrue(failure.message?.contains("microphone stopped") ?? false)
    }

    func testFiveNotificationsWithinOneSecondRestartOnce() throws {
        let (source, engine, clock) = makeSource()
        try source.start { _ in }
        let before = engine.starts
        for _ in 0..<5 {
            engine.onConfigurationChange?()
            clock.advance(by: 0.15)
        }
        clock.advance(by: 0.3)
        engine.deliver()
        XCTAssertEqual(engine.starts, before + 1)
    }
}
