import ApplicationServices
import Foundation

/// Owns the thread that every `AXObserver` lives on. Creating, adding, removing and invalidating an observer, and releasing the
/// context HIServices holds a pointer to, all happen on this thread, which is also the thread the observer's callbacks run on. A
/// teardown therefore never overlaps a callback for the same observer, and the main thread never touches an observer.
final class AXObserverHost {
    /// Starts watching `pid` and returns the teardown. Both run on the host's thread. The teardown must invalidate the run-loop
    /// source first, then remove the notifications, then release what the callback uses. `fire` reports a notification.
    typealias Attach = (_ pid: pid_t, _ fire: @escaping () -> Void) -> (() -> Void)?

    private let attachObserver: Attach
    private let onEvent: () -> Void
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    // Only read or written on the host's thread.
    private var teardown: (() -> Void)?
    private var generation = 0

    init(attach: @escaping Attach, onEvent: @escaping () -> Void) {
        attachObserver = attach
        self.onEvent = onEvent
    }

    func start() {
        guard thread == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let loop = CFRunLoopGetCurrent()
            // A far-future timer keeps the run loop alive while no observer is attached.
            var timerContext = CFRunLoopTimerContext()
            let timer = CFRunLoopTimerCreate(nil, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0, { _, _ in }, &timerContext)
            CFRunLoopAddTimer(loop, timer, .defaultMode)
            self?.runLoop = loop
            ready.signal()
            while Thread.current.isCancelled == false { CFRunLoopRunInMode(.defaultMode, 3600, false) }
            CFRunLoopTimerInvalidate(timer)
        }
        thread.name = "ironpet.capture.ax"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
        ready.wait()
    }

    func attach(to pid: pid_t) {
        perform { [self] in
            tearDown()
            let current = generation
            teardown = attachObserver(pid) { [weak self] in
                // Drop an event whose observer is no longer the current one.
                guard let self, current == generation else { return }
                onEvent()
            }
        }
    }

    func detach() { perform { [self] in tearDown() } }

    /// Tears down, then ends the thread once that block has run.
    func stop() {
        let (ending, loop) = (thread, runLoop)
        perform { [self] in
            tearDown()
            ending?.cancel()
            if let loop { CFRunLoopStop(loop) }
        }
        thread = nil
        runLoop = nil
    }

    /// Runs `block` on the host's thread. Callers other than tests use `attach`, `detach` and `stop`.
    func perform(_ block: @escaping () -> Void) {
        guard let loop = runLoop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(loop)
    }

    private func tearDown() {
        generation += 1
        let finish = teardown
        teardown = nil
        finish?()
    }
}
