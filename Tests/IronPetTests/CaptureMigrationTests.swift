import XCTest
@testable import IronPet

/// S6: the old capture tables go, the new ones exist, and task data from meetings and automations is intact.
@MainActor
final class CaptureMigrationTests: XCTestCase {
    /// The tables the per-app pipeline created in migrations 300 to 302, as they were.
    private static let oldCaptureSchema = """
        CREATE TABLE capture_threads(id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT NOT NULL, app TEXT NOT NULL, app_name TEXT NOT NULL,
                                     title TEXT NOT NULL, kind TEXT NOT NULL, url TEXT, first_seen REAL NOT NULL, last_seen REAL NOT NULL,
                                     last_hash TEXT NOT NULL DEFAULT '', last_text TEXT NOT NULL DEFAULT '', UNIQUE(app, key));
        CREATE TABLE capture_messages(thread_id INTEGER NOT NULL, fingerprint TEXT NOT NULL, author TEXT, body TEXT NOT NULL, sent_at TEXT,
                                      first_seen REAL NOT NULL, PRIMARY KEY(thread_id, fingerprint)) WITHOUT ROWID;
        CREATE TABLE capture_items(id INTEGER PRIMARY KEY AUTOINCREMENT, thread_id INTEGER NOT NULL, at REAL NOT NULL, hash TEXT NOT NULL,
                                   version INTEGER NOT NULL, new_messages INTEGER NOT NULL, body TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'new',
                                   reason TEXT, secret REAL, related TEXT, calendar REAL, task REAL, sent_at REAL, redactions TEXT);
        CREATE TABLE capture_ignored(fingerprint TEXT PRIMARY KEY, kind TEXT NOT NULL, at REAL NOT NULL) WITHOUT ROWID;
        CREATE TABLE capture_send_log(id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, harness TEXT NOT NULL, model TEXT NOT NULL,
                                      items TEXT NOT NULL, bytes INTEGER NOT NULL, outcome TEXT NOT NULL);
        CREATE TABLE capture_originals(item_id INTEGER PRIMARY KEY, body TEXT NOT NULL, at REAL NOT NULL);
        """

    private func tables(_ database: Database) throws -> Set<String> {
        Set(try database.read { try $0.rows("SELECT name FROM sqlite_master WHERE type IN ('table', 'view')") }.compactMap { $0[0] as? String })
    }

    func testOldTablesAreDroppedNewOnesCreatedAndTaskDataKept() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-capture-migration-\(UUID().uuidString)/ironpet.db")
        addTeardownBlock { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let meeting = "/tmp/meetings/2026-11-17-0930"
        XCTAssertGreaterThan(CaptureStore.migrations.map(\.version).min() ?? 0, 431)
        do {
            // The database as the app left it: the old capture schema at its old versions, and the task schema as of the last release.
            let before = TaskStore.migrations.filter { $0.version <= 431 } + [.init(300, "capture (old)", sql: Self.oldCaptureSchema)]
            let old = try Database(path: file, migrations: before)
            XCTAssertEqual(old.schemaVersion, 431)
            try old.write { db in
                try db.execute("INSERT INTO capture_threads(id, key, app, app_name, title, kind, first_seen, last_seen) VALUES(1, 'k', 'a', 'A', 't', 'page', 0, 0)")
                try db.execute("INSERT INTO capture_items(thread_id, at, hash, version, new_messages, body) VALUES(1, 0, 'h', 1, 1, 'old body')")
                try db.execute("INSERT INTO capture_send_log(at, harness, model, items, bytes, outcome) VALUES(0, 'claude', 'm', '[1]', 9, 'sent')")
                try db.execute("INSERT INTO capture_ignored(fingerprint, kind, at) VALUES('f', 'new_task', 0)")
                try db.execute("INSERT INTO task_items(id, title, notes, status, source, created, updated) VALUES('reply-to-sam', 'Reply to Sam', 'From screen capture items 1', 'backlog', 'capture', 1, 1)")
                try db.execute("INSERT INTO task_items(id, title, notes, status, source, created, updated) VALUES('book', 'Book the room', '', 'needs_you', 'meeting', 1, 1)")
                try db.execute("INSERT INTO task_suggestions(id, title, due, meeting, created) VALUES('send-deck', 'Send the deck', 'Friday', ?, 1)", [meeting])
                try db.execute("""
                    INSERT INTO task_suggestions(id, title, notes, url, automation, automation_name, created, waiting_on, source_ref)
                    VALUES('review-pr', 'Review PR 12', 'From the watcher', 'https://example.com/pr/12', 'prs', 'PRs', 2, 'Ana', '{"ref":"prs"}')
                    """)
                try db.execute("INSERT INTO task_suggestions(id, title, capture, kind, quote, evidence, created) VALUES('from-screen', 'From the screen', 'fp', 'new_task', 'q', '[1]', 3)")
                try db.execute("INSERT INTO task_suggestion_outcomes(send_log, suggestion, kind, title, outcome, at) VALUES(1, 'x', 'new_task', 'X', 'accepted', 0)")
            }
        }

        let migrated = try Database(path: file, migrations: AppMigrations.all)
        XCTAssertEqual(migrated.schemaVersion, AppMigrations.all.map(\.version).max())
        let names = try tables(migrated)
        for gone in ["capture_threads", "capture_messages", "capture_items", "capture_ignored", "capture_send_log", "capture_originals", "task_suggestion_outcomes"] {
            XCTAssertFalse(names.contains(gone), "\(gone) is still there")
        }
        for made in ["capture_window", "capture", "capture_fts"] { XCTAssertTrue(names.contains(made), "\(made) is missing") }

        let tasks = TaskStore(database: migrated, now: { Date(timeIntervalSince1970: 10) }, keepDoneDays: { 30 })
        XCTAssertEqual(tasks.task("reply-to-sam")?.source, .capture, "a task a person was working on stays")
        XCTAssertEqual(tasks.task("book")?.title, "Book the room")
        XCTAssertEqual(tasks.suggestions.map(\.id).sorted(), ["review-pr", "send-deck"], "meeting and automation suggestions stay, the screen one goes")
        XCTAssertEqual(tasks.suggestions.first { $0.id == "review-pr" }?.waitingOn, "Ana")
        XCTAssertEqual(tasks.suggestions.first { $0.id == "review-pr" }?.sourceRef, #"{"ref":"prs"}"#)
        let columns = try migrated.read { try $0.rows("PRAGMA table_info(task_suggestions)") }.compactMap { $0[1] as? String }
        for dropped in ["capture", "kind", "target", "changes", "diff", "quote", "evidence"] { XCTAssertFalse(columns.contains(dropped), dropped) }
        XCTAssertThrowsError(try migrated.write { try $0.execute("INSERT INTO task_suggestions(id, title, created) VALUES('x', 'x', 0)") }, "one origin is still required")

        let store = CaptureStore(database: migrated)
        XCTAssertEqual(store.captureCount, 0, "nothing is carried over")
        _ = try store.ingest(app: CaptureApp(bundleId: "a", name: "A"), title: "w", url: nil, trigger: .idle, lines: ["fresh text"])
        XCTAssertEqual(store.search("fresh").count, 1)
    }

    func testAFreshDatabaseHasTheNewTablesOnly() throws {
        let database = Database.open(path: nil, migrations: AppMigrations.all).database
        let names = try tables(database)
        XCTAssertTrue(names.isSuperset(of: ["capture_window", "capture", "capture_fts", "task_items", "task_suggestions"]))
        XCTAssertFalse(names.contains("capture_items") || names.contains("task_suggestion_outcomes"))
    }
}
