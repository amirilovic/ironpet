import Foundation

/// Turns a burst of events into fires. It knows nothing about streams, so a later trigger on ironpet's own events can
/// reuse it. It keeps at most one pending event (the newest) and counts how many it merged.
///
/// - `debounce`: fire once after this many seconds without a new event.
/// - `throttle`: at most one fire in this many seconds, measured from the start of the last fire.
/// - Back-pressure: while a fire is running, nothing fires. The newest event waits and goes out when the fire calls `done`.
@MainActor
final class EventCoalescer {
    /// Called with the newest event and how many events it stands for. `done` must be called once the action has finished.
    var fire: (_ event: [String: Any], _ count: Int, _ done: @escaping () -> Void) -> Void = { _, _, done in done() }
    var debounce: TimeInterval
    var throttle: TimeInterval
    var now: () -> Date

    private var pending: [String: Any]?
    private var count = 0
    private var settled = false
    private(set) var busy = false
    private(set) var lastFire: Date?
    private var debounceTimer: DispatchWorkItem?
    private var throttleTimer: DispatchWorkItem?

    init(debounce: TimeInterval = 0, throttle: TimeInterval = 0, now: @escaping () -> Date = { Date() }) {
        self.debounce = debounce
        self.throttle = throttle
        self.now = now
    }

    var hasPending: Bool { pending != nil }

    func submit(_ event: [String: Any]) {
        pending = event
        count += 1
        debounceTimer?.cancel()
        debounceTimer = nil
        if debounce > 0 {
            settled = false
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.debounceTimer = nil
                    self?.settled = true
                    self?.attempt()
                }
            }
            debounceTimer = item
            DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
        } else {
            settled = true
            attempt()
        }
    }

    /// Drops the pending event and the timers. A fire that is already running keeps its `busy` flag until it calls `done`.
    func reset() {
        debounceTimer?.cancel()
        throttleTimer?.cancel()
        debounceTimer = nil
        throttleTimer = nil
        pending = nil
        count = 0
        settled = false
    }

    private func attempt() {
        guard let event = pending, settled, !busy else { return }
        if throttle > 0, let last = lastFire {
            let wait = last.addingTimeInterval(throttle).timeIntervalSince(now())
            if wait > 0 {
                guard throttleTimer == nil else { return }
                let item = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        self?.throttleTimer = nil
                        self?.attempt()
                    }
                }
                throttleTimer = item
                DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
                return
            }
        }
        let merged = count
        pending = nil
        count = 0
        settled = false
        busy = true
        lastFire = now()
        var finished = false
        fire(event, merged) { [weak self] in
            // `done` can come from a task that outlives the caller, so hop to the main queue and ignore a second call.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !finished else { return }
                    finished = true
                    self?.busy = false
                    self?.attempt()
                }
            }
        }
    }
}
