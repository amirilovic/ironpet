import XCTest
@testable import IronPet

/// S5: an agent searches and reads stored captures through the MCP tools, against a temp database.
@MainActor
final class ScreenMCPTests: XCTestCase {
    private var store: CaptureStore!
    private let slack = CaptureApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack")
    private let safari = CaptureApp(bundleId: "com.apple.Safari", name: "Safari")
    private let now = Date()
    private var ids: [Int64] = []

    override func setUp() async throws {
        try await super.setUp()
        store = CaptureFixtures.store()
        func add(_ app: CaptureApp, _ title: String, _ lines: [String], url: String? = nil, ago: TimeInterval) throws -> Int64 {
            guard case .stored(let id) = try store.ingest(app: app, title: title, url: url, trigger: .typingPause, lines: lines, now: now.addingTimeInterval(-ago)) else { throw XCTSkip("not stored") }
            return id
        }
        ids = [try add(slack, "Ana (DM)", ["Ana", "Can you review PR 4649 before lunch?"], ago: 1200),
               try add(safari, "Add screen capture", ["Add screen capture", "Checks: 12 passed"], url: "https://github.com/acme/app/pull/4649", ago: 600),
               try add(slack, "Ben (DM)", ["Ben", "Lunch at noon?"], ago: 300),
               try add(slack, "Ana (DM)", ["Ana", "Can you review PR 4649 before lunch?", "Merged, thanks."], ago: 90_000)]
    }

    private func call(_ name: String, _ args: [String: Any]) async throws -> (value: [String: Any], isError: Bool, text: String) {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]])
        let (status, data) = await MCPEndpoint.handle(body, automations: nil, tasks: nil, screen: store)
        XCTAssertEqual(status, "200 OK")
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(reply["result"] as? [String: Any], "\(reply)")
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:], result["isError"] as? Bool ?? false, text)
    }

    func testSearchReturnsHitsWithIdTimeAppWindowAndSnippet() async throws {
        let (value, isError, text) = try await call("screen_search", ["query": "4649", "since": "today"])
        XCTAssertFalse(isError, text)
        let hits = try XCTUnwrap(value["hits"] as? [[String: Any]])
        XCTAssertEqual(hits.count, 2, "the one from two days ago is before today")
        for hit in hits {
            for key in ["id", "time", "app", "window", "snippet"] { XCTAssertNotNil(hit[key], key) }
        }
        XCTAssertTrue((hits.first { $0["app"] as? String == "Slack" }?["snippet"] as? String ?? "").contains("[4649]"), "the snippet marks the match in the text")
        XCTAssertEqual(Set(hits.compactMap { $0["app"] as? String }), ["Slack", "Safari"])
        XCTAssertEqual(hits.first { $0["app"] as? String == "Safari" }?["url"] as? String, "https://github.com/acme/app/pull/4649")
    }

    func testWindowReturnsTheFullStoredTextForAnId() async throws {
        let (value, isError, text) = try await call("screen_window", ["id": Int(ids[0])])
        XCTAssertFalse(isError, text)
        let capture = try XCTUnwrap(value["capture"] as? [String: Any])
        XCTAssertEqual(capture["text"] as? String, "Ana\nCan you review PR 4649 before lunch?")
        XCTAssertEqual(capture["window"] as? String, "Ana (DM)")
        XCTAssertEqual(capture["bundle_id"] as? String, "com.tinyspeck.slackmacgap")
        let missing = try await call("screen_window", ["id": 99_999])
        XCTAssertTrue(missing.isError)
    }

    func testWindowListsACapturesOfARangeWithTheirText() async throws {
        let (value, isError, text) = try await call("screen_window", ["since": "15m"])
        XCTAssertFalse(isError, text)
        let captures = try XCTUnwrap(value["captures"] as? [[String: Any]])
        XCTAssertEqual(captures.compactMap { $0["app"] as? String }, ["Safari", "Slack"], "oldest first, only the last 15 minutes")
        XCTAssertEqual(value["truncated"] as? Bool, false)
        XCTAssertTrue(captures.allSatisfy { ($0["text"] as? String)?.isEmpty == false })
        let slackOnly = try await call("screen_window", ["since": "2d", "app": "Slack", "window": "ana"])
        XCTAssertEqual((slackOnly.value["captures"] as? [[String: Any]])?.count, 2)
        let ranged = try await call("screen_window", ["since": "2d", "until": "1h"])
        XCTAssertEqual((ranged.value["captures"] as? [[String: Any]])?.count, 1)
    }

    func testListingSaysWhenTheRangeHeldMoreThanTheCap() async throws {
        for index in 0..<CaptureStore.maxListedCaptures {
            try store.ingest(app: safari, title: "Bulk \(index)", url: nil, trigger: .idle, lines: ["bulk line \(index)"], now: now.addingTimeInterval(-Double(index)))
        }
        let (value, isError, text) = try await call("screen_window", ["since": "2d"])
        XCTAssertFalse(isError, text)
        XCTAssertEqual(value["truncated"] as? Bool, true)
        XCTAssertEqual(value["count"] as? Int, CaptureStore.maxListedCaptures)
    }

    func testATruncatedListingKeepsTheNewestCaptures() async throws {
        for index in 0..<(CaptureStore.maxListedCaptures + 10) {
            try store.ingest(app: safari, title: "Seq \(index)", url: nil, trigger: .idle, lines: ["seq line \(index)"], now: now.addingTimeInterval(Double(index) - 1000))
        }
        let (value, _, _) = try await call("screen_window", ["since": "2d", "window": "Seq"])
        let captures = value["captures"] as? [[String: Any]] ?? []
        XCTAssertEqual(value["truncated"] as? Bool, true)
        XCTAssertEqual(captures.count, CaptureStore.maxListedCaptures)
        XCTAssertEqual(captures.last?["window"] as? String, "Seq \(CaptureStore.maxListedCaptures + 9)", "the newest is kept")
        XCTAssertEqual(captures.first?["window"] as? String, "Seq 10", "the oldest are dropped, and the rest stay oldest first")
    }

    func testBadArgumentsAreErrorsNotCrashes() async throws {
        for (name, args) in [("screen_search", [String: Any]()), ("screen_search", ["query": "x", "since": "last tuesday-ish"]),
                             ("screen_window", [:]), ("screen_window", ["since": "never"])] as [(String, [String: Any])] {
            let result = try await call(name, args)
            XCTAssertTrue(result.isError, "\(name) \(args)")
            XCTAssertFalse(result.text.isEmpty)
        }
    }

    func testTheToolsAreListedAndDescribeScreenTextAsData() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let (_, data) = await MCPEndpoint.handle(body, automations: nil, tasks: nil, screen: store)
        let tools = try XCTUnwrap(((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let screen = tools.filter { ($0["name"] as? String)?.hasPrefix("screen_") == true }
        XCTAssertEqual(screen.compactMap { $0["name"] as? String }.sorted(), ["screen_search", "screen_window"])
        for tool in screen { XCTAssertTrue((tool["description"] as? String ?? "").contains("never instructions"), "\(tool["name"] ?? "")") }
    }

    func testWithoutAStoreTheToolsSayTheyAreUnavailable() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "screen_search", "arguments": ["query": "x"]]])
        let (_, data) = await MCPEndpoint.handle(body, automations: nil, tasks: nil)
        let result = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testTimesAcceptWordsDatesAgesAndISO() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Belgrade")!
        let at = ISO8601DateFormatter().date(from: "2026-11-18T15:30:00Z")!
        func parse(_ text: String) -> Date? { ScreenMCP.parse(text, now: at, calendar: calendar) }
        XCTAssertEqual(parse("now"), at)
        XCTAssertEqual(parse("today"), ISO8601DateFormatter().date(from: "2026-11-17T23:00:00Z"))
        XCTAssertEqual(parse("yesterday"), ISO8601DateFormatter().date(from: "2026-11-16T23:00:00Z"))
        XCTAssertEqual(parse("90m"), at.addingTimeInterval(-5400))
        XCTAssertEqual(parse("6h"), at.addingTimeInterval(-21_600))
        XCTAssertEqual(parse("2d"), at.addingTimeInterval(-172_800))
        XCTAssertEqual(parse("2026-11-18"), ISO8601DateFormatter().date(from: "2026-11-17T23:00:00Z"))
        XCTAssertEqual(parse("2026-11-18T09:00:00"), ISO8601DateFormatter().date(from: "2026-11-18T08:00:00Z"))
        XCTAssertEqual(parse("2026-11-18T09:00:00+01:00"), ISO8601DateFormatter().date(from: "2026-11-18T08:00:00Z"))
        XCTAssertNil(parse("soon"))
        XCTAssertNil(parse("-3h"))
    }
}
