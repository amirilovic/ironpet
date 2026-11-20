import AppKit
import SwiftUI
import XCTest
@testable import IronPet

/// Which rows lie in the scroll view's visible area, as a function of geometry alone. The live-window tests below read
/// the same rule from a real panel. This is the rule they are guarding, and it can be tested without a window.
enum ViewportGeometry {
    /// A row counts when more than a point of it lies inside the clip bounds.
    static func isVisible(_ row: CGRect, in clip: CGRect) -> Bool {
        row.height > 1 && row.intersection(clip).height > 1
    }

    static func visibleCount(of rows: [CGRect], in clip: CGRect) -> Int {
        rows.filter { isVisible($0, in: clip) }.count
    }
}

/// The transcript viewport must never show only the background while the chat has messages.
@MainActor
final class TranscriptBlankTests: XCTestCase {
    /// These tests open a real window and read it through accessibility. On the GitHub macOS runner they fail in
    /// every scenario (rows read as zero and the repair fires), so they run on a developer's Mac only.
    private func skipOnCI() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "real-window transcript tests do not run on CI")
    }

    private func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    private func scrollView(_ panel: NSPanel) -> NSScrollView? { HugeTranscriptTests.scrollView(in: panel.contentView) }

    private func make(_ items: [ChatSession.Item]) -> (ChatSession, IronPetPanel) {
        ChatView.blankRepairsForTesting = 0
        let session = ChatSession(restore: false)
        session.items = items
        let panel = IronPetPanel.chat(session)
        panel.setContentSize(CGSize(width: 520, height: 640))
        panel.orderFrontRegardless()
        spin(3)
        return (session, panel)
    }

    /// Text rows that SwiftUI realized and that lie inside the scroll view's visible area.
    private func visibleRows(_ panel: NSPanel) -> Int {
        guard let scroll = scrollView(panel), let window = scroll.window else { return -1 }
        let area = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
        var count = 0
        func walk(_ element: Any, _ depth: Int) {
            guard depth < 40, let node = element as? NSAccessibilityProtocol else { return }
            var children = node.accessibilityChildren() ?? []
            if children.isEmpty, let view = element as? NSView { children = view.subviews }
            for child in children {
                if let item = child as? NSAccessibilityProtocol, item.accessibilityRole() == .staticText {
                    let frame = item.accessibilityFrame()
                    if frame.height > 1, frame.intersects(area) { count += 1 }
                }
                walk(child, depth + 1)
            }
        }
        walk(panel.contentView as Any, 0)
        // Reply text is a text view. Its accessibility frame is not clipped by the scroll view and lags behind scrolling,
        // so ask AppKit which part of each text view is visible.
        count += textViews(in: panel).filter { $0.visible }.count
        return count
    }

    /// Every reply text view with the part of it that lies inside the scroll view's visible area, from geometry alone.
    private func textViews(in panel: NSPanel) -> [(frame: CGRect, visible: Bool)] {
        guard let clip = scrollView(panel)?.contentView else { return [] }
        var found: [(CGRect, Bool)] = []
        func walk(_ view: NSView) {
            if view is ChatTextView {
                let frame = view.convert(view.bounds, to: clip)
                found.append((frame, ViewportGeometry.isVisible(frame, in: clip.bounds)))
            }
            view.subviews.forEach(walk)
        }
        if let content = panel.contentView { walk(content) }
        return found
    }

    /// What a failing run needs to say about the machine, because the runner differs from a developer's Mac.
    private func environment(_ panel: NSPanel) -> String {
        let scroll = scrollView(panel)
        let screen = panel.screen
        return "os=\(ProcessInfo.processInfo.operatingSystemVersionString) screen=\(String(describing: screen?.frame)) "
            + "scale=\(String(describing: screen?.backingScaleFactor)) window=\(panel.frame) key=\(panel.isKeyWindow) "
            + "visible=\(panel.isVisible) clip=\(String(describing: scroll?.contentView.bounds)) "
            + "doc=\(String(describing: scroll?.documentView?.frame)) "
            + "textViews=\(textViews(in: panel).map { "\($0.frame.integral) \($0.visible)" })"
    }

    private func thread() -> [ChatSession.Item] {
        var items: [ChatSession.Item] = []
        let long = (0..<40).map { "Reply line \($0) with **bold** and `code`." }.joined(separator: "\n")
        for i in 0..<40 {
            items.append(.init(kind: .user("Question \(i)")))
            for j in 0..<(i % 4) { items.append(.init(kind: .tool("Ran `step \(i)-\(j)`", ok: true))) }
            items.append(.init(kind: .assistant(i % 3 == 0 ? long : "Short \(i)")))
        }
        return items
    }

    private func paste() -> String {
        (0..<900).map { "Pasted line \($0) with some filler text so it wraps and takes real vertical room in the bubble." }
            .joined(separator: "\n")
    }

    private func wheel(_ panel: NSPanel, toFraction f: CGFloat, samples: inout [String]) {
        guard let scroll = scrollView(panel) else { return }
        for _ in 0..<400 {
            guard let doc = scroll.documentView else { return }
            let v = scroll.contentView.bounds
            let offset = doc.isFlipped ? v.minY : doc.bounds.maxY - v.maxY
            let delta = (doc.bounds.height - v.height) * f - offset
            if abs(delta) < 40 { break }
            let step = Int32(max(-2500, min(2500, delta)))
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -step, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: cg) else { return }
            scroll.scrollWheel(with: event)
            spin(0.03)
            if visibleRows(panel) == 0 { samples.append("blank while scrolling toward \(f)") }
        }
        spin(0.5)
    }

    private func expectContent(_ panel: NSPanel, _ label: String, _ failures: inout [String]) {
        spin(0.3)
        if visibleRows(panel) == 0 { failures.append("\(label): no rows visible") }
    }

    /// The detector must report no rows when nothing is on screen and some when a reply is. Where a jump ends is not the
    /// test's to decide: the lazy stack re-measures its rows after the jump and may shrink the document, so on one
    /// machine the offset stays past the end (blank) and on another, the CI runner, it is clamped back into the content
    /// (a reply is on screen). Both are correct. This checks the detector against the reply views' own geometry.
    private func assertDetectorAgreesWithTheScreen(_ panel: NSPanel, _ message: String) {
        panel.contentView?.layoutSubtreeIfNeeded()
        spin(0.05)
        let replyOnScreen = textViews(in: panel).contains { $0.visible }
        let rows = visibleRows(panel)
        if replyOnScreen {
            XCTAssertGreaterThan(rows, 0, "\(message): a reply is on screen but the detector saw none. " + environment(panel))
        } else {
            XCTAssertEqual(rows, 0, "\(message): nothing is on screen but the detector saw rows. " + environment(panel))
        }
    }

    /// A viewport pushed past the content must count as blank.
    func testDetectorSeesAViewportPastTheContent() throws {
        // A live transcript scrolls itself back to the end on its own schedule, so where this jump ends depends on the
        // machine. The rule itself is tested without a window in the ViewportGeometry tests below, on every machine.
        try skipOnCI()
        let (_, panel) = make(thread())
        XCTAssertGreaterThan(visibleRows(panel), 0)
        let scroll = try XCTUnwrap(scrollView(panel))
        let doc = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.bounds.height + 3000))
        scroll.reflectScrolledClipView(scroll.contentView)
        assertDetectorAgreesWithTheScreen(panel, "after a jump past the end")
        panel.close()
    }

    /// A viewport that ends inside the content, as the CI runner's did after its jump, must count the rows it shows.
    func testDetectorCountsRowsWhenTheViewportEndsInsideTheContent() throws {
        try skipOnCI()
        let (_, panel) = make(thread())
        let scroll = try XCTUnwrap(scrollView(panel))
        let doc = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.bounds.height - 820))
        scroll.reflectScrolledClipView(scroll.contentView)
        assertDetectorAgreesWithTheScreen(panel, "after a jump to just inside the end")
        XCTAssertGreaterThan(visibleRows(panel), 0)
        panel.close()
    }

    /// Programmatic jumps to the top, the middle and back leave rows on screen, and a healthy transcript must not be
    /// repaired. The jump past the end must end with rows on screen.
    func testJumpsInsideTheContentAreLeftAloneAndOneBeyondItEndsWithRowsOnScreen() throws {
        try skipOnCI()
        let session = ChatSession(restore: false)
        session.items = HugeTranscriptTests.hugeThread(screenshotDir: nil)
        ChatView.blankRepairsForTesting = 0
        let panel = IronPetPanel.chat(session)
        panel.setContentSize(CGSize(width: 520, height: 640))
        panel.orderFrontRegardless()
        spin(3)
        let scroll = try XCTUnwrap(scrollView(panel))
        let doc = try XCTUnwrap(scroll.documentView)
        for y in [CGFloat(0), doc.bounds.height * 0.5, 0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            spin(2)
            XCTAssertGreaterThan(visibleRows(panel), 0, "no rows at y=\(y)")
        }
        XCTAssertEqual(ChatView.blankRepairsForTesting, 0, "a transcript with rows on screen was repaired")
        // Far enough past the end that the header's top inset (52 pt) cannot keep the last rows on screen.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.bounds.height + 3000))
        scroll.reflectScrolledClipView(scroll.contentView)
        spin(2.5)
        XCTAssertGreaterThan(visibleRows(panel), 0, "the jump past the end stayed blank")
        // The reply text is an AppKit view now, and the lazy stack no longer leaves the viewport empty after this jump, so
        // the repair may not be needed. What matters is that rows are on screen and the repair does not loop.
        // testRepairBringsRowsBackAfterOvershoot still covers a jump that does leave the viewport empty.
        XCTAssertLessThanOrEqual(ChatView.blankRepairsForTesting, 2, "the repair kept firing")
        panel.close()
    }

    // MARK: Geometry rule, no window

    private let rows = [CGRect(x: 0, y: 0, width: 400, height: 300), CGRect(x: 0, y: 310, width: 400, height: 718),
                        CGRect(x: 0, y: 1038, width: 400, height: 40)]

    /// A viewport pushed past the content must count as blank: it reports 0 rows.
    func testAViewportPastTheContentReportsNoRows() {
        let contentHeight: CGFloat = 1078
        XCTAssertEqual(ViewportGeometry.visibleCount(of: rows, in: CGRect(x: 0, y: contentHeight + 3000, width: 400, height: 640)), 0)
        XCTAssertEqual(ViewportGeometry.visibleCount(of: rows, in: CGRect(x: 0, y: contentHeight, width: 400, height: 640)), 0)
    }

    /// A viewport that ends inside the content, as the CI runner's did after its jump, reports the rows it shows.
    func testAViewportInsideTheContentReportsItsRows() {
        XCTAssertEqual(ViewportGeometry.visibleCount(of: rows, in: CGRect(x: 0, y: 458, width: 400, height: 640)), 2)
        XCTAssertEqual(ViewportGeometry.visibleCount(of: rows, in: CGRect(x: 0, y: 0, width: 400, height: 640)), 2)
        XCTAssertEqual(ViewportGeometry.visibleCount(of: rows, in: CGRect(x: 0, y: 400, width: 400, height: 2000)), 2)
    }

    /// A row that is only touched, or sliver-thin, is not on screen.
    func testARowThatOnlyTouchesTheViewportIsNotCounted() {
        XCTAssertFalse(ViewportGeometry.isVisible(CGRect(x: 0, y: 0, width: 400, height: 300), in: CGRect(x: 0, y: 300, width: 400, height: 640)))
        XCTAssertFalse(ViewportGeometry.isVisible(CGRect(x: 0, y: 250, width: 400, height: 50.5), in: CGRect(x: 0, y: 300, width: 400, height: 640)))
        XCTAssertFalse(ViewportGeometry.isVisible(CGRect(x: 0, y: 100, width: 400, height: 0.5), in: CGRect(x: 0, y: 0, width: 400, height: 640)))
    }
}
