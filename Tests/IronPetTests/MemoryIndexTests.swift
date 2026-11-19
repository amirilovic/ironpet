import XCTest
@testable import IronPet

final class MemoryIndexTests: XCTestCase {
    private var index: MemoryIndex!
    private var dir: URL!

    override func setUpWithError() throws {
        index = MemoryIndex(database: try Database(path: nil, migrations: AppMigrations.all))
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-memory-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func thread(_ id: String, _ items: [ChatSession.Item], automation: String? = nil) -> ChatThread {
        ChatThread(id: id, title: "Package managers", workspace: "/w", updatedAt: Date(), items: items, agent: "claude", automation: automation)
    }

    func testChatMessagesAreSearchableButToolOutputAndAutomationTextAreNot() {
        let day = Date(timeIntervalSince1970: 1_795_000_000)
        index.indexThread(thread("t1", [
            .init(kind: .user("I always use pnpm, never npm"), date: day),
            .init(kind: .tool("Ran `npm install leftpad`", ok: true), date: day),
            .init(kind: .assistant("Noted, pnpm from now on."), date: day),
            .init(kind: .user("Check the feed for pnpm news"), date: day, origin: ChatSession.automationOrigin),
        ]))
        index.indexThread(thread("t2", [.init(kind: .user("pnpm in the watcher"), date: day)], automation: "watcher"))
        index.flush()
        XCTAssertEqual(index.search("pnpm").count, 2)
        XCTAssertTrue(index.search("leftpad").isEmpty, "tool rows are not indexed")
        XCTAssertTrue(index.search("feed").isEmpty, "an automation's prompt is not indexed")
        let hit = index.search("never npm").first
        XCTAssertEqual(hit?.kind, .chat)
        XCTAssertTrue(hit?.ref.hasPrefix("t1/") == true)
        XCTAssertEqual(hit?.title, "Package managers")
        XCTAssertTrue(hit?.snippet.contains("[npm]") == true || hit?.snippet.contains("[never]") == true)
    }

    func testReindexingAThreadFollowsEditsAndRemovals() {
        var items: [ChatSession.Item] = [.init(kind: .user("first draft about kotlin")), .init(kind: .assistant("Partial"))]
        index.indexThread(thread("t1", items))
        items[1].kind = .assistant("Partial answer about gradle")
        items.remove(at: 0)
        index.indexThread(thread("t1", items))
        index.flush()
        XCTAssertTrue(index.search("kotlin").isEmpty)
        XCTAssertEqual(index.search("gradle").count, 1)
        XCTAssertEqual(index.count(.chat), 1)
    }

    func testMeetingSummaryAndTranscriptPartsAreSearchable() throws {
        let folder = dir.appendingPathComponent("2026-11-18-1000")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "## Summary\nWe picked Postgres.\n".write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        let lines = (0..<90).map { "Me: line \($0)" } + ["Them: the migration needs a rollback plan"]
        try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        index.indexMeeting(folder)
        index.flush()
        XCTAssertEqual(index.search("postgres").first?.ref, folder.path + "/summary")
        XCTAssertEqual(index.search("rollback").first?.ref, folder.path + "/transcript#2")
        XCTAssertEqual(index.search("rollback", kinds: [.chat]).count, 0)
    }

    func testTimeRangesAndKindsNarrowTheSearch() {
        let old = Date(timeIntervalSince1970: 1_700_000_000), new = Date(timeIntervalSince1970: 1_795_000_000)
        index.indexThread(thread("t1", [.init(kind: .user("deploy friday"), date: old), .init(kind: .user("deploy monday"), date: new)]))
        index.flush()
        index.indexNotes(file: "me.md", title: "About me", entries: MemoryDocument("- Never deploy on Fridays <!-- 2026-11-18 chat:a -->").entries, modified: new)
        XCTAssertEqual(index.search("deploy").count, 3)
        // A note is dated at the start of its day, so it falls before the Monday message.
        XCTAssertEqual(index.search("deploy", since: new.addingTimeInterval(-60)).count, 1)
        XCTAssertEqual(index.search("deploy", until: new.addingTimeInterval(-60)).count, 2)
        XCTAssertEqual(index.search("deploy", kinds: [.note]).map(\.ref), ["me.md|0"])
    }

    func testCursorsAndChangesPersist() {
        XCTAssertNil(index.cursor("t1"))
        index.setCursor("t1", item: "a")
        index.setCursor("t1", item: "b", at: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(index.cursor("t1")?.item, "b")
        XCTAssertEqual(index.cursor("t1")?.at, Date(timeIntervalSince1970: 5))
        let id = index.record(at: Date(), file: "me.md", section: nil, action: .added, note: "- x", previous: nil, source: "chat:a")
        XCTAssertNotNil(id)
        index.markUndone(id!)
        XCTAssertEqual(index.changes().first?.undone, true)
        XCTAssertEqual(index.change(id!)?.note, "- x")
    }

    func testDeletedMeetingsAndThreadsAreNotFoundAgain() throws {
        let meetings = dir.appendingPathComponent("meetings")
        let kept = meetings.appendingPathComponent("2026-11-17-0900"), trashed = meetings.appendingPathComponent("2026-11-17-1000")
        for folder in [kept, trashed] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "Budget talk for \(folder.lastPathComponent)".write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
            index.indexMeeting(folder)
        }
        index.indexThread(thread("gone", [.init(kind: .user("budget question"))]))
        index.indexThread(thread("here", [.init(kind: .user("budget answer"))]))
        index.flush()
        XCTAssertEqual(index.search("budget").count, 4)
        try FileManager.default.removeItem(at: trashed)
        index.removeMeeting(trashed)
        index.flush()
        XCTAssertEqual(index.search("budget", kinds: [.meeting]).map(\.ref), [kept.path + "/summary"])
        try FileManager.default.removeItem(at: kept)
        index.backfill(threads: { [self] in [thread("here", [.init(kind: .user("budget answer"))])] }, meetings: meetings)
        index.flush()
        XCTAssertEqual(index.search("budget").map(\.ref).map { $0.hasPrefix("here/") }, [true], "a thread or meeting gone from disk leaves the index")
    }

    func testBackfillIndexesSavedThreadsAndMeetings() throws {
        let meetings = dir.appendingPathComponent("meetings")
        let folder = meetings.appendingPathComponent("2026-11-17-0900")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Decided on weekly releases".write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        let saved = [thread("t9", [.init(kind: .user("remember the sqlite pragma"))])]
        index.backfill(threads: { saved }, meetings: meetings)
        index.flush()
        XCTAssertEqual(index.search("pragma").count, 1)
        XCTAssertEqual(index.search("weekly releases").count, 1)
    }
}
