import Foundation

/// Decides when a capture is due. It is event-driven: a signal sets a short settle time, and the capture runs
/// when that time passes with nothing newer. Typing and scrolling push the time back, so a burst of keys makes one capture, taken after
/// the pause. Nothing here reads a clock: the caller passes `now`, so a test drives it with its own.
struct CaptureScheduler {
    struct Timing: Equatable {
        /// Seconds to wait after the signal for the window to settle.
        var appSwitch = 0.3
        var windowFocus = 0.3
        var typingPause = 0.5
        var scrollStop = 0.4
        var click = 0.2
        /// With nothing else going on, a capture is taken this often.
        var idle = 10.0
        /// Two captures are never closer than this.
        var minGap = 0.2
    }

    let timing: Timing
    private var due: (at: TimeInterval, trigger: CaptureTrigger)?
    private var lastCapture: TimeInterval?
    /// The first time the scheduler saw, so the idle capture counts from the start when nothing has been captured yet.
    private var anchor: TimeInterval?

    init(timing: Timing = Timing()) { self.timing = timing }

    /// Records a signal. A key or a scroll replaces a pending capture of the same kind with a later one. Any other signal keeps the
    /// earlier of the two, so a click during typing does not postpone the capture the typing already earned.
    mutating func signal(_ signal: CaptureSignal, at now: TimeInterval) {
        let (delay, trigger): (TimeInterval, CaptureTrigger)
        switch signal {
        case .appSwitch: (delay, trigger) = (timing.appSwitch, .appSwitch)
        case .windowFocus: (delay, trigger) = (timing.windowFocus, .windowFocus)
        case .key: (delay, trigger) = (timing.typingPause, .typingPause)
        case .scroll: (delay, trigger) = (timing.scrollStop, .scrollStop)
        case .click: (delay, trigger) = (timing.click, .click)
        }
        let candidate = (at: now + delay, trigger: trigger)
        if anchor == nil { anchor = now }
        guard let pending = due else { due = candidate; return }
        if pending.trigger == trigger { due = candidate; return }
        // Typing and scrolling keep their own timer running; the other kinds are one-off events that make the capture sooner.
        if candidate.at < pending.at { due = candidate }
    }

    /// When the next capture is due, for arming a timer: a pending signal's time or the idle time, whichever is first.
    func nextDue(now: TimeInterval) -> TimeInterval {
        let idleAt = (lastCapture ?? anchor ?? now) + timing.idle
        var at = due?.at ?? idleAt
        if let lastCapture { at = max(at, lastCapture + timing.minGap) }
        return at
    }

    /// The trigger of a capture that is due now, or nil. Calling it again before the next signal returns nil until the idle time passes.
    mutating func poll(now: TimeInterval) -> CaptureTrigger? {
        if anchor == nil { anchor = now }
        if let lastCapture, now < lastCapture + timing.minGap { return nil }
        if let pending = due, now >= pending.at {
            due = nil
            lastCapture = now
            return pending.trigger
        }
        let idleAt = (lastCapture ?? anchor ?? now) + timing.idle
        if due == nil, now >= idleAt {
            lastCapture = now
            return .idle
        }
        return nil
    }

    /// Forgets pending signals, as when capture is paused.
    mutating func reset() {
        due = nil
        lastCapture = nil
        anchor = nil
    }
}
