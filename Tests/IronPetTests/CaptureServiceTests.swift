import XCTest
@testable import IronPet

/// A source with no screen behind it. It counts what the service asks of it.
private final class FakeSource: CaptureSource {
    private let lock = NSLock()
    private var _starts = 0, _stops = 0, _reads = 0, _readOnMain = 0, _texts = 0
    var trusted = true
    var lines = ["Please send the invoice to Dana by Friday"]
    var title = "Plan"
    private var onEvent: ((CaptureEvent) -> Void)?
    let app = CaptureApp(bundleId: "com.example.notepad", name: "Notepad", pid: 42)

    var starts: Int { lock.withLock { _starts } }
    var stops: Int { lock.withLock { _stops } }
    var reads: Int { lock.withLock { _reads } }
    var readsOnMain: Int { lock.withLock { _readOnMain } }

    func start(onEvent: @escaping (CaptureEvent) -> Void) {
        lock.withLock { _starts += 1; self.onEvent = onEvent }
    }
    func stop() { lock.withLock { _stops += 1; onEvent = nil } }
    var isTrusted: Bool { trusted }
    func frontmostApp() -> CaptureApp? { app }
    func isWebApp(_ app: CaptureApp) -> Bool { false }
    func enableWebAccessibility(_ app: CaptureApp) {}
    func readText(in rect: CaptureRect) -> [String]? { lock.withLock { _texts += 1 }; return nil }

    func readFocusedWindow(of app: CaptureApp, budget: CaptureReadBudget) -> CaptureSnapshot? {
        lock.withLock { _reads += 1; if Thread.isMainThread { _readOnMain += 1 } }
        let children = lines.enumerated().map {
            CaptureNode(role: "StaticText", value: $1, frame: CaptureRect(x: 20, y: 100 + Double($0) * 20, width: 400, height: 18))
        }
        return CaptureSnapshot(app: app, windowTitle: title, root: CaptureNode(role: "Window", frame: CaptureRect(x: 0, y: 0, width: 800, height: 600), children: children))
    }

    func fire(_ kind: CaptureEventKind = .focusChanged) {
        let handler = lock.withLock { onEvent }
        handler?(CaptureEvent(app: app, kind: kind))
    }
}

private final class Spies {
    var sources: [FakeSource] = []
    var accessibilityRequests = 0
    var screenChecks = 0
    var decisionCalls = 0
    var runs = 0
}

private struct SpyRunner: CaptureModelRunning {
    let spies: Spies
    func run(agent: ACPAgent, model: String?, prompt: String, workspace: URL) async -> Result<String, CaptureRunError> {
        spies.runs += 1
        return .success("{}")
    }
}

private struct SpyDecision: CaptureDecisionClient {
    let spies: Spies
    func probabilities(text: String, existingTasks: [String: String], questions: [(name: String, instructions: String)]) async throws -> [String: Double] {
        spies.decisionCalls += 1
        return Dictionary(uniqueKeysWithValues: questions.map { ($0.name, 0.05) })
    }
}

final class CaptureServiceTests: XCTestCase {
    private func service(_ spies: Spies, enabled: Bool, store: CaptureStore = .inMemory(), trusted: Bool = true) -> (CaptureService, Box) {
        let box = Box(Config.ScreenCapture(enabled: enabled, sendApps: ["com.example.notepad"]))
        var deps = CaptureService.Dependencies()
        deps.screenLocked = { false }
        deps.makeSource = {
            let source = FakeSource()
            source.trusted = trusted
            spies.sources.append(source)
            return source
        }
        deps.requestAccessibility = { spies.accessibilityRequests += 1; return false }
        deps.accessibilityGranted = { trusted }
        deps.screenRecordingGranted = { spies.screenChecks += 1; return false }
        let filter = CaptureDecisionFilter(settings: { box.config.decision }, makeClient: { _, _ in SpyDecision(spies: spies) })
        let service = CaptureService(store: store, config: { box.config }, filter: filter, runner: SpyRunner(spies: spies),
                                     resolveAgent: { _ in ACPAgent(id: "claude", name: "Claude", command: "claude", args: [], helper: nil) }, dependencies: deps)
        // The test body may not use the service after its first call, and Swift can free it then, which would cancel its timers.
        kept.append((service, box))
        return (service, box)
    }

    private var kept: [(CaptureService, Box)] = []

    override func tearDown() {
        for (service, box) in kept {
            box.config.enabled = false
            service.apply()
        }
        kept = []
    }

    private final class Box {
        var config: Config.ScreenCapture
        init(_ config: Config.ScreenCapture) { self.config = config }
    }

    private func settle(_ seconds: TimeInterval = 0.4) async { try? await Task.sleep(for: .seconds(seconds)) }

    // MARK: S1

    func testWithTheSwitchOffNothingStartsAndNothingIsRequested() async throws {
        let spies = Spies()
        let store = CaptureStore.inMemory()
        _ = try store.ingest(CaptureItem(app: CaptureApp(bundleId: "com.example.notepad", name: "Notepad"), threadKey: "k", threadTitle: "t",
                                         content: .page(title: "t", text: "Please send the invoice"), parser: "test"))
        let (service, _) = service(spies, enabled: false, store: store)
        XCTAssertFalse(Config().screenCapture.enabled, "off by default")
        service.apply()
        service.scheduleFilter()
        service.scheduleAnalysis()
        service.tick()
        await settle()
        XCTAssertFalse(service.isRunning)
        XCTAssertTrue(spies.sources.isEmpty, "no source is built, so no accessibility call can happen")
        XCTAssertEqual(spies.accessibilityRequests, 0, "no permission prompt")
        XCTAssertEqual(spies.screenChecks, 0)
        XCTAssertEqual(spies.decisionCalls, 0)
        XCTAssertEqual(spies.runs, 0)
        XCTAssertEqual(store.items(inState: "new").count, 1, "an old item is not filtered while off")
        XCTAssertTrue(store.sendLog().isEmpty)
    }

    func testTurningTheSwitchOnStartsAndOffStopsEverything() async throws {
        let spies = Spies()
        let (service, box) = service(spies, enabled: true, trusted: false)
        service.apply()
        await settle()
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(spies.sources.count, 1)
        XCTAssertEqual(spies.accessibilityRequests, 1, "the prompt appears only now")
        XCTAssertEqual(spies.sources[0].starts, 0, "the observer waits for Accessibility access")
        box.config.enabled = false
        service.apply()
        await settle()
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(spies.sources[0].stops, 1)
        service.apply()
        await settle()
        XCTAssertEqual(spies.sources.count, 1)
        XCTAssertEqual(spies.accessibilityRequests, 1)
    }

    /// `ConfigStore` publishes a change before it stores it, so a change handler that reads the live config sees the old value. The app
    /// passes the new value to `apply`, and the switch must follow it.
    func testApplyFollowsTheNewValueEvenWhenTheLiveConfigIsStillTheOldOne() async throws {
        let spies = Spies()
        let (service, box) = service(spies, enabled: false)
        var enabled = box.config
        enabled.enabled = true
        service.apply(enabled)
        await settle()
        XCTAssertTrue(service.isRunning, "the live config still says off, the new value says on")
        service.apply(box.config)
        await settle()
        XCTAssertFalse(service.isRunning)
    }

    // MARK: S4, S8 (loop)

    func testAnEventReadsOffTheMainThreadAndStoresOnceForUnchangedContent() async throws {
        let spies = Spies()
        let store = CaptureStore.inMemory()
        let (service, _) = service(spies, enabled: true, store: store)
        service.apply()
        await settle()
        let source = try XCTUnwrap(spies.sources.first)
        XCTAssertEqual(source.starts, 1)
        source.fire()
        source.fire(.valueChanged)
        try await waitFor("first item") { store.itemCount == 1 }
        XCTAssertEqual(source.readsOnMain, 0, "reads never run on the main thread")
        source.fire()
        try await waitFor("reads \(source.reads)") { source.reads >= 4 }
        XCTAssertEqual(store.itemCount, 1, "the same content read again stores nothing")
        source.lines.append("Book the dentist next week")
        source.fire(.valueChanged)
        try await waitFor("second item") { store.itemCount == 2 }
        XCTAssertEqual(store.recent(limit: 1).first?.body, "Book the dentist next week")
    }

    func testAPausedServiceReadsNothing() async throws {
        let spies = Spies()
        let store = CaptureStore.inMemory()
        let (service, _) = service(spies, enabled: true, store: store)
        service.apply()
        await settle()
        service.privacy.pause(for: 600)
        let source = try XCTUnwrap(spies.sources.first)
        source.fire()
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(source.reads, 0, "a paused app is never read")
        XCTAssertEqual(store.itemCount, 0)
    }

    func testTheLocalFilterRunsOnNewItemsAndTheSendWaitsForTheDelay() async throws {
        let spies = Spies()
        let store = CaptureStore.inMemory()
        let (service, _) = service(spies, enabled: true, store: store)
        service.apply()
        await settle()
        let source = try XCTUnwrap(spies.sources.first)
        source.fire()
        try await waitFor("ready") { store.count(inState: "ready") == 1 }
        XCTAssertGreaterThan(spies.decisionCalls, 0)
        XCTAssertEqual(spies.runs, 0, "three minutes of quiet have not passed")
        XCTAssertNotNil(service.analyzer.dueDate())
    }

    private func waitFor(_ what: @autoclosure () -> String, _ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what())") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
