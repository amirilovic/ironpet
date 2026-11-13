import Foundation
import QuartzCore

/// Loudness samples for the waveform. The audio thread records peaks; the main thread calls `tick` at a fixed rate to
/// turn them into evenly spaced bars. The waveform view reads it on its own display-rate timeline, so drawing
/// never goes through `@Published` and never re-renders the chat.
final class LevelBuffer: @unchecked Sendable {
    static let tickInterval: TimeInterval = 1.0 / 25
    private static let capacity = 400

    private let lock = NSLock()
    private var peak: Float = 0
    private var bars: [Float] = []
    private var previous: Float = 0
    private var lastTick: CFTimeInterval = CACurrentMediaTime()

    /// Called from the audio thread.
    func record(_ level: Float) {
        lock.lock()
        peak = max(peak, level)
        lock.unlock()
    }

    /// Closes the current interval into one bar. A fast attack and slow release keep the bars from flickering.
    func tick() {
        lock.lock()
        let bar = max(peak, previous * 0.7)
        previous = bar
        peak = 0
        bars.append(bar)
        if bars.count > Self.capacity { bars.removeFirst(bars.count - Self.capacity) }
        lastTick = CACurrentMediaTime()
        lock.unlock()
    }

    /// The newest `count` bars, oldest first, padded with silence on the left, and how far through the current
    /// interval it is (0...1) so the view can scroll smoothly between ticks.
    func recent(_ count: Int) -> (bars: [Float], phase: Double) {
        lock.lock()
        defer { lock.unlock() }
        let tail = Array(bars.suffix(count))
        let padded = [Float](repeating: 0, count: max(0, count - tail.count)) + tail
        return (padded, min(1, (CACurrentMediaTime() - lastTick) / Self.tickInterval))
    }

    func reset() {
        lock.lock()
        peak = 0
        previous = 0
        bars = []
        lastTick = CACurrentMediaTime()
        lock.unlock()
    }
}
