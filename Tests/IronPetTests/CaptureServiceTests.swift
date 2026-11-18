import XCTest
@testable import IronPet

final class CaptureServiceTests: XCTestCase {
    private var store: CaptureStore!
    private var source: FakeCaptureSource!
    private var accessibilityRequests = 0
    private var screenRequests = 0
    private var uptime: TimeInterval = 0
    private var config = Config.ScreenCapture()

    override func setUp() {
        super.setUp()
        store = CaptureFixtures.store()
        source = FakeCaptureSource()
        accessibilityRequests = 0
        screenRequests = 0
        uptime = 0
        config = Config.ScreenCapture()
    }

    private func makeService(screenGranted: Bool = false) -> CaptureService {
        var deps = CaptureService.Dependencies()
        deps.makeSource = { [unowned self] in source }
        deps.requestAccessibility = { [unowned self] in accessibilityRequests += 1; return true }
        deps.requestScreenRecording = { [unowned self] in screenRequests += 1; return true }
        deps.accessibilityGranted = { true }
        deps.screenRecordingGranted = { screenGranted }
        deps.screenLocked = { false }
        deps.now = { Date(timeIntervalSince1970: 1_800_000_000) }
        deps.uptime = { [unowned self] in uptime }
        return CaptureService(store: store, config: { [unowned self] in config }, dependencies: deps)
    }

    func testWithTheSwitchOffNothingStartsAndNothingIsRequested() {
        let service = makeService()
        service.apply(config)
        service.queue.sync {}
        XCTAssertFalse(source.started)
        XCTAssertEqual(accessibilityRequests + screenRequests, 0)
        XCTAssertFalse(service.isRunning)
    }

    func testTurningTheSwitchOnStartsTheSourceAndOffStopsIt() {
        let service = makeService()
        config.enabled = true
        service.apply(config)
        service.queue.sync {}
        XCTAssertTrue(source.started)
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(screenRequests, 0, "Screen Recording is not asked for until the screenshot fallback is on")
        config.enabled = false
        service.apply(config)
        service.queue.sync {}
        XCTAssertTrue(source.stopped)
        XCTAssertFalse(service.isRunning)
    }

    func testScreenRecordingIsAskedForOnlyWhenTheFallbackIsTurnedOn() {
        let service = makeService()
        config.enabled = true
        service.apply(config)
        service.queue.sync {}
        config.ocr = true
        service.apply(config)
        service.apply(config)
        service.queue.sync {}
        XCTAssertEqual(screenRequests, 1, "once, not on every settings change")
    }

    func testASignalAndTheTimeItWaitsForTakeOneCapture() {
        let service = makeService()
        config.enabled = true
        source.root = CaptureFixtures.slack(messages: ["Can you review PR 4649?"])
        service.apply(config)
        service.queue.sync {
            service.runDue(at: 0)
            service.receive(.key, at: 1)
            service.runDue(at: 1.2)
            XCTAssertEqual(store.captureCount, 0, "still typing")
            service.runDue(at: 1.6)
        }
        XCTAssertEqual(store.captureCount, 1)
        XCTAssertEqual(store.recent(limit: 1)[0].trigger, "typing_pause")
        service.apply(Config.ScreenCapture())
        service.queue.sync {}
    }

    func testTheOwnAppIsNeverCaptured() {
        let service = makeService()
        config.enabled = true
        source.app = CaptureApp(bundleId: AXCaptureSource.ownBundleId, name: "ironpet", pid: 1)
        source.root = CaptureFixtures.slack(messages: ["hello"])
        service.apply(config)
        service.queue.sync {
            service.receive(.click, at: 1)
            service.runDue(at: 1.3)
        }
        XCTAssertEqual(store.captureCount, 0)
        XCTAssertEqual(source.reads, 0)
        service.apply(Config.ScreenCapture())
        service.queue.sync {}
    }
}
