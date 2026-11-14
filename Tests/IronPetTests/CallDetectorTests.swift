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
