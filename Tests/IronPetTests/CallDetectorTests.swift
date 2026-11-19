import XCTest
@testable import IronPet

final class CallDetectorTests: XCTestCase {
    private var clients: [MicClient] = []
    private var time = Date(timeIntervalSince1970: 1000)
    private var started: [String] = []
    private var ended: [String] = []

    private func detector() -> CallDetector {
        let d = CallDetector(source: { [unowned self] in clients }, now: { [unowned self] in time }, debounce: 10,
                             ownPID: 100, ownBundleID: "dev.ironpet")
        d.onStarted = { [unowned self] in started.append($0) }
        d.onEnded = { [unowned self] in ended.append($0) }
        return d
    }

    private func advance(_ seconds: TimeInterval, _ d: CallDetector) {
        for _ in 0..<Int(seconds) {
            time += 1
            d.tick()
        }
    }

    private let whatsapp = MicClient(pid: 200, bundleID: "net.whatsapp.WhatsApp")

    func testStartsOnceAfterTenSeconds() {
        let d = detector()
        clients = [whatsapp]
        d.tick()
        advance(9, d)
        XCTAssertEqual(started, [])
        advance(1, d)
        XCTAssertEqual(started, ["net.whatsapp.WhatsApp"])
        advance(30, d)
        XCTAssertEqual(started.count, 1)
    }

    func testResetForgetsACallWithoutReportingAnEnd() {
        let d = detector()
        clients = [whatsapp]
        d.tick()
        advance(10, d)
        XCTAssertEqual(d.activeApps, ["net.whatsapp.WhatsApp"])
        d.reset()
        XCTAssertTrue(d.activeApps.isEmpty)
        XCTAssertEqual(ended, [])
        advance(9, d)
        XCTAssertEqual(started.count, 1, "a call still going after a restart waits out the debounce again")
    }

    func testShortBlipEmitsNothing() {
        let d = detector()
        clients = [whatsapp]
        d.tick()
        advance(3, d)
        clients = []
        advance(30, d)
        XCTAssertEqual(started, [])
        XCTAssertEqual(ended, [])
    }

    func testHelperMapsToParentApp() {
        let d = detector()
        clients = [MicClient(pid: 300, bundleID: "com.google.Chrome.helper.Renderer")]
        d.tick()
        advance(10, d)
        XCTAssertEqual(started, ["com.google.Chrome"])
    }

    func testIgnoresOwnAssistantsAndSystem() {
        let d = detector()
        clients = [MicClient(pid: 100, bundleID: "dev.ironpet"), MicClient(pid: 101, bundleID: "dev.ironpet"),
                   MicClient(pid: 102, bundleID: "com.apple.Siri"), MicClient(pid: 103, bundleID: "com.apple.assistant_service"),
                   MicClient(pid: 104, bundleID: "com.apple.speech.recognitiond"), MicClient(pid: 105, bundleID: "com.apple.coreaudiod"),
                   MicClient(pid: 106, bundleID: "")]
        d.tick()
        advance(60, d)
        XCTAssertEqual(started, [])
    }

    func testIgnoresWisprFlowDictation() {
        let d = detector()
        clients = [MicClient(pid: 200, bundleID: "com.electron.wispr-flow"), MicClient(pid: 201, bundleID: "com.electron.wispr-flow.helper")]
        d.tick()
        advance(60, d)
        XCTAssertEqual(started, [])
    }

    func testEndsAfterTenSecondsOfSilence() {
        let d = detector()
        clients = [whatsapp]
        d.tick()
        advance(10, d)
        clients = []
        advance(9, d)
        XCTAssertEqual(ended, [])
        advance(1, d)
        XCTAssertEqual(ended, ["net.whatsapp.WhatsApp"])
    }

    func testBriefDropDoesNotEndTheCall() {
        let d = detector()
        clients = [whatsapp]
        d.tick()
        advance(10, d)
        clients = []
        advance(4, d)
        clients = [whatsapp]
        advance(30, d)
        XCTAssertEqual(ended, [])
        XCTAssertEqual(started.count, 1)
    }
}

@MainActor
final class CallPromptTests: XCTestCase {
    private var enabled = true
    private var busy = false
    private let app = "net.whatsapp.WhatsApp"

    private func prompt() -> CallPrompt { CallPrompt(isEnabled: { self.enabled }, isBusy: { self.busy }) }

    func testOffersThenStaysQuietAfterNotNowUntilRelease() {
        let p = prompt()
        XCTAssertEqual(p.callStarted(app), .offerRecord(app))
        p.notNow(app)
        XCTAssertNil(p.callStarted(app))
        XCTAssertNil(p.callStarted(app))
        _ = p.callEnded(app)
        XCTAssertEqual(p.callStarted(app), .offerRecord(app))
    }

    func testNoOfferWhenSettingOffOrMeetingBusy() {
        let p = prompt()
        enabled = false
        XCTAssertNil(p.callStarted(app))
        enabled = true
        busy = true
        XCTAssertNil(p.callStarted(app))
    }

    func testOffersToStopWhenRecordedAppReleasesMic() {
        let p = prompt()
        p.accepted(app)
        busy = true
        XCTAssertEqual(p.callEnded(app), .offerStop(app))
        XCTAssertNil(p.callEnded(app))
    }

    func testNoStopOfferForAnotherApp() {
        let p = prompt()
        p.accepted(app)
        busy = true
        XCTAssertNil(p.callEnded("us.zoom.xos"))
    }
}

final class CallAppsTests: XCTestCase {
    func testWhatsAppIsPreselected() {
        let apps = [AudioApp(bundleID: "com.google.Chrome", name: "Chrome"), AudioApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp")]
        XCTAssertEqual(AudioApps.preselect(from: apps, remembered: ""), .app(apps[1]))
    }
}

@MainActor
final class CallMonitorTests: XCTestCase {
    private var clock: TimeInterval = 0
    private var time = Date(timeIntervalSince1970: 1000)

    private func make(_ query: @escaping @Sendable () -> [MicClient]) -> (CallMonitor, CallDetector) {
        let d = CallDetector(source: { [] }, now: { [unowned self] in time }, debounce: 10, ownPID: 100, ownBundleID: "dev.ironpet")
        let m = CallMonitor(detector: d, slowThreshold: 2, maxBackoff: 60, uptime: { [unowned self] in clock }, query: query)
        return (m, d)
    }

    private func pollAndWait(_ m: CallMonitor) {
        let done = expectation(description: "polled")
        m.onPolled = { done.fulfill() }
        m.poll()
        wait(for: [done], timeout: 5)
    }

    func testSlowSourceNeverBlocksMainAndTicksDoNotPileUp() {
        let release = DispatchSemaphore(value: 0)
        let calls = LockedCounter()
        let (m, _) = make { calls.increment(); _ = release.wait(timeout: .now() + 10); return [] }
        let done = expectation(description: "polled")
        m.onPolled = { done.fulfill() }
        var beats = 0
        let heart = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in beats += 1 }
        for _ in 0..<20 { m.poll() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        heart.invalidate()
        XCTAssertGreaterThan(beats, 4, "main thread kept running while the source blocked")
        XCTAssertEqual(calls.value, 1, "polls while a read is in flight are skipped")
        release.signal()
        wait(for: [done], timeout: 5)
    }

    func testBacksOffAfterSlowReadThenResumesAndReportsCall() {
        let whatsapp = MicClient(pid: 200, bundleID: "net.whatsapp.WhatsApp")
        let calls = LockedCounter()
        let (m, d) = make { calls.increment(); return [whatsapp] }
        var started: [String] = []
        d.onStarted = { started.append($0) }

        // First read "takes" 5 s on the fake clock.
        let done = expectation(description: "polled")
        m.onPolled = { done.fulfill() }
        m.poll()
        clock += 5
        wait(for: [done], timeout: 5)
        XCTAssertEqual(calls.value, 1)

        m.poll()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(calls.value, 1, "backoff blocks the next poll")

        clock += 10
        for _ in 0..<12 {
            time += 1
            pollAndWait(m)
        }
        XCTAssertGreaterThan(calls.value, 1)
        XCTAssertEqual(started, ["net.whatsapp.WhatsApp"])
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

final class MicIgnoreListTests: XCTestCase {
    private let dictate = MicClient(pid: 200, bundleID: "com.example.dictate")
    private let helper = MicClient(pid: 201, bundleID: "com.example.dictate.helper.Renderer")
    private let zoom = MicClient(pid: 202, bundleID: "us.zoom.xos")

    private func app(_ c: MicClient, ignored: [String]) -> String? {
        CallApps.app(for: c, ownPID: 1, ownBundleID: "dev.ironpet", ignored: ignored)
    }

    func testUserEntryIgnoresTheAppAndItsHelpers() {
        XCTAssertEqual(app(dictate, ignored: []), "com.example.dictate")
        XCTAssertNil(app(dictate, ignored: ["com.example.dictate"]))
        XCTAssertNil(app(helper, ignored: ["com.example.dictate"]))
        XCTAssertNil(app(dictate, ignored: ["COM.Example.Dictate"]))
        XCTAssertEqual(app(zoom, ignored: ["com.example.dictate"]), "us.zoom.xos")
    }

    func testBuiltInsStayIgnoredWithAnEmptyList() {
        for id in ["com.apple.Siri", "com.apple.dictation", "com.electron.wispr-flow"] {
            XCTAssertNil(app(MicClient(pid: 5, bundleID: id), ignored: []), id)
        }
    }

    func testOldConfigWithoutTheKeyLoadsEmpty() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"meetings":{"enabled":true}}"#.utf8).write(to: file)
        let loaded = Config.load(from: file)
        XCTAssertNil(loaded.error)
        XCTAssertEqual(loaded.config.meetings.ignoredMicApps, [])
        XCTAssertTrue(loaded.config.meetings.enabled)
    }

    func testConfigKeyRoundTripsAndDropsBadEntries() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"meetings":{"ignoredMicApps":["com.example.dictate"," ","com.","com.Example.Dictate","x"]}}"#.utf8).write(to: file)
        XCTAssertEqual(Config.load(from: file).config.meetings.ignoredMicApps, ["com.example.dictate"])
    }

    func testDetectorReadsTheCurrentListOnEveryTick() {
        var list: [String] = []
        var time = Date(timeIntervalSince1970: 1000)
        let d = CallDetector(source: { [self.dictate] }, now: { time }, debounce: 0, ownPID: 1, ownBundleID: "dev.ironpet",
                             ignored: { list })
        d.tick()
        XCTAssertEqual(d.activeApps, ["com.example.dictate"])
        list = ["com.example.dictate"]
        time += 1
        d.tick()
        XCTAssertEqual(d.activeApps, [])
    }

    @MainActor func testMicWatchHonoursTheList() {
        var list = ["com.example.dictate"]
        let clients = [dictate]
        let monitor = CallMonitor(detector: CallDetector(source: { [] }, debounce: 0, ownPID: 1, ownBundleID: "dev.ironpet",
                                                         ignored: { list }), query: { clients })
        let watch = MicWatch(monitor: monitor)
        let done = expectation(description: "polled")
        monitor.onPolled = { done.fulfill() }
        _ = watch.calls()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(watch.calls(), [])
        list = []
        monitor.detector.tick()
        XCTAssertEqual(watch.calls(), ["com.example.dictate"])
        watch.stop()
    }

    func testValidation() {
        let own = "dev.ironpet"
        func result(_ s: String, _ existing: [String] = []) -> MicIgnoreList.Rejection? {
            if case .failure(let r) = MicIgnoreList.validate(s, existing: existing, ownBundleID: own) { return r }
            return nil
        }
        XCTAssertEqual(result(""), .empty)
        XCTAssertEqual(result("   "), .empty)
        XCTAssertEqual(result("com"), .tooShort)
        XCTAssertEqual(result("com."), .tooShort)
        XCTAssertEqual(result(".app"), .tooShort)
        XCTAssertEqual(result("com.exa mple"), .hasSpaces)
        XCTAssertEqual(result("dev.IronPet"), .ironpet)
        XCTAssertEqual(result("com.example.a", ["com.Example.A"]), .duplicate)
        XCTAssertEqual(result("com.apple.dictation"), .alreadyBuiltIn)
        XCTAssertNil(result("  com.example.a  "))
        XCTAssertEqual(try? MicIgnoreList.validate(" com.example.a ").get(), "com.example.a")
    }
}

@MainActor
final class MicIgnoreModelTests: XCTestCase {
    private var saved: [String] = []
    private let dictate = MicIgnoreModel.AppInfo(name: "Dictate", url: URL(fileURLWithPath: "/Applications/Dictate.app"))

    private func model(entries: [String] = []) -> MicIgnoreModel {
        saved = entries
        let info = dictate
        return MicIgnoreModel(entries: { [unowned self] in saved }, save: { [unowned self] in saved = $0 },
                              resolve: { $0 == "com.example.dictate" ? info : nil }, ownBundleID: "dev.ironpet")
    }

    private func makeApp(identifier: String?) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleName": "Test"]
        if let identifier { plist["CFBundleIdentifier"] = identifier }
        try (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: app) }
        return app
    }

    func testRowsResolveInstalledAndUnknownApps() {
        let m = model(entries: ["com.example.dictate", "com.example.a"])
        XCTAssertEqual(m.rows, [.init(bundleID: "com.example.dictate", app: dictate), .init(bundleID: "com.example.a", app: nil)])
        XCTAssertEqual(m.rows.map(\.title), ["Dictate", "com.example.a"])
    }

    func testRemove() {
        let m = model(entries: ["com.example.dictate", "com.example.a"])
        m.remove("com.example.dictate")
        XCTAssertEqual(saved, ["com.example.a"])
    }

    func testAddRefusals() {
        let m = model(entries: ["com.example.dictate"])
        XCTAssertEqual(m.add("com.example.dictate"), .duplicate)
        XCTAssertEqual(m.add("dev.ironpet"), .ironpet)
        XCTAssertEqual(saved, ["com.example.dictate"])
    }

    func testAddPickedAppOnce() throws {
        let m = model()
        let app = try makeApp(identifier: "com.example.picked")
        XCTAssertNil(m.add(appAt: app))
        XCTAssertEqual(saved, ["com.example.picked"])
        XCTAssertEqual(m.add(appAt: app), .rejected(.duplicate))
        XCTAssertEqual(saved, ["com.example.picked"])
    }

    func testAddPickedAppWithoutIdentifier() throws {
        let m = model()
        XCTAssertEqual(m.add(appAt: try makeApp(identifier: nil)), .noIdentifier)
        XCTAssertEqual(saved, [])
    }
}

@MainActor
final class CallOfferTests: XCTestCase {
    func testAlwaysIgnoreAddsTheParentIdAndClosesWithoutRecording() {
        var saved: [String] = []
        var recorded = false, snoozed = false, closed = false
        let model = MicIgnoreModel(entries: { saved }, save: { saved = $0 }, ownBundleID: "dev.ironpet")
        let actions = CallOffer.recordActions(
            bundleID: "com.example.dictate.helper.Renderer", name: "Dictate", ignore: model,
            record: { recorded = true }, notNow: { snoozed = true }, close: { closed = true })
        XCTAssertEqual(actions.map(\.title), ["Record", "Not now", "Always ignore Dictate"])
        actions[2].run()
        XCTAssertEqual(saved, ["com.example.dictate"])
        XCTAssertTrue(closed)
        XCTAssertFalse(recorded)
        XCTAssertFalse(snoozed)
        // Pressing it again, or for a built-in, still closes and adds nothing.
        closed = false
        actions[2].run()
        XCTAssertEqual(saved, ["com.example.dictate"])
        XCTAssertTrue(closed)
    }

    func testRecordAndNotNowStillWork() {
        var log: [String] = []
        let model = MicIgnoreModel(entries: { [] }, save: { _ in }, ownBundleID: nil)
        let actions = CallOffer.recordActions(bundleID: "us.zoom.xos", name: "zoom", ignore: model,
                                              record: { log.append("record") }, notNow: { log.append("notNow") }, close: { log.append("close") })
        actions[0].run()
        actions[1].run()
        XCTAssertEqual(log, ["close", "record", "notNow", "close"])
    }
}
