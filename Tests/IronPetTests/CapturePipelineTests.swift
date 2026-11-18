import CoreGraphics
import XCTest
import AppKit
@testable import IronPet

final class CapturePipelineTests: XCTestCase {
    private var store: CaptureStore!
    private var privacy: CapturePrivacy!
    private var pipeline: CapturePipeline!
    private var source: FakeCaptureSource!

    override func setUp() {
        super.setUp()
        store = CaptureFixtures.store()
        privacy = CapturePrivacy()
        pipeline = CapturePipeline(privacy: privacy, store: store)
        source = FakeCaptureSource()
    }

    private func capture(_ trigger: CaptureTrigger = .idle, ocr: Bool = false, at seconds: TimeInterval = 0) -> CapturePipeline.Outcome {
        pipeline.capture(app: source.app, trigger: trigger, source: source, ocr: ocr, now: Date(timeIntervalSince1970: 1_000_000 + seconds))
    }

    // MARK: S1

    func testTypingThenSendingStoresOneCaptureAfterThePauseAndOneAfterTheSend() {
        var scheduler = CaptureScheduler()
        var clock: TimeInterval = 0
        var outcomes: [CapturePipeline.Outcome] = []
        func advance(to end: TimeInterval) {
            while clock < end {
                clock += 0.05
                if let trigger = scheduler.poll(now: clock) { outcomes.append(capture(trigger, at: clock)) }
            }
        }
        let history = ["Can you review PR 4649?"]
        source.root = CaptureFixtures.slack(messages: history)
        scheduler.signal(.appSwitch, at: 0)
        advance(to: 0.5)
        XCTAssertEqual(store.captureCount, 1, "the app switch")

        // The user types for 5 seconds. Keys arrive every 100 ms and the composer fills up.
        advance(to: 1)
        var typed = ""
        for step in 0..<50 {
            typed += "word "
            source.root = CaptureFixtures.slack(messages: history, draft: typed)
            scheduler.signal(.key, at: clock)
            advance(to: 1 + Double(step + 1) * 0.1)
            XCTAssertEqual(store.captureCount, 1, "no capture while typing, step \(step)")
        }
        advance(to: clock + 0.6)
        XCTAssertEqual(store.captureCount, 2, "one capture after the typing pause")
        XCTAssertTrue(store.recent(limit: 1)[0].text.contains("word word"), "the pause capture holds the draft")

        // Enter: the draft is cleared and the message joins the list.
        source.root = CaptureFixtures.slack(messages: history + ["On it, I will look at it now."])
        scheduler.signal(.key, at: clock)
        advance(to: clock + 0.6)
        XCTAssertEqual(store.captureCount, 3, "one capture after the send")
        XCTAssertTrue(store.recent(limit: 1)[0].text.contains("On it, I will look at it now."))

        let everything = store.list(limit: 60).map(\.text).joined(separator: "\n")
        for label in ["Bold: off", "Italic: off", "Send now", "Strikethrough", "Message to Ana"] {
            XCTAssertFalse(everything.contains(label), "stored text has the control label \(label)")
        }
        XCTAssertEqual(outcomes.filter { if case .stored = $0 { return true } else { return false } }.count, 3)
    }

    // MARK: S2

    func testAWindowWithNoTextIsReadFromAScreenshotOnlyWhenAllowed() {
        source.root = AXNode(role: "Window", children: [AXNode(role: "Button", title: "Close")])
        source.ocrLines = ["Invoice 4649", "Due on Friday"]
        XCTAssertEqual(capture(ocr: false), .skipped(.noText))
        XCTAssertEqual(source.ocrCalls, 0, "no screenshot when the fallback is off")
        XCTAssertEqual(store.captureCount, 0)
        guard case .stored = capture(ocr: true) else { return XCTFail("expected a stored capture") }
        XCTAssertEqual(source.ocrCalls, 1)
        XCTAssertEqual(store.recent(limit: 1)[0].text, "Invoice 4649\nDue on Friday")
    }

    func testAWindowWithTextNeverTakesAScreenshot() {
        source.root = CaptureFixtures.slack(messages: ["hello"])
        _ = capture(ocr: true)
        XCTAssertEqual(source.ocrCalls, 0)
    }

    func testTheScreenshotFallbackFindsTextInAnImageAndLeavesNoFile() throws {
        let image = try XCTUnwrap(Self.render("Invoice 4649 is due on Friday"))
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
        let lines = try XCTUnwrap(ScreenOCR.recognize(image))
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
        let joined = lines.joined(separator: " ")
        XCTAssertTrue(joined.contains("4649"), joined)
        XCTAssertTrue(joined.lowercased().contains("friday"), joined)
        let images = after.subtracting(before).filter { ["png", "jpg", "jpeg", "tiff", "heic", "pdf"].contains(($0 as NSString).pathExtension.lowercased()) }
        XCTAssertEqual(images, [], "recognizing wrote no image file")
    }

    /// Black text on white, large enough for Vision.
    private static func render(_ text: String) -> CGImage? {
        let size = NSSize(width: 1400, height: 160)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 30, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 72), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    // MARK: S3

    func testASecondCaptureThatAddsTwoLinesStoresThemWithContextAndAnIdenticalThirdStoresNothing() {
        let first = (1...10).map { "message \($0)" }
        source.root = CaptureFixtures.slack(messages: first)
        guard case .stored = capture(at: 0) else { return XCTFail() }
        XCTAssertEqual(store.recent(limit: 1)[0].text.split(separator: "\n").count, 20, "the first capture holds the whole window")
        source.root = CaptureFixtures.slack(messages: first + ["message 11", "message 12"])
        guard case .stored = capture(at: 20) else { return XCTFail() }
        let second = store.recent(limit: 1)[0].text.split(separator: "\n").map(String.init)
        XCTAssertTrue(second.contains("message 11") && second.contains("message 12"))
        XCTAssertFalse(second.contains("message 1"), "the old lines are not stored again")
        XCTAssertLessThanOrEqual(second.count, 8, "two new lines plus a few lines of context, not the window: \(second)")
        XCTAssertEqual(capture(at: 40), .unchanged)
        XCTAssertEqual(store.captureCount, 2)
    }

    // MARK: S4

    func testSecretsAreRedactedAndAPasswordFieldIsNeverRead() {
        let key = "AKIA" + "IOSFODNN7EXAMPLE"
        let token = "ghp_" + String(repeating: "a1B2", count: 9)
        source.root = AXNode(role: "Window", children: [
            AXNode(role: "StaticText", value: "deploy with \(key) please"),
            AXNode(role: "StaticText", value: "token \(token)"),
            AXNode(role: "TextField", subrole: "SecureTextField", value: "correct horse battery staple"),
        ])
        guard case .stored = capture() else { return XCTFail() }
        let text = store.recent(limit: 1)[0].text
        XCTAssertFalse(text.contains(key) || text.contains(token) || text.contains("correct horse"), text)
        XCTAssertTrue(text.contains("[redacted:aws-key]") && text.contains("[redacted:github-token]"), text)
        XCTAssertEqual(store.search("AKIAIOSFODNN7EXAMPLE").count, 0, "the key is not in the index either")
    }

    func testADenyListedAppIsNeverRead() {
        for bundle in ["com.1password.1password", "com.bitwarden.desktop", "com.apple.keychainaccess"] {
            source.app = CaptureApp(bundleId: bundle, name: "Vault", pid: 5)
            XCTAssertEqual(capture(), .skipped(.deniedApp(bundle)))
        }
        XCTAssertEqual(source.reads, 0, "the window of a denied app is not even read")
        privacy.setExcluded(["Slack"])
        source.app = CaptureApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack", pid: 100)
        XCTAssertEqual(capture(), .skipped(.deniedApp("com.tinyspeck.slackmacgap")))
        XCTAssertEqual(store.captureCount, 0)
    }

    func testPausedLockedPrivateAndUnsafeWindowsAreSkipped() {
        source.root = CaptureFixtures.slack(messages: ["hi"])
        privacy.pause(for: 600, now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(capture(), .skipped(.paused))
        privacy.resume()
        privacy.setScreenLocked(true)
        XCTAssertEqual(capture(), .skipped(.locked))
        privacy.setScreenLocked(false)

        source.app = CaptureApp(bundleId: "com.apple.Safari", name: "Safari", pid: 7)
        source.title = "Example - Private Browsing"
        XCTAssertEqual(capture(), .skipped(.privateWindow))
        source.title = "Example"
        source.root = CaptureFixtures.slack(messages: ["hi"], url: "file:///Users/me/secret.txt")
        XCTAssertEqual(capture(), .skipped(.unsafeURL))
        source.root = CaptureFixtures.slack(messages: ["hi"], url: "https://vault.bitwarden.com/#/vault")
        XCTAssertEqual(capture(), .skipped(.deniedHost("vault.bitwarden.com")))
        XCTAssertEqual(store.captureCount, 0)
    }

    func testAPageAddressLosesItsSecretsBeforeItIsStored() {
        source.root = CaptureFixtures.slack(messages: ["hi"], url: "https://example.com/doc?id=7&token=abc123def456#section")
        guard case .stored(let id) = capture() else { return XCTFail() }
        let url = store.capture(id: id)?.url ?? ""
        XCTAssertTrue(url.contains("id=7"))
        XCTAssertFalse(url.contains("abc123def456"), url)
    }
}
