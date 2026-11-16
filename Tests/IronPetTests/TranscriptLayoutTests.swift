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
        // Only the items: threads saved before ACP have no "agent" and do not decode as a ChatThread.
        struct Saved: Decodable { var items: [ChatSession.Item] }
        var items = try decoder.decode(Saved.self, from: Data(contentsOf: URL(fileURLWithPath: path))).items
        // The saved screenshots live on another Mac. IRONPET_SHOTS points them at local stand-in images.
        if let shots = ProcessInfo.processInfo.environment["IRONPET_SHOTS"] {
            var n = 0
            for i in items.indices {
                if case .screenshot = items[i].kind { items[i].kind = .screenshot("\(shots)/shot-\(n % 24).png"); n += 1 }
            }
        }
        return items
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

/// S1/S2: a resumed session with thousands of items must not hang the main thread.
@MainActor
final class HugeTranscriptTests: XCTestCase {
    static func hugeThread(screenshotDir: URL?) -> [ChatSession.Item] {
        var items: [ChatSession.Item] = []
        let markdown = (0..<20).map { "Line \($0) of **markdown** with `code`." }.joined(separator: "\n")
        var i = 0
        while items.count < 5200 {
            items.append(.init(kind: .user("Question \(i)")))
            for j in 0..<55 { items.append(.init(kind: .tool("Ran `step \(i)-\(j)`", ok: true))) }
            items.append(.init(kind: .assistant(i % 3 == 0 ? markdown : "Short answer \(i)")))
            if i % 4 == 0 {
                let path = screenshotDir?.appendingPathComponent("shot-\(i % 24).png").path ?? "/nonexistent/shot.png"
                items.append(.init(kind: .screenshot(path)))
            }
            i += 1
        }
        return items
    }

    static func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let found = view as? NSScrollView { return found }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    static func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return Int(info.phys_footprint / 1_048_576)
    }

    private func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }

    func testHugeTranscriptIdlesAndStreams() throws {
        let session = ChatSession(restore: false)
        // IRONPET_SHOTS: a folder with shot-0.png ... shot-23.png (large screenshots) to decode for real.
        let shots = ProcessInfo.processInfo.environment["IRONPET_SHOTS"].map { URL(fileURLWithPath: $0) }
        session.items = Self.hugeThread(screenshotDir: shots)
        let panel = ChatPanel(session: session)
        let open = Date()
        panel.orderFrontRegardless()
        spin(0.1)
        let openStall = Date().timeIntervalSince(open)
        spin(5)
        let before = cpuSeconds()
        spin(5)
        let idle = cpuSeconds() - before
        print("HUGE open stall \(openStall)s, idle cpu \(idle)s in 5s")
        // Scroll to the top and back, then read the memory footprint.
        if let scroll = Self.scrollView(in: panel.contentView), let doc = scroll.documentView {
            for y in [CGFloat(0), doc.bounds.height * 0.5, 0, doc.bounds.height] {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                spin(1.5)
            }
        }
        print("HUGE footprint after scrolling \(Self.footprintMB()) MB")
        // Stream 2000 tokens, tracking the longest main-thread stall.
        session.items.append(.init(kind: .assistant("")))
        let last = session.items.count - 1
        var text = ""
        var worst = 0.0
        for i in 0..<2000 {
            text += i % 40 == 39 ? "tok\(i)\n\n" : "tok\(i) "
            // Main-thread CPU time, not wall time, so other processes on a busy Mac do not count as a stall.
            let t = Self.threadCPU()
            session.items[last].kind = .assistant(text)
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
            let d = Self.threadCPU() - t
            if d > 0.1 { print("HUGE stall \(d)s at token \(i)") }
            worst = max(worst, d)
        }
        print("HUGE worst stall while streaming \(worst)s")
        panel.close()
        XCTAssertLessThan(openStall, 2)
        XCTAssertLessThan(idle, 0.25, "idle burned \(idle)s CPU in 5s")
        XCTAssertLessThan(worst, 0.25)
        XCTAssertLessThan(Self.footprintMB(), 300)
    }
}

final class TranscriptGroupTests: XCTestCase {
    private func mixed() -> [ChatSession.Item] {
        [.init(kind: .user("a")), .init(kind: .tool("t1", ok: true)), .init(kind: .tool("t2", ok: nil)),
         .init(kind: .assistant("b")), .init(kind: .tool("t3", ok: true)), .init(kind: .screenshot("/x.png"))]
    }

    func testConsecutiveToolsFormOneBlockWithStableIDs() {
        let items = mixed()
        let groups = TranscriptGroup.make(items[...])
        XCTAssertEqual(groups.count, 5)
        guard case .tools(let run) = groups[1] else { return XCTFail("expected a tool block") }
        XCTAssertEqual(run.count, 2)
        XCTAssertEqual(groups[1].id, items[1].id)
        XCTAssertEqual(groups[0].id, items[0].id)
        XCTAssertEqual(TranscriptGroup.make(items[...]).map(\.id), groups.map(\.id))
    }

    func testTrailingToolRunIsKept() {
        let items = Array(mixed()[..<3])
        let groups = TranscriptGroup.make(items[...])
        guard case .tools(let run) = groups.last else { return XCTFail() }
        XCTAssertEqual(run.count, 2)
    }

    func testWindowNeverSplitsToolRun() {
        let items = mixed()
        XCTAssertEqual(TranscriptGroup.windowStart(items, limit: 100), 0)
        XCTAssertEqual(TranscriptGroup.windowStart(items, limit: 5), 1)
        XCTAssertEqual(TranscriptGroup.windowStart(items, limit: 4), 1) // t2 pulls in t1
        XCTAssertEqual(TranscriptGroup.windowStart(items, limit: 3), 3) // starts at the assistant
    }
}

/// Live-resizing the chat window: the scroll position must survive and each frame must stay cheap.
@MainActor
final class TranscriptResizeTests: XCTestCase {
    /// Plain questions and answers. The shown window is the last `pageSize` items, and in `hugeThread` that is only about
    /// five turns, since each turn's 55 tool steps fold into one row. That leaves a scroll range of a few hundred points,
    /// where one re-wrap moves "the middle" to an end. Here the window is many screens tall.
    private static func conversation() -> [ChatSession.Item] {
        let markdown = (0..<6).map { "Line \($0) of an answer with **markdown** and `code` that wraps at narrow widths." }.joined(separator: "\n")
        return (0..<200).flatMap { i -> [ChatSession.Item] in
            [.init(kind: .user("Question \(i): how does this part of the code work?")),
             .init(kind: .assistant(i % 3 == 0 ? markdown : "Short answer \(i)."))]
        }
    }

    private func items(conversation: Bool = false) throws -> [ChatSession.Item] {
        // IRONPET_FIXTURE: a saved thread; IRONPET_SHOTS: stand-in screenshots. Without them a generated thread.
        if let path = ProcessInfo.processInfo.environment["IRONPET_FIXTURE"] {
            struct Saved: Decodable { var items: [ChatSession.Item] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var items = try decoder.decode(Saved.self, from: Data(contentsOf: URL(fileURLWithPath: path))).items
            if let shots = ProcessInfo.processInfo.environment["IRONPET_SHOTS"] {
                var n = 0
                for i in items.indices {
                    if case .screenshot = items[i].kind { items[i].kind = .screenshot("\(shots)/shot-\(n % 24).png"); n += 1 }
                }
            }
            return items
        }
        return conversation ? Self.conversation() : HugeTranscriptTests.hugeThread(screenshotDir: nil)
    }

    private func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    /// (offset from the top, content height, viewport height) of the transcript's scroll view.
    private func geometry(_ panel: NSPanel) -> (offset: CGFloat, content: CGFloat, viewport: CGFloat)? {
        guard let scroll = HugeTranscriptTests.scrollView(in: panel.contentView), let doc = scroll.documentView else { return nil }
        let visible = scroll.contentView.bounds
        let offset = doc.isFlipped ? visible.minY : doc.bounds.maxY - visible.maxY
        return (offset, doc.bounds.height, visible.height)
    }

    /// Scrolls with real wheel events, so SwiftUI's scroll position tracking sees it like a user's scroll.
    private func scroll(_ panel: NSPanel, toFraction f: CGFloat) {
        guard let scroll = HugeTranscriptTests.scrollView(in: panel.contentView) else { return }
        for _ in 0..<400 {
            guard let g = geometry(panel) else { return }
            let target = (g.content - g.viewport) * f
            let delta = target - g.offset
            if abs(delta) < 40 { break }
            let step = Int32(max(-3000, min(3000, delta)))
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -step, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: cg) else { return }
            scroll.scrollWheel(with: event)
            spin(0.05)
        }
    }

    /// Drags the right edge through `widths`, 30 frames each way, and returns the mean and worst main-thread CPU per frame.
    private func liveResize(_ panel: NSPanel, widths: [CGFloat]) -> (mean: Double, worst: Double) {
        var costs: [Double] = []
        var frame = panel.frame
        var steps: [CGFloat] = []
        for (a, b) in zip(widths, widths.dropFirst()) { for k in 1...20 { steps.append(a + (b - a) * CGFloat(k) / 20) } }
        panel.viewsNeedDisplay = true
        for w in steps {
            let t = HugeTranscriptTests.threadCPU()
            frame.size.width = w
            panel.setFrame(frame, display: true)
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.016))
            costs.append(HugeTranscriptTests.threadCPU() - t)
        }
        return (costs.reduce(0, +) / Double(costs.count), costs.max() ?? 0)
    }

    private func open(conversation: Bool = false) throws -> ChatPanel {
        let session = ChatSession(restore: false)
        session.items = try items(conversation: conversation)
        let panel = ChatPanel(session: session)
        panel.setContentSize(CGSize(width: 520, height: 640))
        panel.orderFrontRegardless()
        spin(3)
        return panel
    }

    func testResizeAtBottomStaysAtBottom() throws {
        let panel = try open()
        if let g = geometry(panel) { print("RESIZE start: offset \(g.offset) content \(g.content) viewport \(g.viewport)") }
        let stats = liveResize(panel, widths: [520, 760, 400, 560])
        if let g = geometry(panel) { print("RESIZE just after: offset \(g.offset) content \(g.content) viewport \(g.viewport)") }
        spin(2)
        let g = try XCTUnwrap(geometry(panel))
        let gap = g.content - g.viewport - g.offset
        print("RESIZE bottom: gap \(gap) pt, mean frame cpu \(stats.mean * 1000) ms, worst \(stats.worst * 1000) ms")
        panel.close()
        XCTAssertLessThan(abs(gap), 60, "left the bottom after a resize")
        XCTAssertLessThan(stats.mean, 0.1)
    }

    func testResizeInTheMiddleDoesNotJumpToTheTop() throws {
        let panel = try open(conversation: true)
        scroll(panel, toFraction: 0.5)
        spin(1.5)
        // Rows only get their real heights once they have been on screen, so the fraction moves after the first pass.
        scroll(panel, toFraction: 0.5)
        spin(1.5)
        let before = try XCTUnwrap(geometry(panel))
        let ratioBefore = before.offset / max(1, before.content - before.viewport)
        XCTAssertGreaterThan(before.content - before.viewport, 4 * before.viewport, "too little to scroll for a middle")
        XCTAssertEqual(ratioBefore, 0.5, accuracy: 0.15, "did not reach the middle before resizing")
        let stats = liveResize(panel, widths: [520, 760, 400, 560])
        spin(2)
        let after = try XCTUnwrap(geometry(panel))
        let ratioAfter = after.offset / max(1, after.content - after.viewport)
        print("RESIZE middle: scroll fraction \(ratioBefore) -> \(ratioAfter), mean frame cpu \(stats.mean * 1000) ms, worst \(stats.worst * 1000) ms")
        panel.close()
        XCTAssertGreaterThan(after.offset, 100, "jumped to the beginning")
        XCTAssertGreaterThan(after.content - after.viewport - after.offset, 100, "jumped to the end")
        // Re-wrapping changes the total height, so the fraction only holds roughly.
        XCTAssertEqual(ratioAfter, ratioBefore, accuracy: 0.15)
        XCTAssertLessThan(stats.mean, 0.1)
    }
}
