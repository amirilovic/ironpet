import XCTest
@testable import IronPet

final class VoiceActivityTests: XCTestCase {
    private let frame: TimeInterval = 0.02

    /// Feeds `seconds` of frames at `level` and returns the events in order.
    private func feed(_ activity: inout VoiceActivity, level: Float, seconds: TimeInterval) -> [VoiceActivity.Event] {
        (0..<Int((seconds / frame).rounded())).compactMap { _ in activity.feed(level: level, duration: frame) }
    }

    func testSpeechStartsAfterTheHoldAndEndsAfterTheHangover() {
        var activity = VoiceActivity()
        XCTAssertEqual(feed(&activity, level: 0.05, seconds: 1), [])
        XCTAssertEqual(feed(&activity, level: 0.6, seconds: 0.1), [], "shorter than the start hold")
        XCTAssertEqual(feed(&activity, level: 0.6, seconds: 1), [.started])
        // A breath between words is not the end.
        XCTAssertEqual(feed(&activity, level: 0.05, seconds: 0.4), [])
        XCTAssertEqual(feed(&activity, level: 0.6, seconds: 0.5), [])
        let events = feed(&activity, level: 0.05, seconds: 0.8)
        guard case .ended(let voiced)? = events.first else { return XCTFail("expected an end, got \(events)") }
        XCTAssertEqual(voiced, 2.0, accuracy: 0.1)
        XCTAssertFalse(activity.isSpeaking)
    }

    func testAClickIsDiscarded() {
        var activity = VoiceActivity()
        XCTAssertEqual(feed(&activity, level: 0.7, seconds: 0.16), [.started])
        XCTAssertEqual(feed(&activity, level: 0.0, seconds: 0.8), [.discarded])
    }

    func testANoisyRoomRaisesTheStartLevel() {
        var activity = VoiceActivity()
        let quiet = activity.startLevel
        _ = feed(&activity, level: 0.3, seconds: 10)
        XCTAssertGreaterThan(activity.startLevel, quiet)
        // The room's own hum never counts as speech.
        XCTAssertFalse(activity.isSpeaking)
        XCTAssertEqual(feed(&activity, level: 0.4, seconds: 1), [], "just above the old threshold is still the room")
        XCTAssertEqual(feed(&activity, level: 0.7, seconds: 0.2), [.started])
    }

    func testDuringPlaybackOnlyLouderLongerSpeechInterrupts() {
        var activity = VoiceActivity()
        activity.playback = true
        // The pet's own voice leaking through echo cancellation.
        XCTAssertEqual(feed(&activity, level: 0.45, seconds: 2), [])
        XCTAssertEqual(feed(&activity, level: 0.7, seconds: 0.2), [], "shorter than the barge-in hold")
        _ = feed(&activity, level: 0.1, seconds: 0.1)
        XCTAssertEqual(feed(&activity, level: 0.7, seconds: 0.3), [.started])
    }

    func testALongUtteranceIsCutAtTheLimit() {
        var activity = VoiceActivity()
        activity.tuning.maxUtterance = 2
        let events = feed(&activity, level: 0.6, seconds: 3)
        XCTAssertEqual(events.first, .started)
        guard case .ended? = events.dropFirst().first else { return XCTFail("expected a cut, got \(events)") }
    }

    func testTheCutterKeepsTheLeadInAndReturnsTheUtterance() throws {
        var cutter = UtteranceCutter()
        let samplesPerFrame = Int(Double(WAV.sampleRate) * frame)
        func feed(_ level: Float, seconds: TimeInterval) -> [UtteranceCutter.Cut] {
            (0..<Int((seconds / frame).rounded())).compactMap { _ in
                cutter.feed([Int16](repeating: level > 0.3 ? 8_000 : 10, count: samplesPerFrame), level: level)
            }
        }
        XCTAssertEqual(feed(0.05, seconds: 1), [])
        XCTAssertEqual(feed(0.6, seconds: 1), [.started])
        let cuts = feed(0.05, seconds: 0.8)
        guard case .finished(let wav)? = cuts.first else { return XCTFail("expected a WAV, got \(cuts)") }
        let duration = try XCTUnwrap(WAV.duration(of: wav))
        // One second of speech, the lead-in before the start was certain, and the closing pause.
        XCTAssertEqual(duration, 1 + UtteranceCutter.leadIn - 0.12 + 0.12 + 0.7, accuracy: 0.15)
        XCTAssertEqual(feed(0.05, seconds: 1), [])
    }
}
