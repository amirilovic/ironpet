import AppKit
import SwiftUI
import XCTest
@testable import IronPet

/// The transcript viewport must never show only the background while the chat has messages.
@MainActor
final class TranscriptBlankTests: XCTestCase {
    private func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    private func scrollView(_ panel: NSPanel) -> NSScrollView? { HugeTranscriptTests.scrollView(in: panel.contentView) }

    private func render(_ panel: NSPanel) -> NSBitmapImageRep? {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

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
        return count
    }

    private func ink(_ panel: NSPanel) -> Double { visibleRows(panel) > 0 ? 1 : 0 }

    private func captureBaseline() {
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
            let share = ink(panel)
            if share < 0.01 { samples.append("blank while scrolling toward \(f): ink \(share)") }
        }
        spin(0.5)
    }

    private func expectContent(_ panel: NSPanel, _ label: String, _ failures: inout [String]) {
        spin(0.3)
        let share = ink(panel)
        if share < 0.01 { failures.append("\(label): ink \(share)") }
    }

    func testPinnedPasteThenStreamKeepsMessagesVisible() throws {
        captureBaseline()
        let (session, panel) = make(thread())
        var failures: [String] = []
        expectContent(panel, "open", &failures)
        session.items.append(.init(kind: .user(paste())))
        for k in 0..<8 { spin(0.2); expectContent(panel, "after paste \(k)", &failures) }
        session.items.append(.init(kind: .assistant("")))
        let last = session.items.count - 1
        var text = ""
        for i in 0..<150 {
            text += i % 9 == 0 ? "\n\n- item \(i) with a longer line that will wrap across the panel width.\n" : "word\(i) "
            session.items[last].kind = .assistant(text)
            spin(0.03)
            if i % 5 == 0 { expectContent(panel, "stream \(i)", &failures) }
        }
        panel.close()
        XCTAssertEqual(ChatView.blankRepairsForTesting, 0, "the blank viewport repair fired while rows were visible")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testReaderInHistoryWithPasteStaysVisible() throws {
        captureBaseline()
        var items = thread()
        items.insert(.init(kind: .user(paste())), at: 60)
        let (session, panel) = make(items)
        var failures: [String] = []
        for f in [0.5, 0.2, 0.7, 0.35] as [CGFloat] {
            wheel(panel, toFraction: f, samples: &failures)
            expectContent(panel, "at \(f)", &failures)
            session.items.append(.init(kind: .assistant("streamed \(f) " + String(repeating: "word ", count: 200))))
            session.items.append(.init(kind: .user(paste()), origin: ChatSession.telegramOrigin))
            for k in 0..<6 { spin(0.2); expectContent(panel, "at \(f) after arrivals \(k)", &failures) }
        }
        panel.close()
        XCTAssertEqual(ChatView.blankRepairsForTesting, 0, "the blank viewport repair fired while rows were visible")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testSendingLongPasteFromHistoryShowsMessages() throws {
        captureBaseline()
        let (session, panel) = make(thread())
        var failures: [String] = []
        wheel(panel, toFraction: 0.4, samples: &failures)
        session.items.append(.init(kind: .user(paste())))
        for k in 0..<10 { spin(0.2); expectContent(panel, "after send \(k)", &failures) }
        panel.close()
        XCTAssertEqual(ChatView.blankRepairsForTesting, 0, "the blank viewport repair fired while rows were visible")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// Guards the detector: a viewport pushed past the content must count as blank.
    func testDetectorSeesAViewportPastTheContent() throws {
        let (_, panel) = make(thread())
        XCTAssertGreaterThan(visibleRows(panel), 0)
        let scroll = try XCTUnwrap(scrollView(panel))
        let doc = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.bounds.height + 3000))
        spin(0.05)
        XCTAssertEqual(visibleRows(panel), 0, "the detector reported rows for a viewport past the content")
        panel.close()
    }

    /// The agent is working: typing indicator at the end while text streams and the reader switches position.
    func testRunningAgentWithPasteKeepsMessagesVisible() throws {
        var items = thread()
        items.insert(.init(kind: .user(paste())), at: 50)
        let (session, panel) = make(items)
        session.loadPreview(.approval)
        var failures: [String] = []
        for f in [0.6, 1.0, 0.1, 1.0] as [CGFloat] {
            wheel(panel, toFraction: f, samples: &failures)
            session.items.append(.init(kind: .tool("Ran `step`", ok: true)))
            session.items.append(.init(kind: .assistant(String(repeating: "streamed word ", count: 300))))
            for k in 0..<5 { spin(0.2); expectContent(panel, "at \(f) running \(k)", &failures) }
        }
        panel.close()
        XCTAssertEqual(ChatView.blankRepairsForTesting, 0, "the blank viewport repair fired while rows were visible")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// A viewport pushed past the content is repaired once, and the rows come back without a reader scroll.
    func testRepairBringsRowsBackAfterOvershoot() throws {
        let (_, panel) = make(thread())
        let scroll = try XCTUnwrap(scrollView(panel))
        let doc = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.bounds.height + 3000))
        scroll.reflectScrolledClipView(scroll.contentView)
        spin(2)
        XCTAssertGreaterThan(visibleRows(panel), 0, "rows did not come back")
        XCTAssertGreaterThanOrEqual(ChatView.blankRepairsForTesting, 1)
        XCTAssertLessThanOrEqual(ChatView.blankRepairsForTesting, 2, "the repair kept firing")
        panel.close()
    }
}
