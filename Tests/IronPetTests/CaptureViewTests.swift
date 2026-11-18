import XCTest
@testable import IronPet

/// S5 to S7: what the MCP tools return for stored trees, old rows after the migration, and the rule that capture code names no app.
final class CaptureViewTests: XCTestCase {
    private var store: CaptureStore!
    private let app = CaptureApp(bundleId: "test.chat", name: "Chat")
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar = Calendar(identifier: .gregorian)

    override func setUp() {
        super.setUp()
        store = CaptureFixtures.store()
        calendar.timeZone = TimeZone(identifier: "Europe/Belgrade")!
    }

    @discardableResult
    private func ingest(_ tree: AXNode, at offset: TimeInterval = 0, title: String = "#general", app override: CaptureApp? = nil) throws -> Int64 {
        let (lines, inputs) = CaptureText.read(in: tree)
        guard case .stored(let id) = try store.ingest(app: override ?? app, title: title, url: nil, trigger: .idle, lines: lines, inputLines: inputs, tree: tree, now: t0.addingTimeInterval(offset)) else {
            throw XCTSkip("not stored")
        }
        return id
    }

    /// Ingests without requiring a capture to be stored.
    private func push(_ tree: AXNode, at offset: TimeInterval) throws {
        let (lines, inputs) = CaptureText.read(in: tree)
        try store.ingest(app: app, title: "#general", url: nil, trigger: .idle, lines: lines, inputLines: inputs, tree: tree, now: t0.addingTimeInterval(offset))
    }

    private func call(_ name: String, _ args: [String: Any], at offset: TimeInterval = 3600) throws -> [String: Any] {
        switch ScreenMCP.call(name, args, store: store, now: t0.addingTimeInterval(offset), calendar: calendar) {
        case .success(let value): return try XCTUnwrap(value as? [String: Any])
        case .failure(let failure): XCTFail(failure.message); return [:]
        }
    }

    private func json(_ value: Any) -> Int { (try? JSONSerialization.data(withJSONObject: value).count) ?? 0 }

    // MARK: S5

    func testTheChangeListHasOneLineForEachBlockWithLabelDateCaptureAndRef() throws {
        let id = try ingest(TreeFixtures.discord(messages: TreeFixtures.messages(8)))
        let result = try call("screen_window", ["since": "2h"])
        let windows = try XCTUnwrap(result["changes"] as? [[String: Any]])
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0]["app"] as? String, "Chat")
        XCTAssertEqual(windows[0]["window"] as? String, "#general")
        XCTAssertEqual(windows[0]["in"] as? String, "Messages in #general")
        let lines = try XCTUnwrap(windows[0]["changes"] as? [String])
        XCTAssertEqual(lines.count, 8)
        let follow = TreeFixtures.messages(8)[1]
        let line = try XCTUnwrap(lines.first { $0.contains(follow.text) })
        XCTAssertTrue(line.hasPrefix("2027-01-15T09:00+01:00 new | \(follow.author) , \(follow.text)"), line)
        XCTAssertTrue(line.contains("Wednesday, 18. November 2026 at \(follow.time)"), "the date from the page")
        XCTAssertTrue(line.contains("c\(id) #"), line)
        XCTAssertNil(windows[0]["more"])
    }

    func testTheListIsCappedPerWindowAndSaysHowManyMoreThereAre() throws {
        try ingest(TreeFixtures.discord(messages: TreeFixtures.messages(62)))
        let windows = try XCTUnwrap(try call("screen_window", ["since": "2h"])["changes"] as? [[String: Any]])
        XCTAssertEqual((windows[0]["changes"] as? [String])?.count, ScreenMCP.maxChangesPerWindow)
        XCTAssertEqual(windows[0]["more"] as? Int, 62 - ScreenMCP.maxChangesPerWindow)
    }

    func testTheChangeListIsFarSmallerThanTheFlatTextOfTheSameWindow() throws {
        let tree = TreeFixtures.discord(messages: TreeFixtures.messages(62))
        try ingest(tree)
        let flat = CaptureText.lines(in: tree).joined(separator: "\n").utf8.count
        let list = json(try call("screen_window", ["since": "2h"]))
        print("RATIO change list \(list) B, flat \(flat) B, \(Double(list) / Double(flat))")
        XCTAssertLessThan(Double(list), Double(flat) * 0.4, "change list \(list) B, flat text \(flat) B")
    }

    func testAnEditAndASentMessageShowTheirKinds() throws {
        let base = TreeFixtures.messages(5)
        try push(TreeFixtures.discord(messages: base), at: 0)
        var edited = base
        edited[2].text = "an edited line"
        edited.append(TreeFixtures.Message(id: 9_100, author: "Sam", text: "on my way", time: "10:10"))
        try push(TreeFixtures.discord(messages: edited, draft: "on my way"), at: 60)
        try push(TreeFixtures.discord(messages: edited), at: 90)
        let lines = try XCTUnwrap((try call("screen_window", ["since": "2h"])["changes"] as? [[String: Any]])?[0]["changes"] as? [String])
        XCTAssertEqual(lines.filter { $0.contains(" edited | ") }.count, 1)
        XCTAssertEqual(lines.filter { $0.contains(" sent | ") }.count, 1)
    }

    func testACaptureReadsAsAnOutlineWithRefsAndTheSubtreeAndRolesFollow() throws {
        let id = try ingest(TreeFixtures.discord(messages: TreeFixtures.messages(8)))
        let outline = try XCTUnwrap((try call("screen_window", ["id": Int(id)])["capture"] as? [String: Any])?["outline"] as? String)
        XCTAssertLessThan(outline.split(separator: "\n").count, 60)
        XCTAssertFalse(outline.contains("Reply"), "a label every message repeats is dropped")
        XCTAssertFalse(outline.contains("heading \"3\""), "a heading reads by name, not by its level")
        XCTAssertFalse(outline.contains("group #"), "wrappers with no name are skipped")
        XCTAssertTrue(outline.contains("group.documentarticle \"Alex , can you look"), outline)

        let line = try XCTUnwrap(outline.split(separator: "\n").first { $0.contains("sounds good") })
        let ref = try XCTUnwrap(line.split(separator: "#").last).split(separator: " ").first.map(String.init) ?? ""
        let subtree = try XCTUnwrap((try call("screen_window", ["id": Int(id), "root": ref])["capture"] as? [String: Any])?["outline"] as? String)
        XCTAssertTrue(subtree.contains("sounds good"), subtree)
        XCTAssertLessThan(subtree.split(separator: "\n").count, 15)

        let headings = try XCTUnwrap((try call("screen_window", ["id": Int(id), "role": "heading"])["capture"] as? [String: Any])?["elements"] as? String)
        XCTAssertTrue(headings.contains("heading \"Alex 09:00\""), headings)
        let none = ScreenMCP.call("screen_window", ["id": Int(id), "root": "zzzzzzzz"], store: store, now: t0)
        guard case .failure = none else { return XCTFail("an unknown ref is an error") }
    }

    func testTheReadRulesHelpTwoOfThreeFixturesAndHurtNone() throws {
        let fixtures = [TreeFixtures.discord(messages: TreeFixtures.messages(12)), TreeFixtures.slack(messages: TreeFixtures.messages(12)),
                        TreeFixtures.gmail(mails: TreeFixtures.mails(12))]
        var shorter = 0
        for fixture in fixtures {
            let tree = CaptureTree.prepare(fixture, clean: { $0 }).tree
            let raw = CaptureView.outline(tree, depth: 30, maxLines: 5000).lines.count
            let cleaned = CaptureView.outline(CaptureView.cleaned(tree), depth: 30, maxLines: 5000).lines.count
            XCTAssertLessThanOrEqual(cleaned, raw)
            if cleaned < raw { shorter += 1 }
            // The heading rule: no line is only a heading level.
            XCTAssertFalse(CaptureText.lines(in: fixture).contains { Int($0) != nil })
        }
        XCTAssertGreaterThanOrEqual(shorter, 2, "dropping text that sibling blocks repeat shortens at least two of the three")
    }

    // MARK: S6

    func testExistingCapturesAreDeletedOnUpgradeAndTheNewSchemaWorks() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-tree-migration-\(UUID().uuidString)/ironpet.db")
        addTeardownBlock { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        do {
            let old = try Database(path: file, migrations: CaptureStore.migrations.filter { $0.version <= 440 })
            try old.write { db in
                try db.execute("INSERT INTO capture_window(id, key, app, app_name, title, first_seen, last_seen) VALUES(1, 'k', 'old.app', 'Old', 'Notes', ?, ?)",
                               [t0.timeIntervalSince1970, t0.timeIntervalSince1970])
                try db.execute("INSERT INTO capture(window_id, at, app, app_name, title, trigger, text) VALUES(1, ?, 'old.app', 'Old', 'Notes', 'idle', 'the invoice 4649 is due')",
                               [t0.timeIntervalSince1970 + 5])
            }
            XCTAssertEqual(CaptureStore(database: old).captureCount, 1)
        }
        let upgraded = try Database(path: file, migrations: CaptureStore.migrations)
        store = CaptureStore(database: upgraded)
        XCTAssertEqual(store.captureCount, 0, "captures stored before the upgrade are deleted")
        XCTAssertTrue(store.search("invoice").isEmpty)
        XCTAssertEqual((try call("screen_window", ["since": "2d"])["changes"] as? [[String: Any]])?.count, 0)
        let names = Set(try upgraded.read { try $0.rows("SELECT name FROM sqlite_master") }.compactMap { $0[0] as? String })
        XCTAssertTrue(names.isSuperset(of: ["capture", "capture_window", "capture_fts", "capture_node", "capture_block_seen", "capture_draft"]))

        let first = try ingest(TreeFixtures.discord(messages: TreeFixtures.messages(6)), at: 100)
        XCTAssertGreaterThan(first, 1, "ids continue after the deleted ones, so a capture id stored as evidence never names a new capture")
        let message = TreeFixtures.messages(6)[1]
        let hits = try XCTUnwrap(try call("screen_search", ["query": message.author + " " + message.text.split(separator: " ")[0]])["hits"] as? [[String: Any]])
        XCTAssertTrue(hits.contains { $0["window"] as? String == "#general" }, "a label and its text are searchable")
    }

    func testAScreenshotReadIsStoredAsOneTextBlockWithNoTree() throws {
        guard case .stored(let id) = try store.ingest(app: app, title: "Remote desktop", url: nil, trigger: .idle,
                                                      lines: ["Quarterly numbers", "Revenue up 4 percent"], now: t0) else { return XCTFail() }
        let windows = try XCTUnwrap(try call("screen_window", ["since": "2h"])["changes"] as? [[String: Any]])
        let line = try XCTUnwrap((windows.first?["changes"] as? [String])?.first)
        XCTAssertTrue(line.contains("new | Remote desktop: Quarterly numbers"), line)
        let capture = try XCTUnwrap(try call("screen_window", ["id": Int(id)])["capture"] as? [String: Any])
        XCTAssertEqual(capture["text"] as? String, "Quarterly numbers\nRevenue up 4 percent")
        XCTAssertEqual((try call("screen_search", ["query": "revenue"])["hits"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(try store.ingest(app: app, title: "Remote desktop", url: nil, trigger: .idle, lines: ["Quarterly numbers", "Revenue up 4 percent"], now: t0.addingTimeInterval(10)), .unchanged)
    }

    // MARK: S7

    func testCaptureCodeNamesNoApp() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/IronPet/Capture")
        let names = try NSRegularExpression(pattern: #"\b(slack|discord|gmail|whatsapp|telegram|safari|chrome|firefox|zoom|outlook|notion|github|cursor|xcode|iterm|vscode|mail\.app)\b"#, options: .caseInsensitive)
        let bundle = try NSRegularExpression(pattern: #"\b(com|org|net|io)\.[a-z0-9_-]+\.[a-z0-9_.-]+"#)
        var found: [String] = []
        // CapturePrivacy holds the deny lists. CaptureRedactor recognises credential formats, which providers name, not apps.
        let exempt: Set<String> = ["CapturePrivacy.swift", "CaptureRedactor.swift"]
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") && !exempt.contains($0) }
        XCTAssertGreaterThan(files.count, 10)
        for file in files {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                let hit = names.firstMatch(in: String(line), range: range) != nil
                    || (bundle.firstMatch(in: String(line), range: range) != nil && !line.contains("com.ironpet") && !line.contains("com.apple.screen"))
                if hit { found.append("\(file):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))") }
            }
        }
        XCTAssertEqual(found, [], "capture and read code must not name an app; the deny lists live in CapturePrivacy")
    }
}
