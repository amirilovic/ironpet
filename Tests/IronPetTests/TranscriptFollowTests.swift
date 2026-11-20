import AppKit
import SwiftUI
import XCTest
@testable import IronPet

/// Pure rules for when the transcript follows new content.
final class TranscriptFollowLogicTests: XCTestCase {
    func testStartsPinned() {
        XCTAssertTrue(TranscriptFollow().pinned)
    }

    func testUserScrollingAwayUnpins() {
        var f = TranscriptFollow()
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        XCTAssertFalse(f.pinned)
    }

    func testContentGrowthWithoutUserInputKeepsUnpinned() {
        var f = TranscriptFollow()
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.geometryChanged(distanceFromBottom: 900, userDriven: false)
        XCTAssertFalse(f.pinned)
    }

    func testContentGrowthWhilePinnedDoesNotUnpin() {
        var f = TranscriptFollow()
        f.geometryChanged(distanceFromBottom: 300, userDriven: false)
        XCTAssertTrue(f.pinned)
    }

    func testUserScrollingBackToBottomPins() {
        var f = TranscriptFollow()
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.geometryChanged(distanceFromBottom: 5, userDriven: true)
        XCTAssertTrue(f.pinned)
    }

    func testArrivingAtBottomWithoutInputPins() {
        var f = TranscriptFollow()
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.geometryChanged(distanceFromBottom: 0, userDriven: false)
        XCTAssertTrue(f.pinned)
    }

    func testSendingAndJumpingPin() {
        var f = TranscriptFollow()
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.sent()
        XCTAssertTrue(f.pinned)
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.jumpedToLatest()
        XCTAssertTrue(f.pinned)
    }

    func testStatusChangeAfterTheReadersMessageDoesNotDragThemDown() {
        var f = TranscriptFollow()
        f.contentArrived(readerSent: true)
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.contentArrived(readerSent: false) // the agent starts running, an approval arrives
        XCTAssertFalse(f.pinned)
    }

    func testStatusOnlyChangeDoesNotOfferJumpToLatest() {
        var f = TranscriptFollow()
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.contentArrived(readerSent: false, newContent: false)
        XCTAssertFalse(f.newBelow)
    }

    func testReaderSendingWhileScrolledUpPins() {
        var f = TranscriptFollow()
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.contentArrived(readerSent: true)
        XCTAssertTrue(f.pinned)
        XCTAssertFalse(f.newBelow)
    }

    func testNewContentBelowShowsJumpButtonOnlyWhileUnpinned() {
        var f = TranscriptFollow()
        f.contentArrived(readerSent: false)
        XCTAssertFalse(f.newBelow)
        f.geometryChanged(distanceFromBottom: 400, userDriven: true)
        f.contentArrived(readerSent: false)
        XCTAssertTrue(f.newBelow)
        f.geometryChanged(distanceFromBottom: 0, userDriven: true)
        XCTAssertFalse(f.newBelow)
    }
}

/// A reader scrolled up must stay where they are while a reply streams in.
@MainActor
final class TranscriptFollowTests: XCTestCase {
    override func setUpWithError() throws {
        try CISkip.unlessLocal()
    }

    private func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    private func scrollView(_ panel: NSPanel) -> NSScrollView? { HugeTranscriptTests.scrollView(in: panel.contentView) }

    /// (distance from top, distance from bottom)
    private func position(_ panel: NSPanel) -> (top: CGFloat, bottom: CGFloat) {
        guard let scroll = scrollView(panel), let doc = scroll.documentView else { return (0, 0) }
        let v = scroll.contentView.bounds
        let top = doc.isFlipped ? v.minY : doc.bounds.maxY - v.maxY
        return (top, doc.bounds.height - v.height - top)
    }

    private func wheel(_ panel: NSPanel, toFraction f: CGFloat) {
        guard let scroll = scrollView(panel) else { return }
        for _ in 0..<600 {
            guard let doc = scroll.documentView else { return }
            let v = scroll.contentView.bounds
            let offset = doc.isFlipped ? v.minY : doc.bounds.maxY - v.maxY
            let delta = (doc.bounds.height - v.height) * f - offset
            if abs(delta) < 40 { break }
            let step = Int32(max(-3000, min(3000, delta)))
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -step, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: cg) else { return }
            scroll.scrollWheel(with: event)
            spin(0.04)
        }
        spin(1)
    }

    private func open() -> (ChatSession, IronPetPanel) {
        let session = ChatSession(restore: false)
        session.items = HugeTranscriptTests.hugeThread(screenshotDir: nil)
        let panel = IronPetPanel.chat(session)
        panel.setContentSize(CGSize(width: 520, height: 640))
        panel.orderFrontRegardless()
        spin(3)
        return (session, panel)
    }

    private func stream(_ session: ChatSession, words: Int) {
        session.items.append(.init(kind: .assistant("")))
        let index = session.items.count - 1
        var text = ""
        for i in 0..<words {
            text += "word\(i) "
            session.items[index].kind = .assistant(text)
            if i % 4 == 0 { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.004)) }
        }
        spin(1)
    }

    private func snapshot(_ panel: NSPanel, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["IRONPET_SNAPSHOTS"], let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    func testScrolledUpStaysPutWhileReplyStreams() throws {
        let (session, panel) = open()
        wheel(panel, toFraction: 0.5)
        let before = position(panel)
        snapshot(panel, "scrolledup-before")
        stream(session, words: 1500)
        session.items.append(.init(kind: .tool("Ran `ls`", ok: true)))
        session.items.append(.init(kind: .assistant("A later message")))
        spin(1)
        let after = position(panel)
        snapshot(panel, "scrolledup-after")
        print("FOLLOW scrolled up: top \(before.top) -> \(after.top), bottom gap \(before.bottom) -> \(after.bottom)")
        panel.close()
        XCTAssertEqual(after.top, before.top, accuracy: 40, "the transcript moved while the reader was scrolled up")
    }

    /// The invariant is the row the reader sees, not the offset: SwiftUI shifts the offset by hundreds of points when a
    /// new row changes its height estimates, and keeps the row where it was.
    func testScrolledUpKeepsTheSameRowWhileContentArrives() throws {
        let (session, panel) = open()
        wheel(panel, toFraction: 0.5)
        func topIndex() -> Int? { ChatView.topRowForTesting.flatMap { id in session.items.firstIndex { $0.id == id } } }
        let before = try XCTUnwrap(topIndex(), "SwiftUI reported no top row")
        stream(session, words: 800)
        session.items.append(.init(kind: .tool("Ran `ls`", ok: true)))
        session.items.append(.init(kind: .assistant("A later message")))
        session.items.append(.init(kind: .user("A message from Telegram"), origin: ChatOrigin.telegramClient))
        spin(1.5)
        let after = try XCTUnwrap(topIndex())
        print("FOLLOW top row index \(before) -> \(after)")
        panel.close()
        XCTAssertEqual(after, before, "the row the reader was looking at changed")
    }

    func testPinnedKeepsFollowingWhileReplyStreams() throws {
        let (session, panel) = open()
        stream(session, words: 1500)
        let after = position(panel)
        snapshot(panel, "pinned-after")
        print("FOLLOW pinned: bottom gap \(after.bottom)")
        panel.close()
        XCTAssertLessThan(after.bottom, 60, "stopped following the bottom")
    }

    func testScrollingBackDownResumesFollowing() throws {
        let (session, panel) = open()
        wheel(panel, toFraction: 0.5)
        stream(session, words: 300)
        for _ in 0..<5 where position(panel).bottom > 20 { wheel(panel, toFraction: 1) }
        print("FOLLOW reader reached bottom: gap \(position(panel).bottom)")
        stream(session, words: 1500)
        let after = position(panel)
        print("FOLLOW resumed: bottom gap \(after.bottom)")
        panel.close()
        XCTAssertLessThan(after.bottom, 60, "did not resume following after scrolling to the bottom")
    }

    func testSendingJumpsToBottom() throws {
        let (session, panel) = open()
        wheel(panel, toFraction: 0.3)
        session.items.append(.init(kind: .user("hello")))
        spin(2)
        XCTAssertLessThan(position(panel).bottom, 60)
        panel.close()
    }
}

final class BlankViewportGuardTests: XCTestCase {
    func testNeverFiresWhileARowIsVisible() {
        var guardrail = BlankViewportGuard()
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 1, hasRows: true, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: -700))
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 3, hasRows: true, contentHeight: 9000, viewportHeight: 600, distanceFromBottom: -700))
    }

    func testFiresOnlyWhenEmptyWithTallContent() {
        var guardrail = BlankViewportGuard()
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 0, hasRows: false, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: -700))
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 400, viewportHeight: 600, distanceFromBottom: -700))
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5000, viewportHeight: 0, distanceFromBottom: -700))
        XCTAssertTrue(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: -700))
    }

    func testIgnoresAViewportThatStillOverlapsTheContent() {
        var guardrail = BlankViewportGuard()
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: 900))
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: 0))
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: -10))
        XCTAssertTrue(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: -200))
    }

    func testFiresOncePerContentHeightAndRearmsWhenRowsReturn() {
        var guardrail = BlankViewportGuard()
        XCTAssertTrue(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: -700))
        XCTAssertFalse(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5000, viewportHeight: 600, distanceFromBottom: -700))
        XCTAssertTrue(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5200, viewportHeight: 600, distanceFromBottom: -700))
        guardrail.rowsVisible()
        XCTAssertTrue(guardrail.shouldReanchor(visibleRows: 0, hasRows: true, contentHeight: 5200, viewportHeight: 600, distanceFromBottom: -700))
    }
}
