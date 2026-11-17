import AppKit
import Combine
import Foundation

/// What Settings and the pet menu show about screen capture.
@MainActor
final class CaptureStatusModel: ObservableObject {
    @Published var running = false
    @Published var accessibility = true
    @Published var screenRecording = false
    @Published var paused = false
    @Published var pausedUntil: Date?
    @Published var sending = false
    @Published var itemCount = 0
    @Published var pendingCount = 0
    @Published var localOnlyCount = 0
    @Published var sendLog: [CaptureSendRecord] = []
    @Published var decision: CaptureDecisionFilter.Status = .unknown
    @Published var lastSkip: String?
    @Published var rules: [CaptureRuleSet.Info] = []
    @Published var nextSend: Date?
}

/// Runs the capture loop and the steps after it, and owns the master switch. With the switch off nothing here starts: no source, no
/// timer, no accessibility or screen-recording request, no decision call and no larger-model run.
final class CaptureService: @unchecked Sendable {
    struct Dependencies {
        var makeSource: () -> CaptureSource = { AXCaptureSource() }
        /// Asks macOS for Accessibility access. Called only when the feature is on.
        var requestAccessibility: () -> Bool = {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        var accessibilityGranted: () -> Bool = { AXIsProcessTrusted() }
        var screenRecordingGranted: () -> Bool = { CGPreflightScreenCaptureAccess() }
        var now: () -> Date = { Date() }
        /// Whether the screen is locked right now. The lock notifications only report changes.
        var screenLocked: () -> Bool = {
            (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        }
    }

    let store: CaptureStore
    let privacy: CapturePrivacy
    let rules: CaptureRules
    let pipeline: CapturePipeline
    let filter: CaptureDecisionFilter
    let analyzer: CaptureAnalyzer
    @MainActor let model = CaptureStatusModel()

    /// The settings as of the last `apply()`. The capture queue and the analysis tasks read this copy, never the live config, which the
    /// main thread writes.
    private final class Snapshot {
        private let lock = NSLock()
        private var value: Config.ScreenCapture
        init(_ value: Config.ScreenCapture) { self.value = value }
        var current: Config.ScreenCapture {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private let live: () -> Config.ScreenCapture
    let tasks: CaptureTaskList
    private let snapshot: Snapshot
    private var config: Config.ScreenCapture { snapshot.current }
    private let deps: Dependencies
    private let queue = DispatchQueue(label: "ironpet.capture", qos: .utility)
    private var source: CaptureSource?
    private var reader: CaptureReader?
    private var wake: DispatchSourceTimer?
    private var analysisTimer: DispatchSourceTimer?
    private var permissionTimer: DispatchSourceTimer?
    private var filtering = false
    private var started = false
    private var lockObservers: [NSObjectProtocol] = []
    private var lastPrune: Date?
    private var lastPurge: Date?

    /// Called on the main thread with the suggestions of a run.
    @MainActor var onProposals: ([CaptureProposal]) -> Void = { _ in }

    init(store: CaptureStore, config: @escaping () -> Config.ScreenCapture, rules: CaptureRules = CaptureRules(), privacy: CapturePrivacy = CapturePrivacy(),
         filter: CaptureDecisionFilter? = nil, tasks: CaptureTaskList = SharedTaskList(), runner: CaptureModelRunning = ACPCaptureRunner(),
         resolveAgent: @escaping (String) -> ACPAgent? = { AgentCatalog.agent(id: $0) },
         workspace: URL = Paths.root.appendingPathComponent("capture/agent"), dependencies: Dependencies = Dependencies()) {
        let snapshot = Snapshot(config())
        self.store = store
        self.tasks = tasks
        self.live = config
        self.snapshot = snapshot
        self.rules = rules
        self.privacy = privacy
        self.deps = dependencies
        self.pipeline = CapturePipeline(privacy: privacy, rules: rules, store: store)
        self.filter = filter ?? CaptureDecisionFilter(settings: { snapshot.current.decision })
        self.analyzer = CaptureAnalyzer(store: store, tasks: tasks, settings: {
            let c = snapshot.current
            return .init(agent: c.agent, model: c.model, delay: c.delayMinutes * 60, sendApps: c.sendApps)
        }, runner: runner, resolveAgent: resolveAgent, workspace: workspace)
        self.filter.isEnabled = { snapshot.current.enabled }
        analyzer.isEnabled = { snapshot.current.enabled }
        analyzer.onProposals = { [weak self] proposals in
            guard let self else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onProposals(proposals) } }
        }
        analyzer.onSending = { [weak self] on in
            guard let self else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.model.sending = on } }
        }
    }

    var isRunning: Bool { queue.sync { started } }

    // MARK: Master switch

    /// Starts or stops everything to match the setting. Safe to call whenever the config changes. Pass the new value when called from a
    /// change notification: `ConfigStore` publishes before it stores, so reading the live config there still gives the old one.
    func apply(_ new: Config.ScreenCapture? = nil) {
        let c = new ?? live()
        snapshot.current = c
        privacy.setExcluded(c.excludedApps)
        if c.enabled { start() } else { stop() }
    }

    private func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            if !deps.accessibilityGranted() { _ = deps.requestAccessibility() }
            let source = deps.makeSource()
            self.source = source
            reader = CaptureReader(source: source, mayRead: { [pipeline] in pipeline.mayRead($0) }, ocrRegions: { [weak self] snapshot in
                guard let self, self.deps.screenRecordingGranted() else { return [] }
                return self.pipeline.ocrRegions(for: snapshot)
            })
            watchScreenLock()
            if source.isTrusted {
                begin(source)
            } else {
                waitForPermission()
            }
            refreshModel()
            scheduleFilter()
            scheduleAnalysis()
        }
    }

    private func begin(_ source: CaptureSource) {
        permissionTimer?.cancel()
        permissionTimer = nil
        source.start { [weak self] event in
            self?.queue.async { [weak self] in
                guard let self, self.started else { return }
                self.reader?.onEvent(event, now: ProcessInfo.processInfo.systemUptime)
                self.reschedule()
            }
        }
        prune()
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
        queue.async { [self] in
            guard started else { return }
            started = false
            wake?.cancel()
            wake = nil
            analysisTimer?.cancel()
            analysisTimer = nil
            permissionTimer?.cancel()
            permissionTimer = nil
            source?.stop()
            source = nil
            reader?.reset()
            reader = nil
            for observer in lockObservers { DistributedNotificationCenter.default().removeObserver(observer) }
            lockObservers = []
            privacy.setScreenLocked(false)
            refreshModel()
        }
    }

    // MARK: Loop

    /// Sleeps until the next read is due. Nothing polls.
    private func reschedule() {
        guard started, let reader, let target = reader.nextWake else { return }
        let delay = max(0.02, target - ProcessInfo.processInfo.systemUptime)
        wake?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in self?.tick() }
        wake = timer
        timer.resume()
    }

    /// Reads what is due and runs it through the pipeline. Also what tests call.
    func tick() {
        guard started, let reader else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var changed = false
        let due = reader.readDue(now: now)
        for read in due {
            switch pipeline.process(read.snapshot, confirmedBy: read.earlier, now: deps.now()) {
            case .stored(_, let result):
                if result.itemId != nil { changed = true }
            case .skipped(.unsettled):
                if read.attempt < CaptureReader.maxConfirmAttempts { reader.retry(read.snapshot.app, now: now, attempt: read.attempt + 1) }
            case .skipped(let skip):
                noteSkip(skip)
            }
        }
        for form in reader.takeForms(now: now) {
            switch pipeline.process(form: form, now: deps.now()) {
            case .stored(_, let result): if result.itemId != nil { changed = true }
            case .skipped(let skip): noteSkip(skip)
            }
        }
        if changed {
            refreshModel()
            scheduleFilter()
        }
        prune()
        reschedule()
    }

    private func noteSkip(_ skip: CaptureSkip) {
        let text = skip.description
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.model.lastSkip = text } }
    }

    // MARK: Filter and analysis

    /// Runs the local decision model over new items, one pass at a time.
    func scheduleFilter() {
        queue.async { [self] in
            guard started, !filtering, store.count(inState: "new") > 0 else { return }
            filtering = true
            let (filter, store, tasks, queue) = (self.filter, self.store, self.tasks, self.queue)
            Task.detached(priority: .utility) {
                let done = await filter.run(on: store, tasks: tasks)
                queue.async { [weak self] in
                    guard let self else { return }
                    self.filtering = false
                    if done > 0 { self.analyzer.noteReady(at: self.deps.now()) }
                    self.refreshModel()
                    self.scheduleAnalysis()
                    // The model may be down. Look again in a minute, but only while something waits.
                    if self.started, store.count(inState: "new") > 0 {
                        queue.asyncAfter(deadline: .now() + 60) { [weak self] in self?.scheduleFilter() }
                    }
                }
            }
        }
    }

    /// Sets one timer for the moment the quiet period ends.
    func scheduleAnalysis() {
        queue.async { [self] in
            analysisTimer?.cancel()
            analysisTimer = nil
            guard started else { return }
            analyzer.holdUnallowed()
            guard let due = analyzer.dueDate() else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + max(0.05, due.timeIntervalSince(deps.now())))
            timer.setEventHandler { [weak self] in
                guard let self, self.started else { return }
                Task.detached(priority: .utility) {
                    _ = await self.analyzer.runIfDue(now: self.deps.now())
                    self.refreshModel()
                    self.scheduleAnalysis()
                }
            }
            analysisTimer = timer
            timer.resume()
        }
    }

    /// Deletes old items every few hours and unredacted originals past their 24 hours every few minutes.
    private func prune() {
        let now = deps.now()
        if lastPurge.map({ now.timeIntervalSince($0) >= 600 }) ?? true {
            lastPurge = now
            Task.detached(priority: .background) { [store] in store.purgeOriginals(now: now) }
        }
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

    func refreshModel() {
        let log = store.sendLog(limit: 30)
        let items = store.itemCount
        let pending = store.count(inState: "new") + store.count(inState: "ready")
        let local = store.count(inState: "local")
        let running = started
        let due = running ? analyzer.dueDate() : nil
        // Reading the rules loads them, which a switched-off service must not do.
        let rulesReport = running ? rules.report() : []
        let status = filter.status
        let ax = deps.accessibilityGranted()
        let screen = deps.screenRecordingGranted()
        let paused = privacy.isPaused()
        let until = privacy.pausedUntilDate
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let model = self?.model else { return }
                model.running = running
                model.sendLog = log
                model.itemCount = items
                model.pendingCount = pending
                model.localOnlyCount = local
                model.nextSend = due
                model.rules = rulesReport
                model.decision = status
                model.accessibility = ax
                model.screenRecording = screen
                model.paused = paused
                model.pausedUntil = until
            }
        }
    }

    /// Test mode only: answers analysis runs with `answer` and calls texts with `secretWords` secrets, without a model or an agent.
    func useStubs(answer: String, secretWords: [String]) {
        analyzer.runner = StubCaptureRunner(answer: answer)
        filter.makeClient = { _, _ in StubDecisionClient(secretWords: secretWords) }
    }

    /// Tests the local decision model from Settings.
    func testDecisionModel() async {
        _ = await filter.test()
        refreshModel()
    }

    /// Reloads the rules, including the user's folder `~/.ironpet/capture/rules`.
    func reloadRules() {
        rules.replace(CaptureRuleSet(folder: Self.rulesFolder))
        refreshModel()
    }

    static var rulesFolder: URL { Paths.root.appendingPathComponent("capture/rules") }

    // MARK: Proposals

    /// The user clicked Add. Creates the task in the Tasks section, or updates the open task the suggestion is about. The quote that
    /// justifies it goes into the notes, so the task says where it came from.
    @discardableResult
    func accept(_ proposal: CaptureProposal, title: String? = nil, due: String? = nil) async -> CaptureTask? {
        defer { refreshModel() }
        let origin = "From screen capture items \(proposal.sources.map(String.init).joined(separator: ", "))"
        switch proposal.kind {
        case .update:
            guard let id = proposal.taskId else { return nil }
            return await tasks.update(id: id, title: title ?? proposal.title, notes: proposal.notes, due: due ?? proposal.due,
                                      done: proposal.status == "done", note: origin)
        case .newTask, .followUp, .calendar:
            var notes = proposal.notes
            if proposal.kind == .calendar { notes += (notes.isEmpty ? "" : "\n") + "Calendar candidate" }
            if !proposal.quote.isEmpty { notes += (notes.isEmpty ? "" : "\n") + "\u{201C}\(proposal.quote)\u{201D}" }
            notes += (notes.isEmpty ? "" : "\n") + origin
            return await tasks.create(title: title ?? proposal.title, notes: notes, due: due ?? proposal.due)
        }
    }

    /// The user clicked Ignore. The same suggestion is not made again.
    func ignore(_ proposal: CaptureProposal) {
        store.ignore(fingerprint: proposal.id, kind: proposal.kind.rawValue)
    }
}
