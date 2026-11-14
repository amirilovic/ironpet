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
