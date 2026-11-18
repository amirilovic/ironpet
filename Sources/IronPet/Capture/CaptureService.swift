import AppKit
import Combine
import Foundation

/// What Settings, the Screen section and the pet menu show about screen capture.
@MainActor
final class CaptureStatusModel: ObservableObject {
    @Published var running = false
    @Published var accessibility = true
    @Published var screenRecording = false
    @Published var paused = false
    @Published var pausedUntil: Date?
    @Published var captureCount = 0
    @Published var lastCapture: Date?
    @Published var lastSkip: String?
}

/// A source that reports nothing and reads nothing. Test mode uses it, so an automated run never touches the real screen.
final class IdleCaptureSource: CaptureSource {
    func start(onSignal: @escaping (CaptureSignal) -> Void) {}
    func stop() {}
    var isTrusted: Bool { false }
    func frontmostApp() -> CaptureApp? { nil }
    func readFocusedWindow(of app: CaptureApp, budget: CaptureReadBudget) -> WindowRead? { nil }
    func recognizeFocusedWindow(of app: CaptureApp, windowID: UInt32?) -> [String]? { nil }
}

/// Runs the capture loop and owns the master switch. With the switch off nothing here starts: no source, no timer, no accessibility or
/// screen-recording request.
final class CaptureService: @unchecked Sendable {
    struct Dependencies {
        var makeSource: () -> CaptureSource = { AXCaptureSource() }
        /// Asks macOS for Accessibility access. Called only when the feature is on.
        var requestAccessibility: () -> Bool = {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        /// Asks macOS for Screen Recording access. Called only when the screenshot fallback is turned on.
        var requestScreenRecording: () -> Bool = { CGRequestScreenCaptureAccess() }
        var accessibilityGranted: () -> Bool = { AXIsProcessTrusted() }
        var screenRecordingGranted: () -> Bool = { CGPreflightScreenCaptureAccess() }
        var now: () -> Date = { Date() }
        /// Seconds from a clock that does not jump, for the scheduler.
        var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        /// Whether the screen is locked right now. The lock notifications only report changes.
        var screenLocked: () -> Bool = {
            (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        }
    }

    let store: CaptureStore
    let privacy: CapturePrivacy
    let pipeline: CapturePipeline
    @MainActor let model = CaptureStatusModel()

    private let live: () -> Config.ScreenCapture
    private let deps: Dependencies
    let queue = DispatchQueue(label: "ironpet.capture", qos: .utility)
    private var config: Config.ScreenCapture
    private var source: CaptureSource?
    private var scheduler = CaptureScheduler()
    private var wake: DispatchSourceTimer?
    private var permissionTimer: DispatchSourceTimer?
    private var started = false
    private var lockObservers: [NSObjectProtocol] = []
    private var lastPrune: Date?
    private var askedForScreenRecording = false

    init(store: CaptureStore, config: @escaping () -> Config.ScreenCapture, privacy: CapturePrivacy = CapturePrivacy(),
         dependencies: Dependencies = Dependencies()) {
        self.store = store
        self.live = config
        self.config = config()
        self.privacy = privacy
        self.deps = dependencies
        self.pipeline = CapturePipeline(privacy: privacy, store: store)
    }

    var isRunning: Bool { queue.sync { started } }

    // MARK: Master switch

    /// Starts or stops everything to match the setting. Safe to call whenever the config changes. Pass the new value when called from a
    /// change notification: `ConfigStore` publishes before it stores, so reading the live config there still gives the old one.
    func apply(_ new: Config.ScreenCapture? = nil) {
        let c = new ?? live()
        privacy.setExcluded(c.excludedApps)
        queue.async { [self] in
            config = c
            if c.enabled { start() } else { stop() }
            // The prompt belongs to turning the fallback on, so a user who never does never sees it.
            if c.enabled, c.ocr, !askedForScreenRecording, !deps.screenRecordingGranted() {
                askedForScreenRecording = true
                _ = deps.requestScreenRecording()
            }
            if !c.ocr { askedForScreenRecording = false }
            refreshModel()
        }
    }

    private func start() {
        guard !started else { return }
        started = true
        if !deps.accessibilityGranted() { _ = deps.requestAccessibility() }
        let source = deps.makeSource()
        self.source = source
        scheduler.reset()
        watchScreenLock()
        if source.isTrusted { begin(source) } else { waitForPermission() }
        prune()
    }

    private func begin(_ source: CaptureSource) {
        permissionTimer?.cancel()
        permissionTimer = nil
        source.start { [weak self] signal in
            self?.queue.async { [weak self] in self?.receive(signal) }
        }
        reschedule()
    }

    /// Accessibility access does not announce itself, so while it is missing the service looks again every few seconds.
    private func waitForPermission() {
        permissionTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self, self.started, let source = self.source else { return }
            if source.isTrusted {
                self.begin(source)
                self.refreshModel()
            }
        }
        permissionTimer = timer
        timer.resume()
    }

    private func stop() {
        guard started else { return }
        started = false
        wake?.cancel()
        wake = nil
        permissionTimer?.cancel()
        permissionTimer = nil
        source?.stop()
        source = nil
        scheduler.reset()
        for observer in lockObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        lockObservers = []
        privacy.setScreenLocked(false)
    }

    // MARK: Loop

    /// Records a signal. Must run on `queue`.
    func receive(_ signal: CaptureSignal, at uptime: TimeInterval? = nil) {
        guard started else { return }
        scheduler.signal(signal, at: uptime ?? deps.uptime())
        reschedule()
    }

    /// Sleeps until the next capture is due. Nothing polls faster than that.
    private func reschedule() {
        guard started else { return }
        let delay = max(0.02, scheduler.nextDue(now: deps.uptime()) - deps.uptime())
        wake?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in self?.runDue() }
        wake = timer
        timer.resume()
    }

    /// Takes the capture that is due, if any. Must run on `queue`. Tests call it with their own clock.
    func runDue(at uptime: TimeInterval? = nil) {
        guard started, let source else { return }
        defer { reschedule() }
        guard let trigger = scheduler.poll(now: uptime ?? deps.uptime()) else { return }
        guard let app = source.frontmostApp(), app.bundleId != AXCaptureSource.ownBundleId else { return }
        switch pipeline.capture(app: app, trigger: trigger, source: source, ocr: config.ocr && deps.screenRecordingGranted(), now: deps.now()) {
        case .stored:
            refreshModel(captured: true)
        case .unchanged:
            break
        case .skipped(let skip):
            noteSkip(skip)
        }
        prune()
    }

    private func noteSkip(_ skip: CaptureSkip) {
        let text = skip.description
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.model.lastSkip = text } }
    }

    /// Deletes captures older than the retention setting, at most every few hours.
    private func prune() {
        let now = deps.now()
        if let last = lastPrune, now.timeIntervalSince(last) < 6 * 3600 { return }
        lastPrune = now
        let days = config.retentionDays
        Task.detached(priority: .background) { [store] in store.prune(olderThanDays: days, now: now) }
    }

    // MARK: Screen lock

    private func watchScreenLock() {
        guard lockObservers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        // The notifications only report changes, so read the state the Mac is in now.
        if deps.screenLocked() { privacy.setScreenLocked(true) }
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false), ("com.apple.screensaver.didstart", true),
                               ("com.apple.screensaver.didstop", false)] {
            lockObservers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { [weak self] _ in
                self?.privacy.setScreenLocked(locked)
            })
        }
    }

    // MARK: Status

    func refreshModel(captured: Bool = false) {
        let running = started
        let count = store.captureCount
        let ax = deps.accessibilityGranted()
        let screen = deps.screenRecordingGranted()
        let paused = privacy.isPaused()
        let until = privacy.pausedUntilDate
        let now = deps.now()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let model = self?.model else { return }
                model.running = running
                model.captureCount = count
                model.accessibility = ax
                model.screenRecording = screen
                model.paused = paused
                model.pausedUntil = until
                if captured { model.lastCapture = now }
            }
        }
    }
}
