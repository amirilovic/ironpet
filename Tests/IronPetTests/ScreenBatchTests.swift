import XCTest
@testable import IronPet

@MainActor
final class ScreenBatchTests: XCTestCase {
    private var database: Database!
    private var tasks: TaskStore!
    private var capture: CaptureStore!
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        try await super.setUp()
        database = Database.open(path: nil, migrations: AppMigrations.all).database
        tasks = TaskStore(database: database, now: { self.base }, keepDoneDays: { 30 })
        capture = CaptureStore(database: database)
        tasks.ignoreCapture = { [capture] fingerprint, kind in capture?.ignore(fingerprint: fingerprint, kind: kind) }
    }

    private func item(_ thread: String, _ text: String) throws -> Int64 {
        let item = CaptureItem(app: CaptureApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack"), threadKey: thread, threadTitle: thread,
                               content: .conversation(title: thread, isGroup: false, messages: [CaptureMessage(author: "Ana", text: text)]), parser: "test")
        return try XCTUnwrap(try capture.ingest(item, now: base).itemId)
    }

    private func proposal(_ title: String, log: Int64, items: [Int64]) -> CaptureProposal {
        var p = CaptureProposal(id: CaptureStore.fingerprint(kind: "new_task", title: title), kind: .newTask, title: title, notes: "", due: nil,
                                taskId: nil, status: nil, sources: items, quote: "quote for \(title)", diff: [])
        p.sendLog = log
        return p
    }

    private func send(_ items: [Int64]) throws -> Int64 {
        capture.logSend(harness: "claude", model: "sonnet", items: items, bytes: 500, outcome: "sent", now: base)
        return try XCTUnwrap(capture.lastSendLogId)
    }

    func testBatchListsExactlyItsItems() throws {
        let a = try item("slack:a", "first"), b = try item("slack:b", "second"), c = try item("slack:c", "third")
        let log = try send([a, c])
        _ = b
        let batch = try XCTUnwrap(ScreenBatchLoader.load(log, capture: capture, tasks: tasks))
        XCTAssertEqual(batch.items.map(\.id), [a, c])
        XCTAssertEqual(batch.items.first?.app, "Slack")
        XCTAssertEqual(batch.items.first?.title, "slack:a")
        XCTAssertEqual(batch.record.bytes, 500)
    }

    func testPrunedItemStaysListed() throws {
        let log = try send([9_999])
        let batch = try XCTUnwrap(ScreenBatchLoader.load(log, capture: capture, tasks: tasks))
        XCTAssertEqual(batch.items.map(\.id), [9_999])
        XCTAssertNil(batch.items[0].app)
        XCTAssertTrue(ScreenBatchText.itemTitle(batch.items[0]).contains("no longer stored"))
    }

    func testPendingAcceptedAndRejectedSuggestionsOfOneBatch() throws {
        let a = try item("slack:a", "first")
        let log = try send([a])
        let other = try send([a])
        tasks.suggest(capture: [proposal("Pending one", log: log, items: [a]), proposal("Accept me", log: log, items: [a]),
                                proposal("Reject me", log: log, items: [a]), proposal("Other batch", log: other, items: [a])])
        let accept = try XCTUnwrap(tasks.suggestions.first { $0.title == "Accept me" })
        let reject = try XCTUnwrap(tasks.suggestions.first { $0.title == "Reject me" })
        let task = try tasks.accept(accept.id)
        try tasks.reject(reject.id, note: "not mine", by: "user")

        let batch = try XCTUnwrap(ScreenBatchLoader.load(log, capture: capture, tasks: tasks))
        XCTAssertEqual(batch.suggestions.count, 3)
        XCTAssertEqual(Set(tasks.suggestions.map(\.title)), ["Pending one", "Other batch"], "the resolved ones left task_suggestions")
        let byTitle = Dictionary(uniqueKeysWithValues: batch.suggestions.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["Pending one"]?.outcome, .pending(id: try XCTUnwrap(tasks.suggestions.first { $0.title == "Pending one" }).id))
        XCTAssertEqual(byTitle["Accept me"]?.outcome, .accepted(task: task.id, title: "Accept me"))
        XCTAssertEqual(byTitle["Reject me"]?.outcome, .rejected(note: "not mine"))
        XCTAssertEqual(byTitle["Accept me"]?.quote, "quote for Accept me")
        XCTAssertEqual(ScreenBatchLoader.counts([log, other], tasks: tasks), [log: 3, other: 1])
    }

    func testSkipWithoutANoteIsRejectedWithNoNote() throws {
        let log = try send([])
        let s = try XCTUnwrap(tasks.suggest(capture: [proposal("Skip me", log: log, items: [])]).first)
        tasks.skip(s.id)
        let batch = try XCTUnwrap(ScreenBatchLoader.load(log, capture: capture, tasks: tasks))
        XCTAssertEqual(batch.suggestions.map(\.outcome), [.rejected(note: nil)])
    }

    func testBatchWithNoSuggestionsStillListsItsItems() throws {
        let a = try item("slack:a", "first")
        let log = try send([a])
        let batch = try XCTUnwrap(ScreenBatchLoader.load(log, capture: capture, tasks: tasks))
        XCTAssertTrue(batch.suggestions.isEmpty)
        XCTAssertEqual(batch.items.map(\.id), [a])
        XCTAssertEqual(ScreenBatchLoader.counts([log], tasks: tasks), [log: 0])
    }

    func testRedactedItemShowsTheStoredRedactedTextAndSummary() throws {
        let key = "AKIAIOSFODNN7EXAMPLE"
        let a = try item("slack:a", "the key is \(key) ok")
        let log = try send([a])
        let batch = try XCTUnwrap(ScreenBatchLoader.load(log, capture: capture, tasks: tasks))
        let shown = try XCTUnwrap(batch.items.first)
        XCTAssertFalse(shown.body.contains(key), "the raw secret is never in the batch view")
        XCTAssertTrue(shown.body.contains("[redacted:"), shown.body)
        XCTAssertFalse(batch.redactions.isEmpty)
        XCTAssertTrue(batch.redactions.summary.hasPrefix("redacted"))
    }

    func testTaskAcceptedBeforeOutcomesWereRecordedIsStillListed() throws {
        let log = try send([])
        _ = try tasks.create(title: "Old accepted", notes: "", status: .backlog, source: .capture, sourceRef: TaskStore.refText(["send_log": Int(log), "ref": "capture_send_log:\(log)"]), by: "user")
        let batch = try XCTUnwrap(ScreenBatchLoader.load(log, capture: capture, tasks: tasks))
        XCTAssertEqual(batch.suggestions.map(\.title), ["Old accepted"])
    }

    func testOutcomesPastKeepDoneDaysArePruned() throws {
        let log = try send([])
        let s = try XCTUnwrap(tasks.suggest(capture: [proposal("Old skip", log: log, items: [])]).first)
        tasks.skip(s.id)
        XCTAssertEqual(tasks.captureOutcomes(sendLog: log).count, 1)
        let later = base.addingTimeInterval(31 * 86_400)
        let aged = TaskStore(database: database, now: { later }, keepDoneDays: { 30 })
        aged.prune()
        XCTAssertTrue(aged.captureOutcomes(sendLog: log).isEmpty)
    }

    func testMigration431UpgradesADatabaseAt430() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-batch-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: file) }
        let old = AppMigrations.all.filter { $0.version <= 430 }
        XCTAssertEqual(old.map(\.version).max(), 430)
        XCTAssertEqual(AppMigrations.all.map(\.version).max(), 431)
        XCTAssertEqual(Set(AppMigrations.all.map(\.version)).count, AppMigrations.all.count, "no version is used twice")
        var db: Database? = try Database(path: file, migrations: old)
        XCTAssertEqual(db?.schemaVersion, 430)
        db = nil
        let upgraded = try Database(path: file, migrations: AppMigrations.all)
        XCTAssertEqual(upgraded.schemaVersion, 431)
        XCTAssertNoThrow(try upgraded.read { try $0.rows("SELECT send_log, outcome FROM task_suggestion_outcomes") })
    }
}
