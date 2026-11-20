import Foundation
import os

/// Timing marks for the voice path: one line per step with the milliseconds since the turn's start, in Console.app
/// under `com.ironpet` / `voice`. Nothing is stored and no text is logged, only step names and times.
enum VoiceTiming {
    private static let logger = Logger(subsystem: "com.ironpet", category: "voice")

    /// Logs `step`, with the time since `since` when a turn has one.
    static func log(_ step: String, since: ContinuousClock.Instant? = nil) {
        guard let since else { return logger.info("\(step, privacy: .public)") }
        let ms = Int((ContinuousClock.now - since).milliseconds)
        logger.info("\(step, privacy: .public) +\(ms, privacy: .public) ms")
    }
}

private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
