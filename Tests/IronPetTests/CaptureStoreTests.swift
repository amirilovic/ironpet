import XCTest
@testable import IronPet

final class CaptureStoreTests: XCTestCase {
    private var store: CaptureStore!
    private let slack = CaptureApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack")
    private let safari = CaptureApp(bundleId: "com.apple.Safari", name: "Safari")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        store = CaptureFixtures.store()
    }

    @discardableResult
    private func add(_ app: CaptureApp, _ title: String, _ lines: [String], url: String? = nil, ago: TimeInterval = 0) throws -> CaptureStore.IngestResult {
        try store.ingest(app: app, title: title, url: url, trigger: .typingPause, lines: lines, now: now.addingTimeInterval(-ago))
    }

    func testAFirstCaptureStoresEverythingAndTheSameTextAgainStoresNothing() throws {
        guard case .stored(let id) = try add(slack, "Ana", ["one", "two"]) else { return XCTFail() }
        XCTAssertEqual(store.capture(id: id)?.text, "one\ntwo")
        XCTAssertEqual(try add(slack, "Ana", ["one", "two"]), .unchanged)
        XCTAssertEqual(try add(slack, "Ana", []), .empty)
        XCTAssertEqual(store.captureCount, 1)
    }

    func testWindowsAreKeyedByAppAndTitleOrByPageAddress() throws {
        try add(slack, "Ana", ["shared line", "x"], ago: 120)
        guard case .stored = try add(slack, "Ben", ["shared line", "x"]) else { return XCTFail("another window starts with its own history") }
        guard case .stored = try add(safari, "Ana", ["shared line", "x"]) else { return XCTFail("another app does too") }
        try add(safari, "Page", ["a", "b"], url: "https://example.com/p?id=1#top")
        XCTAssertEqual(try add(safari, "Page, renamed", ["a", "b"], url: "https://example.com/p?id=1#other"), .unchanged, "a page is keyed by address without the fragment")
        guard case .stored = try add(safari, "Page", ["a", "b", "c"], url: "https://example.com/p?id=2") else { return XCTFail("another address is another window") }
    }

    func testAWindowKeepsDigestsNotText() throws {
        try add(slack, "Ana", ["a secret-looking line", "b"])
        let rows = try store.database.read { try $0.rows("SELECT last_lines FROM capture_window") }
        let kept = rows[0][0] as? String ?? ""
        XCTAssertFalse(kept.contains("secret-looking"))
        XCTAssertEqual(kept.split(separator: "\n").count, 2)
    }

    func testATitleThatChangesEveryCaptureStaysOneWindow() throws {
        try add(slack, "Terminal - 1 task", ["l1", "l2", "l3", "l4"], ago: 20)
        guard case .stored(let id) = try add(slack, "Terminal - 2 tasks", ["l1", "l2", "l3", "l4", "l5"], ago: 10) else { return XCTFail() }
        XCTAssertEqual(store.capture(id: id)?.text, "l3\nl4\nl5", "only the new line with context, not the whole window again")
        XCTAssertEqual(try add(slack, "Terminal - 3 tasks", ["l1", "l2", "l3", "l4", "l5"]), .unchanged)
        let windows = try store.database.read { try $0.rows("SELECT COUNT(*) FROM capture_window") }
        XCTAssertEqual(windows[0][0] as? Int64, 1)
        guard case .stored = try add(slack, "Other chat", ["x1", "x2", "x3"]) else { return XCTFail("different content is another window") }
    }

    func testALineThatLeavesAndComesBackIsNewAgain() throws {
        try add(slack, "Ana", ["a", "b"])
        try add(slack, "Ana", ["a"])
        guard case .stored(let id) = try add(slack, "Ana", ["a", "b"]) else { return XCTFail() }
        XCTAssertEqual(store.capture(id: id)?.text, "a\nb")
    }

    func testSearchFindsTextTitleAndAppAndNarrowsByAppAndTime() throws {
        try add(slack, "Ana (DM)", ["Can you review PR 4649?", "thanks"], ago: 3600)
        try add(safari, "Pull request 4649", ["Add screen capture", "Checks passed"], url: "https://github.com/acme/app/pull/4649", ago: 60)
        try add(safari, "Docs", ["Unrelated page about 99"], ago: 30)
        let all = store.search("4649")
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.map(\.app).sorted(), ["com.apple.Safari", "com.tinyspeck.slackmacgap"])
        XCTAssertTrue(all.contains { $0.snippet.contains("[4649]") }, "the snippet marks the match")
        XCTAssertEqual(store.search("4649", app: "Slack").map(\.appName), ["Slack"])
        XCTAssertEqual(store.search("4649", app: "com.apple.safari").count, 1)
        XCTAssertEqual(store.search("4649", since: now.addingTimeInterval(-600)).count, 1)
        XCTAssertEqual(store.search("4649", until: now.addingTimeInterval(-600)).count, 1)
        XCTAssertEqual(store.search("review thanks").count, 1, "every word must match")
        XCTAssertEqual(store.search("docs unrelated").count, 1, "the title is searched too")
        XCTAssertTrue(store.search("nothing like this").isEmpty)
        XCTAssertTrue(store.search("   ").isEmpty)
        for odd in ["\"", "AND OR", "a*", "NEAR(", "x:y", "(", "4649\""] { _ = store.search(odd) }
    }

    func testListReturnsTheTimeRangeOldestFirstFilteredByAppAndWindow() throws {
        try add(slack, "Ana", ["first"], ago: 300)
        try add(slack, "Ben", ["second"], ago: 200)
        try add(safari, "Docs 100%_x", ["third"], ago: 100)
        XCTAssertEqual(store.list(since: now.addingTimeInterval(-250)).map(\.text), ["second", "third"])
        XCTAssertEqual(store.list(app: "slack").map(\.text), ["first", "second"])
        XCTAssertEqual(store.list(window: "Ben").map(\.text), ["second"])
        XCTAssertEqual(store.list(window: "100%_x").map(\.text), ["third"], "% and _ are not wildcards")
        XCTAssertEqual(store.list(window: "%").count, 1)
        XCTAssertEqual(store.list(until: now.addingTimeInterval(-250)).map(\.text), ["first"])
        XCTAssertEqual(store.list(limit: 1).count, 1)
    }

    func testPruneDeletesOldCapturesFromTheIndexToo() throws {
        try add(slack, "Ana", ["ancient needle"], ago: 10 * 86_400)
        try add(slack, "Ben", ["fresh needle"], ago: 3600)
        XCTAssertEqual(store.search("needle").count, 2)
        XCTAssertEqual(store.prune(olderThanDays: 7, now: now), 1)
        XCTAssertEqual(store.search("needle").map(\.window), ["Ben"])
        XCTAssertEqual(store.captureCount, 1)
        store.clear()
        XCTAssertEqual(store.captureCount, 0)
        XCTAssertTrue(store.search("needle").isEmpty)
        guard case .stored = try add(slack, "Ben", ["fresh needle"]) else { return XCTFail("a cleared window starts over") }
    }

    func testThePrivacyFilterHookRunsOnWriteAndOnRead() throws {
        struct Shout: CapturePrivacyFilter {
            func filterOnWrite(_ text: String, app: String) -> String { text.replacingOccurrences(of: "secret-plan", with: "[filtered]") }
            func filterOnRead(_ text: String, app: String) -> String { text.uppercased() }
        }
        store.filter = Shout()
        guard case .stored(let id) = try add(slack, "Ana", ["the secret-plan is ready"]) else { return XCTFail() }
        XCTAssertEqual(store.capture(id: id)?.text, "THE [FILTERED] IS READY")
        XCTAssertTrue(store.search("secret-plan").isEmpty, "the written text never held the filtered words")
        XCTAssertEqual(store.recent(limit: 1).first?.text, "THE [FILTERED] IS READY")
        XCTAssertTrue(store.search("ready").first?.snippet.contains("READY") == true)
    }

    func testTitlesAndUrlsAreRedactedToo() throws {
        let token = "ghp_" + String(repeating: "a1B2", count: 9)
        guard case .stored(let id) = try add(safari, "Settings \(token)", ["page text"], url: "https://example.com/x?access_token=abc123xyz789") else { return XCTFail() }
        let capture = try XCTUnwrap(store.capture(id: id))
        XCTAssertFalse(capture.window.contains(token))
        XCTAssertFalse((capture.url ?? "").contains("abc123xyz789"))
    }

    func testTheDatabaseFilesAreOwnerOnly() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-capture-\(UUID().uuidString)/ironpet.db")
        addTeardownBlock { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let database = try Database(path: file, migrations: CaptureStore.migrations)
        CaptureStore.restrictPermissions(of: database)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}
