import XCTest
@testable import IronPet

final class CaptureSchedulerTests: XCTestCase {
    /// Polls every 50 ms from `from` to `to` and returns what fired and when.
    private func drive(_ scheduler: inout CaptureScheduler, from: TimeInterval, to: TimeInterval) -> [(TimeInterval, CaptureTrigger)] {
        var fired: [(TimeInterval, CaptureTrigger)] = []
        var t = from
        while t <= to + 1e-9 {
            if let trigger = scheduler.poll(now: t) { fired.append((t, trigger)) }
            t += 0.05
        }
        return fired
    }

    func testEachSignalWaitsItsOwnSettleTime() {
        let cases: [(CaptureSignal, CaptureTrigger, TimeInterval)] = [(.appSwitch, .appSwitch, 0.3), (.windowFocus, .windowFocus, 0.3),
                                                                      (.key, .typingPause, 0.5), (.scroll, .scrollStop, 0.4), (.click, .click, 0.2)]
        for (signal, trigger, delay) in cases {
            var scheduler = CaptureScheduler()
            _ = scheduler.poll(now: 0)
            scheduler.signal(signal, at: 1)
            XCTAssertNil(scheduler.poll(now: 1 + delay - 0.06), "\(signal) fired early")
            XCTAssertEqual(scheduler.poll(now: 1 + delay + 0.001), trigger, "\(signal)")
            XCTAssertNil(scheduler.poll(now: 1 + delay + 0.01), "\(signal) fired twice")
        }
    }

    func testFiveSecondsOfTypingMakesNoCaptureAndOneAfterThePause() {
        var scheduler = CaptureScheduler()
        _ = scheduler.poll(now: 0)
        scheduler.signal(.appSwitch, at: 0)
        XCTAssertEqual(drive(&scheduler, from: 0.05, to: 0.4).map(\.1), [.appSwitch])
        var fired: [(TimeInterval, CaptureTrigger)] = []
        var t = 1.0
        while t <= 6.0 {
            scheduler.signal(.key, at: t)
            fired += drive(&scheduler, from: t, to: t + 0.1 - 0.001)
            t += 0.1
        }
        XCTAssertTrue(fired.isEmpty, "no capture while keys keep arriving: \(fired)")
        let after = drive(&scheduler, from: 6.1, to: 7.0)
        XCTAssertEqual(after.map(\.1), [.typingPause])
        XCTAssertEqual(after[0].0, 6.5, accuracy: 0.06, "0.5 s after the last key at 6.0")
    }

    func testAKeyThenAClickCapturesAtTheClickAndThenTheTypingPause() {
        var scheduler = CaptureScheduler()
        _ = scheduler.poll(now: 0)
        scheduler.signal(.key, at: 1)
        scheduler.signal(.click, at: 1.1)
        let fired = drive(&scheduler, from: 1.1, to: 2.0)
        XCTAssertEqual(fired.first?.1, .click)
    }

    func testIdleCaptureEveryTenSecondsAndNeverCloserThanTheMinimumGap() {
        var scheduler = CaptureScheduler()
        let fired = drive(&scheduler, from: 0, to: 31)
        XCTAssertEqual(fired.map(\.1), [.idle, .idle, .idle])
        XCTAssertEqual(fired.map(\.0), [10, 20, 30].map { $0 }, accuracy: 0.06)

        // With a settle time shorter than the gap, the gap still holds.
        var close = CaptureScheduler(timing: .init(click: 0.05))
        _ = close.poll(now: 0)
        close.signal(.click, at: 1)
        XCTAssertEqual(close.poll(now: 1.05), .click)
        close.signal(.click, at: 1.06)
        XCTAssertNil(close.poll(now: 1.12), "due at 1.11, but the last capture was at 1.05")
        XCTAssertEqual(close.poll(now: 1.26), .click)
    }

    func testNextDueIsThePendingTimeOrTheIdleTime() {
        var scheduler = CaptureScheduler()
        _ = scheduler.poll(now: 0)
        XCTAssertEqual(scheduler.nextDue(now: 0), 10)
        scheduler.signal(.scroll, at: 2)
        XCTAssertEqual(scheduler.nextDue(now: 2), 2.4, accuracy: 1e-9)
    }
}

private func XCTAssertEqual(_ a: [TimeInterval], _ b: [TimeInterval], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
