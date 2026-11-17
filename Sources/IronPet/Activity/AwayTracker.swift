import Foundation

/// Tells when the user stepped away from the Mac and when they came back, from samples of the system idle time. Away
/// starts once nothing was typed or clicked for `threshold`, or when two samples are `threshold` apart (the Mac slept and
/// the timer did not fire). It ends at the first sample with recent input. Pure, so tests drive it with a fake clock.
struct AwayTracker: Equatable {
    enum Transition: Equatable {
        case left(since: Date)
        case returned(since: Date, at: Date)
    }

    /// Input this recent means someone is at the keyboard.
    static let backWithin: TimeInterval = 10

    /// When the current away stretch began; nil while the user is here.
    private(set) var awaySince: Date?
    private(set) var lastSample: Date?

    /// `present` is true while the user is at the Mac without typing, such as on a call: no stretch starts, and one that
    /// is running ends without a return.
    mutating func sample(now: Date, idleSeconds: TimeInterval, threshold: TimeInterval, present: Bool) -> Transition? {
        let previous = lastSample
        lastSample = now
        if present {
            awaySince = nil
            return nil
        }
        let active = idleSeconds < Self.backWithin
        if let since = awaySince {
            guard active else { return nil }
            awaySince = nil
            return .returned(since: since, at: now)
        }
        if let previous, now.timeIntervalSince(previous) >= threshold {
            // Woke from sleep: the stretch began at the last sample before it.
            if active { return .returned(since: previous, at: now) }
            awaySince = previous
            return .left(since: previous)
        }
        guard idleSeconds >= threshold else { return nil }
        let since = now.addingTimeInterval(-idleSeconds)
        awaySince = since
        return .left(since: since)
    }
}
