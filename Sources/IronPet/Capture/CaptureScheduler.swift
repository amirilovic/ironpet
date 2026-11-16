import Foundation

/// What can wake the capture loop. The loop never polls: a read happens only after one of these.
enum CaptureEventKind: Equatable {
    case focusChanged, titleChanged, valueChanged, liveRegionChanged, selectionChanged, appActivated

    /// Events after which the window may show a different thread. Value and live-region changes edit what is already there.
    var mayChangeIdentity: Bool {
        switch self {
        case .focusChanged, .titleChanged, .selectionChanged, .appActivated: return true
        case .valueChanged, .liveRegionChanged: return false
        }
    }
}

struct CaptureEvent: Equatable {
    var app: CaptureApp
    var kind: CaptureEventKind
}

/// Limits for one read. When either is hit the source stops and marks the snapshot truncated.
struct CaptureReadBudget: Equatable {
    var maxNodes = 20_000
    var maxTime: TimeInterval = 4
}

/// Where snapshots come from. The macOS implementation reads accessibility; tests use a fake, so no test touches the real screen.
protocol CaptureSource: AnyObject {
    /// Starts delivering events. Called from the capture queue; `onEvent` may be called from any thread.
    func start(onEvent: @escaping (CaptureEvent) -> Void)
    func stop()
    var isTrusted: Bool { get }
    func frontmostApp() -> CaptureApp?
    /// The app's focused window as a normalized tree, or nil.
    func readFocusedWindow(of app: CaptureApp, budget: CaptureReadBudget) -> CaptureSnapshot?
    /// Lines of text drawn in a screen rectangle, read on the device. Nil without Screen Recording permission.
    func readText(in rect: CaptureRect) -> [String]?
    /// Chromium and Electron apps expose no web tree until asked.
    func isWebApp(_ app: CaptureApp) -> Bool
    func enableWebAccessibility(_ app: CaptureApp)
}

/// A finished read. `earlier` is the first read of a burst that needed confirmation; the pipeline stores `snapshot` only if both
/// resolve to the same thread.
struct CaptureRead {
    var snapshot: CaptureSnapshot
    var earlier: CaptureSnapshot?
    /// 0 for the first try, then one more for each retry after a mismatch.
    var attempt: Int
}

/// Collapses bursts of events into one read per app. A read becomes due once `debounce` has passed since the last event, or `maxWait`
/// since the first (so typing cannot starve it).
struct CaptureScheduler {
    struct Pending {
        var app: CaptureApp
        var first: TimeInterval
        var last: TimeInterval
        var identity: Bool
        var attempt: Int
    }

    struct Due: Equatable {
        var app: CaptureApp
        var identity: Bool
        var attempt: Int
    }

    var debounce: TimeInterval
    var maxWait: TimeInterval
    private(set) var pending: [Int32: Pending] = [:]

    init(debounce: TimeInterval = 0.8, maxWait: TimeInterval = 5) {
        self.debounce = debounce
        self.maxWait = maxWait
    }

    mutating func onEvent(_ event: CaptureEvent, now: TimeInterval) {
        queue(event.app, now: now, identity: event.kind.mayChangeIdentity, attempt: 0)
    }

    /// Schedules another identity read of `app`, after the two reads of a burst disagreed.
    mutating func requeue(_ app: CaptureApp, now: TimeInterval, attempt: Int) {
        queue(app, now: now, identity: true, attempt: attempt)
    }

    private mutating func queue(_ app: CaptureApp, now: TimeInterval, identity: Bool, attempt: Int) {
        if var existing = pending[app.pid] {
            existing.last = now
            existing.app = app
            existing.identity = existing.identity || identity
            existing.attempt = max(existing.attempt, attempt)
            pending[app.pid] = existing
        } else {
            pending[app.pid] = Pending(app: app, first: now, last: now, identity: identity, attempt: attempt)
        }
    }

    /// Removes and returns the apps whose read is due.
    mutating func takeDue(now: TimeInterval) -> [Due] {
        let ready = pending.filter { now - $0.value.last >= debounce || now - $0.value.first >= maxWait }
        for pid in ready.keys { pending[pid] = nil }
        return ready.values.sorted { $0.first < $1.first }.map { Due(app: $0.app, identity: $0.identity, attempt: $0.attempt) }
    }

    /// When the next read becomes due, for sleeping until then.
    var nextDue: TimeInterval? {
        pending.values.map { min($0.last + debounce, $0.first + maxWait) }.min()
    }
}

/// Reads due windows through a source, with the confirmation re-read: after an app switch or a focus, title or selection change,
/// the window is read again `settle` later, and the pair goes to the pipeline together. Value and live-region changes are read once.
final class CaptureReader {
    static let maxConfirmAttempts = 2

    private struct Awaiting {
        var app: CaptureApp
        var snapshot: CaptureSnapshot
        var confirmAt: TimeInterval
        var attempt: Int
    }

    private let source: CaptureSource
    private let may: (CaptureApp) -> Bool
    private let regions: (CaptureSnapshot) -> [CapturePipeline.OCRRegion]
    private var scheduler: CaptureScheduler
    private var awaiting: [Int32: Awaiting] = [:]
    private var kicked: Set<Int32> = []
    var budget: CaptureReadBudget
    /// How long after the first read of an identity burst the second one happens.
    var settle: TimeInterval

    init(source: CaptureSource, scheduler: CaptureScheduler = CaptureScheduler(), budget: CaptureReadBudget = CaptureReadBudget(), settle: TimeInterval = 0.35,
         mayRead: @escaping (CaptureApp) -> Bool, ocrRegions: @escaping (CaptureSnapshot) -> [CapturePipeline.OCRRegion] = { _ in [] }) {
        self.source = source
        self.scheduler = scheduler
        self.budget = budget
        self.settle = settle
        self.may = mayRead
        self.regions = ocrRegions
    }

    func onEvent(_ event: CaptureEvent, now: TimeInterval) { scheduler.onEvent(event, now: now) }

    func retry(_ app: CaptureApp, now: TimeInterval, attempt: Int) { scheduler.requeue(app, now: now, attempt: attempt) }

    /// Drops everything waiting, for when capture is switched off.
    func reset() {
        scheduler = CaptureScheduler(debounce: scheduler.debounce, maxWait: scheduler.maxWait)
        awaiting = [:]
    }

    /// When the loop should run next, or nil when nothing is waiting.
    var nextWake: TimeInterval? {
        [scheduler.nextDue, awaiting.values.map(\.confirmAt).min()].compactMap { $0 }.min()
    }

    func readDue(now: TimeInterval) -> [CaptureRead] {
        var out: [CaptureRead] = []
        for pid in awaiting.filter({ $0.value.confirmAt <= now }).map(\.key) {
            guard let waiting = awaiting.removeValue(forKey: pid) else { continue }
            // Pause, private mode or an exclusion may have started in between.
            guard may(waiting.app) else { continue }
            if let snapshot = read(waiting.app) { out.append(CaptureRead(snapshot: snapshot, earlier: waiting.snapshot, attempt: waiting.attempt)) }
        }
        for due in scheduler.takeDue(now: now) {
            guard may(due.app) else { continue }
            if source.isWebApp(due.app), kicked.insert(due.app.pid).inserted { source.enableWebAccessibility(due.app) }
            guard let snapshot = read(due.app) else { continue }
            if due.identity && settle > 0 {
                awaiting[due.app.pid] = Awaiting(app: due.app, snapshot: snapshot, confirmAt: now + settle, attempt: due.attempt)
            } else {
                out.append(CaptureRead(snapshot: snapshot, earlier: nil, attempt: due.attempt))
            }
        }
        return out
    }

    private func read(_ app: CaptureApp) -> CaptureSnapshot? {
        guard var snapshot = source.readFocusedWindow(of: app, budget: budget) else { return nil }
        // A screen rectangle shows whatever is on top, so it is read only while the window's app is frontmost.
        if source.frontmostApp()?.pid == app.pid {
            for region in regions(snapshot) {
                if let lines = source.readText(in: region.rect) { snapshot.ocr[region.name] = lines }
            }
        }
        return snapshot
    }
}
