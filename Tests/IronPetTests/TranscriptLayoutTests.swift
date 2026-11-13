import AppKit
import SwiftUI
import XCTest
@testable import IronPet

/// A chat with hundreds of items must settle: once laid out, an idle transcript uses almost no CPU.
@MainActor
final class TranscriptLayoutTests: XCTestCase {
    private func longThread() -> [ChatSession.Item] {
        var items: [ChatSession.Item] = []
        let markdown = (0..<40).map { "Line \($0) of **markdown** with `code` and a [link](https://example.com)." }.joined(separator: "\n")
        for i in 0..<60 {
            items.append(.init(kind: .user("Question \(i)")))
            for j in 0..<3 { items.append(.init(kind: .tool("Ran `step \(i)-\(j)`", ok: true))) }
            items.append(.init(kind: .assistant(i % 4 == 0 ? markdown : "Short answer \(i)")))
            if i % 5 == 0 { items.append(.init(kind: .screenshot("/nonexistent/shot-\(i).png"))) }
        }
        return items
    }

    /// Set IRONPET_FIXTURE to a saved thread JSON to run against real data.
    private func fixtureItems() throws -> [ChatSession.Item]? {
        guard let path = ProcessInfo.processInfo.environment["IRONPET_FIXTURE"] else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChatThread.self, from: Data(contentsOf: URL(fileURLWithPath: path))).items
    }

    private func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let found = view as? NSScrollView { return found }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    /// Points between the visible area and the end of the transcript.
    private func distanceFromBottom(_ panel: NSPanel) -> CGFloat? {
        guard let scroll = scrollView(in: panel.contentView), let doc = scroll.documentView else { return nil }
        let visible = scroll.contentView.bounds
        return doc.isFlipped ? doc.bounds.maxY - visible.maxY : visible.minY - doc.bounds.minY
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }

    private func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    /// Opens the chat panel on `session` and returns the CPU seconds used over 3 idle seconds after the first layout.
    private var openedAtBottom: CGFloat?

    private func idleCPU(_ session: ChatSession) -> Double {
        let panel = ChatPanel(session: session)
        panel.orderFrontRegardless()
        spin(3) // initial layout and scroll to the bottom
        let before = cpuSeconds()
        spin(3)
        let used = cpuSeconds() - before
        openedAtBottom = distanceFromBottom(panel)
        panel.close()
        return used
    }

    func testLongTranscriptIdlesAfterLayout() throws {
        let session = ChatSession(restore: false)
        session.items = try fixtureItems() ?? longThread()
        let used = idleCPU(session)
        XCTAssertLessThan(used, 0.6, "idle transcript burned \(used)s of CPU in 3s")
    }

    func testLongTranscriptWithPendingApprovalIdles() throws {
        let session = ChatSession(restore: false)
        session.loadPreview(.approval) // running, with one approval card
        session.items = try fixtureItems() ?? longThread()
        let used = idleCPU(session)
        XCTAssertLessThan(used, 0.6, "transcript with an approval burned \(used)s of CPU in 3s")
    }

    /// The reply grows token by token while the panel is open, then the turn ends.
    func testStreamingReplyThenIdle() throws {
        let session = ChatSession(restore: false)
        session.items = try fixtureItems() ?? longThread()
        let panel = ChatPanel(session: session)
        panel.orderFrontRegardless()
        spin(2)
        session.items.append(.init(kind: .assistant("")))
        let last = session.items.count - 1
        var text = ""
        let start = cpuSeconds()
        let wall = Date()
        for i in 0..<60 {
            text += "word\(i) **bold** and more text to wrap across lines. "
            session.items[last].kind = .assistant(text)
            spin(0.05)
        }
        let streamCPU = cpuSeconds() - start
        let streamWall = Date().timeIntervalSince(wall)
        spin(2)
        let before = cpuSeconds()
        spin(3)
        let idle = cpuSeconds() - before
        let gap = distanceFromBottom(panel)
        panel.close()
        XCTAssertLessThan(try XCTUnwrap(gap), 30, "transcript left the bottom while streaming")
        print("streaming: \(streamCPU)s cpu in \(streamWall)s wall, idle after: \(idle)s")
        XCTAssertLessThan(idle, 0.6, "idle after streaming burned \(idle)s of CPU in 3s")
    }

    /// An approval card appears and is answered while a long chat is already open.
    func testApprovalArrivesAndIsAnsweredInOpenChat() throws {
        let session = ChatSession(restore: false)
        let fixture = try fixtureItems() ?? longThread()
        session.items = fixture
        let panel = ChatPanel(session: session)
        panel.orderFrontRegardless()
        spin(2)
        session.loadPreview(.approval)
        session.items = fixture + [.init(kind: .tool("Ran `npm test`", ok: true))]
        let wall = Date()
        spin(2)
        let before = cpuSeconds()
        spin(3)
        let pending = cpuSeconds() - before
        let approval = try XCTUnwrap(session.approvals.first)
        session.decide(approval, allow: true)
        spin(1)
        let after = cpuSeconds()
        spin(3)
        let idle = cpuSeconds() - after
        let gap = distanceFromBottom(panel)
        panel.close()
        XCTAssertLessThan(try XCTUnwrap(gap), 30, "transcript left the bottom after the approval")
        print("approval: pending cpu \(pending)s, idle after decide \(idle)s, wall \(Date().timeIntervalSince(wall))s")
        XCTAssertTrue(session.approvals.isEmpty)
        XCTAssertLessThan(pending, 0.6)
        XCTAssertLessThan(idle, 0.6)
    }

    func testThumbnailDecodesEachFileOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString).png")
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = ThumbnailCache.decodeCount
        for _ in 0..<20 { XCTAssertNotNil(ThumbnailCache.image(at: url.path)) }
        XCTAssertEqual(ThumbnailCache.decodeCount - before, 1)
        XCTAssertNil(ThumbnailCache.image(at: "/nonexistent/x.png"))
    }
}
