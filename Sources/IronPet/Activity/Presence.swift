import AppKit

/// Whether the user is at the Mac without typing: a meeting is being recorded, or an app holds the microphone for a call.
/// Uses meeting call detection while it runs; otherwise `micCalls`, which needs no permission.
struct Presence {
    var meetingActive: () -> Bool
    /// The apps meeting call detection counts as calls, or nil while it is not running.
    var detectedCalls: () -> Set<String>?
    /// The apps holding the microphone as of the last background poll, for when meeting call detection is off.
    var micCalls: () -> Set<String>

    func isPresent() -> Bool {
        if meetingActive() { return true }
        return !(detectedCalls() ?? micCalls()).isEmpty
    }
}

/// Polls Core Audio for apps holding the microphone only while asked to, through `CallMonitor`, so the reads stay off
/// the main thread. The first answer after starting is empty; the next poll, 2 s later, has the real one.
@MainActor
final class MicWatch {
    private let monitor: CallMonitor

    init(monitor: CallMonitor? = nil, ignored: @escaping () -> [String] = { [] }) {
        self.monitor = monitor ?? CallMonitor(detector: CallDetector(source: { [] }, debounce: 0, ignored: ignored))
    }

    var isRunning: Bool { monitor.isRunning }

    /// Starts polling if it is not running, and returns the calls the last finished poll saw.
    func calls() -> Set<String> {
        monitor.start()
        return monitor.detector.activeApps
    }

    func stop() { monitor.stop() }
}

/// When the Mac last woke from sleep, so a gap between timer ticks counts as sleep only after a real wake, not after
/// App Nap or a busy main thread.
@MainActor
final class WakeMonitor {
    static let shared = WakeMonitor()
    private(set) var lastWake: Date?
    private var observer: NSObjectProtocol?

    private init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            // Registered on the main queue, so this runs on the main thread.
            MainActor.assumeIsolated { WakeMonitor.shared.lastWake = Date() }
        }
    }

    func woke(since date: Date) -> Bool { lastWake.map { $0 > date } ?? false }
}
