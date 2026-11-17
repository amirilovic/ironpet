import XCTest
@testable import IronPet

final class DatabaseTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("ironpet.db") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let v1 = Database.Migration(1, "notes", sql: "CREATE TABLE note_items(id INTEGER PRIMARY KEY, body TEXT NOT NULL);")
    private let v2 = Database.Migration(2, "notes tags", sql: "ALTER TABLE note_items ADD COLUMN tag TEXT; CREATE INDEX note_items_tag ON note_items(tag);")

    private func tables(_ db: Database) throws -> Set<String> {
        Set(try db.read { try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") }.compactMap { $0[0] as? String })
    }

    func testFreshDatabaseGetsEveryMigrationInOrderAndWAL() throws {
        let db = try Database(path: file, migrations: [v2, v1])
        XCTAssertEqual(db.schemaVersion, 2)
        XCTAssertEqual(try tables(db), ["note_items"])
        let mode = try db.read { try $0.rows("PRAGMA journal_mode").first?.first as? String }
        XCTAssertEqual(mode, "wal")
        XCTAssertEqual(try Data(contentsOf: file).prefix(15), Data("SQLite format 3".utf8))
    }

    func testUpgradeFromVersionOneKeepsDataAndAppliesOnlyTheNewMigration() throws {
        var db: Database? = try Database(path: file, migrations: [v1])
        try db?.write { try $0.execute("INSERT INTO note_items(body) VALUES(?)", ["keep me"]) }
        XCTAssertEqual(db?.schemaVersion, 1)
        db = nil
        var applied: [Int] = []
        let counting = [Database.Migration(1, "notes") { _ in applied.append(1) },
                        Database.Migration(2, "notes tags") { try $0.script("ALTER TABLE note_items ADD COLUMN tag TEXT;"); applied.append(2) }]
        let upgraded = try Database(path: file, migrations: counting)
        XCTAssertEqual(applied, [2], "version 1 is not run again")
        XCTAssertEqual(upgraded.schemaVersion, 2)
        let body = try upgraded.read { try $0.rows("SELECT body, tag FROM note_items").first }
        XCTAssertEqual(body?[0] as? String, "keep me")
        XCTAssertNil(body?[1] ?? nil)
    }

    func testReopeningWithNothingNewChangesNothing() throws {
        _ = try Database(path: file, migrations: [v1, v2])
        var ran = false
        let again = try Database(path: file, migrations: [v1, v2, Database.Migration(2, "x") { _ in ran = true }].dropLast())
        XCTAssertFalse(ran)
        XCTAssertEqual(again.schemaVersion, 2)
    }

    func testAFailedMigrationRollsBackAndKeepsTheEarlierVersion() throws {
        _ = try Database(path: file, migrations: [v1])
        let broken = Database.Migration(2, "half done") { db in
            try db.script("CREATE TABLE half_done(id INTEGER);")
            try db.execute("INSERT INTO missing_table VALUES(1)")
        }
        XCTAssertThrowsError(try Database(path: file, migrations: [v1, broken])) { error in
            XCTAssertTrue(error.localizedDescription.contains("migration 2 (half done) failed"), error.localizedDescription)
        }
        let after = try Database(path: file, migrations: [v1])
        XCTAssertEqual(after.schemaVersion, 1, "the version did not move")
        XCTAssertEqual(try tables(after), ["note_items"], "the table the failed migration created is gone")
        // A fixed migration then applies cleanly.
        let fixed = try Database(path: file, migrations: [v1, v2])
        XCTAssertEqual(fixed.schemaVersion, 2)
    }

    func testEachMigrationHasItsOwnTransaction() throws {
        let broken = Database.Migration(2, "fails") { _ in throw Database.Failure(message: "nope") }
        XCTAssertThrowsError(try Database(path: file, migrations: [v1, broken, Database.Migration(3, "never")  { _ in }]))
        let db = try Database(path: file, migrations: [v1])
        XCTAssertEqual(db.schemaVersion, 1, "migration 1 stayed applied when 2 failed")
    }

    func testDatabaseFromANewerIronpetIsRefusedAndOpenFallsBackToMemory() throws {
        _ = try Database(path: file, migrations: [v1, v2])
        XCTAssertThrowsError(try Database(path: file, migrations: [v1])) { XCTAssertTrue($0.localizedDescription.contains("newer")) }
        let fallback = Database.open(path: file, migrations: [v1])
        XCTAssertNotNil(fallback.error)
        XCTAssertNil(fallback.database.path)
        XCTAssertEqual(try tables(fallback.database), ["note_items"])
    }

    func testDuplicateVersionsAreRejected() {
        XCTAssertThrowsError(try Database(path: nil, migrations: [v1, Database.Migration(1, "again", sql: "SELECT 1;")]))
    }

    func testAThrowingWriteRollsBackEverythingInIt() throws {
        let db = try Database(path: file, migrations: [v1])
        XCTAssertThrowsError(try db.write { conn in
            try conn.execute("INSERT INTO note_items(body) VALUES('a')")
            try conn.execute("INSERT INTO note_items(body) VALUES(NULL)")
        })
        XCTAssertEqual(try db.read { try $0.rows("SELECT COUNT(*) FROM note_items").first?.first as? Int64 }, 0)
    }

    func testWritesFromManyThreadsAreSerializedAndReadsRunAlongside() throws {
        let db = try Database(path: file, migrations: [v1])
        let group = DispatchGroup()
        for i in 0..<200 {
            DispatchQueue.global().async(group: group) {
                try? db.write { try $0.execute("INSERT INTO note_items(body) VALUES(?)", ["n\(i)"]) }
                _ = try? db.read { try $0.rows("SELECT COUNT(*) FROM note_items") }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(try db.read { try $0.rows("SELECT COUNT(*) FROM note_items").first?.first as? Int64 }, 200)
    }

    func testInMemoryDatabaseWorks() throws {
        let db = try Database(path: nil, migrations: [v1, v2])
        try db.write { try $0.execute("INSERT INTO note_items(body, tag) VALUES(?, ?)", ["x", "t"]) }
        XCTAssertEqual(try db.read { try $0.rows("SELECT tag FROM note_items").first?.first as? String }, "t")
    }
}

@MainActor
final class DatabaseUnavailableTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("ironpet.db") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-dbu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// A file in the default (rollback journal) mode at a version no migration reaches.
    private func makeNewerFile() throws -> Data {
        let tasks = Database.Migration(1, "t", sql: "CREATE TABLE t(x);")
        var db: Database? = try Database(path: file, migrations: [tasks])
        // One above the newest registered migration, so adding a migration cannot make this file look current.
        let newer = (AppMigrations.all.map(\.version).max() ?? 0) + 1
        try db?.write { try $0.script("INSERT INTO t VALUES(1); PRAGMA user_version = \(newer)") }
        db = nil
        // Back to a plain file with no -wal or -shm next to it.
        let out = Process()
        out.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        out.arguments = [file.path, "PRAGMA journal_mode=DELETE;"]
        out.standardOutput = FileHandle.nullDevice
        try out.run(); out.waitUntilExit()
        return try Data(contentsOf: file)
    }

    func testNewerFileRaisesAnAlertWithReasonAndPathAndStaysUntouched() throws {
        let before = try makeNewerFile()
        let (database, error) = Database.open(path: file, migrations: AppMigrations.all)
        XCTAssertNotNil(error)
        let signals = SignalStore()
        var notified: Signal?
        signals.onNew = { notified = $0 }
        signals.reportIfUnavailable(database)
        let alert = try XCTUnwrap(signals.signals.first)
        XCTAssertEqual(alert.label, "ironpet can't open its database")
        XCTAssertEqual(alert.mood, .failed)
        XCTAssertTrue(alert.title.contains("newer than this ironpet knows"))
        XCTAssertTrue(alert.title.contains("Install that build or a newer one"))
        XCTAssertTrue(alert.title.contains(file.path))
        XCTAssertEqual(notified?.id, alert.id)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + "-wal"))
    }

    func testTasksShowTheUnavailableStateNotTheEmptyOne() throws {
        _ = try makeNewerFile()
        let store = TaskStore(database: Database.open(path: file, migrations: AppMigrations.all).database)
        XCTAssertNotNil(store.unavailable)
        XCTAssertEqual(TaskListView.content(unavailable: store.unavailable != nil, isEmpty: true), .unavailable)
        XCTAssertEqual(TaskListView.content(unavailable: false, isEmpty: true), .empty)
        XCTAssertNotNil(UsageStore(database: Database.open(path: file, migrations: AppMigrations.all).database).unavailable)
    }

    func testTasksToolsReturnAnErrorNamingTheReason() throws {
        _ = try makeNewerFile()
        let store = TaskStore(database: Database.open(path: file, migrations: AppMigrations.all).database)
        for op in ["list", "create"] {
            guard case .failure(let error) = store.call(op, ["title": "x"], by: "agent:mcp") else { return XCTFail("\(op) succeeded") }
            XCTAssertTrue(error.message.contains("newer than this ironpet knows"), error.message)
            XCTAssertTrue(error.message.contains("Not saved"), error.message)
        }
        let cli = TaskMCP.handleCLI(Data(#"{"op":"list"}"#.utf8), store: store)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: cli.body) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertTrue((object["error"] as? String)?.contains("newer than this ironpet knows") == true)
    }

    func testNormalDatabaseShowsNoAlertOrBanner() throws {
        let database = Database.open(path: file, migrations: AppMigrations.all).database
        let signals = SignalStore()
        signals.reportIfUnavailable(database)
        XCTAssertTrue(signals.signals.isEmpty)
        let store = TaskStore(database: database)
        XCTAssertNil(store.unavailable)
        XCTAssertNil(UsageStore(database: database).unavailable)
        guard case .success = store.call("list", [:], by: "agent:mcp") else { return XCTFail("list failed") }
    }
}
