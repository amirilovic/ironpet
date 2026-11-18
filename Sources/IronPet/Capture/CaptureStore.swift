import CryptoKit
import Foundation

/// An on-device filter that can rewrite or empty captured text. Capture calls it on write, after the rule-based redaction and before
/// the diff, and the MCP tools and the Screen section call it on read. The default does nothing. A model-based filter plugs in here;
/// this build ships none.
protocol CapturePrivacyFilter: Sendable {
    func filterOnWrite(_ text: String, app: String) -> String
    func filterOnRead(_ text: String, app: String) -> String
}

struct PassthroughPrivacyFilter: CapturePrivacyFilter {
    func filterOnWrite(_ text: String, app: String) -> String { text }
    func filterOnRead(_ text: String, app: String) -> String { text }
}

/// Screen captures in ironpet's shared database: one row per window, one row per capture, and an FTS5 index over the text.
///
/// Text is redacted (`CaptureRedactor`) before it is stored. A capture of a window with an accessibility tree stores the tree as
/// hashed nodes (`CaptureTree`) and records the blocks that are new in it (`CaptureTreeStore`). A window with no blocks, and a
/// screenshot read, keep a short hash of each line of the last capture and store only the lines whose hash was not there, with a few
/// lines of context. Tables are prefixed `capture_`. Captured text never goes into logs.
final class CaptureStore: @unchecked Sendable {
    /// Versions start at 440, after every migration of the other features that the old capture pipeline's tables were created beside.
    /// Migration 442 drops the capture tables and creates them again with the tree schema. Nothing is carried over: captures stored
    /// before it are deleted on upgrade. The id counter is kept, so a capture id that a task stored as evidence never names a new capture.
    static let migrations: [Database.Migration] = [
        .init(440, "capture: replace the per-app pipeline's tables with windows, captures and a text index", sql: """
            DROP TABLE IF EXISTS capture_items;
            DROP TABLE IF EXISTS capture_threads;
            DROP TABLE IF EXISTS capture_messages;
            DROP TABLE IF EXISTS capture_send_log;
            DROP TABLE IF EXISTS capture_originals;
            DROP TABLE IF EXISTS capture_ignored;
            DROP TABLE IF EXISTS capture_fts;
            DROP TABLE IF EXISTS capture;
            DROP TABLE IF EXISTS capture_window;
            CREATE TABLE capture_window(id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT NOT NULL UNIQUE, app TEXT NOT NULL, app_name TEXT NOT NULL,
                                        title TEXT NOT NULL, url TEXT, last_lines TEXT NOT NULL DEFAULT '', first_seen REAL NOT NULL,
                                        last_seen REAL NOT NULL);
            CREATE TABLE capture(id INTEGER PRIMARY KEY AUTOINCREMENT, window_id INTEGER NOT NULL, at REAL NOT NULL, app TEXT NOT NULL,
                                 app_name TEXT NOT NULL, title TEXT NOT NULL, url TEXT, trigger TEXT NOT NULL, text TEXT NOT NULL);
            CREATE INDEX capture_by_time ON capture(at);
            CREATE INDEX capture_by_window ON capture(window_id, id);
            CREATE VIRTUAL TABLE capture_fts USING fts5(text, title, app_name, url, content='capture', content_rowid='id');
            CREATE TRIGGER capture_fts_insert AFTER INSERT ON capture BEGIN
                INSERT INTO capture_fts(rowid, text, title, app_name, url) VALUES(new.id, new.text, new.title, new.app_name, new.url);
            END;
            CREATE TRIGGER capture_fts_delete AFTER DELETE ON capture BEGIN
                INSERT INTO capture_fts(capture_fts, rowid, text, title, app_name, url) VALUES('delete', old.id, old.text, old.title, old.app_name, old.url);
            END;
            """),
        .init(442, "capture: keep the accessibility tree, the blocks seen in it and drafts; existing captures are deleted", sql: """
            CREATE TEMP TABLE capture_old_sequence AS SELECT seq FROM sqlite_sequence WHERE name = 'capture';
            DROP TRIGGER IF EXISTS capture_fts_insert;
            DROP TRIGGER IF EXISTS capture_fts_delete;
            DROP TABLE IF EXISTS capture_fts;
            DROP TABLE IF EXISTS capture;
            DROP TABLE IF EXISTS capture_window;
            CREATE TABLE capture_window(id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT NOT NULL UNIQUE, app TEXT NOT NULL, app_name TEXT NOT NULL,
                                        title TEXT NOT NULL, url TEXT, last_lines TEXT NOT NULL DEFAULT '', last_content TEXT, first_seen REAL NOT NULL,
                                        last_seen REAL NOT NULL);
            CREATE TABLE capture(id INTEGER PRIMARY KEY AUTOINCREMENT, window_id INTEGER NOT NULL, at REAL NOT NULL, app TEXT NOT NULL,
                                 app_name TEXT NOT NULL, title TEXT NOT NULL, url TEXT, trigger TEXT NOT NULL, text TEXT NOT NULL, root TEXT);
            CREATE INDEX capture_by_time ON capture(at);
            CREATE INDEX capture_by_window ON capture(window_id, id);
            CREATE VIRTUAL TABLE capture_fts USING fts5(text, title, app_name, url, content='capture', content_rowid='id');
            CREATE TRIGGER capture_fts_insert AFTER INSERT ON capture BEGIN
                INSERT INTO capture_fts(rowid, text, title, app_name, url) VALUES(new.id, new.text, new.title, new.app_name, new.url);
            END;
            CREATE TRIGGER capture_fts_delete AFTER DELETE ON capture BEGIN
                INSERT INTO capture_fts(capture_fts, rowid, text, title, app_name, url) VALUES('delete', old.id, old.text, old.title, old.app_name, old.url);
            END;
            CREATE TABLE capture_node(hash TEXT PRIMARY KEY, data TEXT NOT NULL) WITHOUT ROWID;
            CREATE TABLE capture_block_seen(id INTEGER PRIMARY KEY AUTOINCREMENT, window_id INTEGER NOT NULL, identity TEXT NOT NULL,
                                            text_hash TEXT NOT NULL, kind TEXT NOT NULL, seen REAL NOT NULL, label TEXT NOT NULL,
                                            "when" TEXT, container TEXT, capture_id INTEGER, ref TEXT);
            CREATE INDEX capture_block_by_identity ON capture_block_seen(window_id, identity);
            CREATE INDEX capture_block_by_time ON capture_block_seen(seen);
            CREATE INDEX capture_block_by_capture ON capture_block_seen(capture_id);
            CREATE TABLE capture_draft(window_id INTEGER NOT NULL, key TEXT NOT NULL, field TEXT, text TEXT NOT NULL, status TEXT NOT NULL,
                                       first_seen REAL NOT NULL, updated REAL NOT NULL, cleared REAL, PRIMARY KEY(window_id, key)) WITHOUT ROWID;
            INSERT INTO sqlite_sequence(name, seq) SELECT 'capture', seq FROM capture_old_sequence;
            DROP TABLE capture_old_sequence;
            """),
    ]

    /// What a read of the stored text may return per call. A tool result this large is already more than an agent should read at once.
    static let maxListedCaptures = 60
    static let maxListedCharacters = 60_000

    let database: Database
    var filter: CapturePrivacyFilter
    /// How many tree nodes the last capture wrote. The rest were already stored. Tests read it.
    var lastNodeWrites = 0

    init(database: Database, filter: CapturePrivacyFilter = PassthroughPrivacyFilter()) {
        self.database = database
        self.filter = filter
    }

    // MARK: Write

    enum IngestResult: Equatable {
        /// A capture was stored.
        case stored(id: Int64)
        /// Nothing in the window was new.
        case unchanged
        /// There was no text.
        case empty
    }

    /// The key of a window: the app and, for a page, its address without secrets and fragment, otherwise the window title.
    static func windowKey(app: String, title: String, url: String?) -> String {
        if let url, !url.isEmpty {
            var page = CaptureURL.normalize(url)
            if let hash = page.firstIndex(of: "#") { page = String(page[..<hash]) }
            return app + "\u{1F}" + page
        }
        return app + "\u{1F}" + title
    }

    /// A short digest of a line. The window row keeps these instead of the text, so only new lines are ever stored.
    static func digest(_ line: String) -> String {
        SHA256.hash(data: Data(line.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Stores what is new in a window since its last capture. The text is redacted, then passed through the privacy filter, then compared
    /// with the digests of the window's last lines. The window keeps the digests of the new text, so a line that goes away and comes
    /// back counts as new again.
    ///
    /// A window without an address is keyed by its title. When the title changes between captures (a counter, a clock, the text being
    /// typed), the app's window seen in the last 30 s that shares at least half of these lines is reused instead of starting a new one.
    @discardableResult
    func ingest(app: CaptureApp, title: String?, url: String?, trigger: CaptureTrigger, lines: [String], inputLines: [String] = [],
                tree: AXNode? = nil, now: Date = Date()) throws -> IngestResult {
        let windowTitle = CaptureRedactor.redact(title ?? "").text
        let pageURL = url.map(CaptureURL.redact)
        func clean(_ text: String) -> String { filter.filterOnWrite(CaptureRedactor.redact(text).text, app: app.bundleId) }
        // What a person typed is a draft, not page text.
        let typed = Set(inputLines.map(clean))
        let current = clean(lines.joined(separator: "\n")).split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty && !typed.contains($0) }
        guard !current.isEmpty || tree != nil else { return .empty }
        let at = now.timeIntervalSince1970
        var key = Self.windowKey(app: app.bundleId, title: windowTitle, url: pageURL)
        let digests = current.map(Self.digest)
        let prepared = tree.map { CaptureTree.prepare($0, clean: clean, cleanURL: CaptureURL.redact) }
        let blocks = prepared.map { CaptureBlocks.extract($0.tree) } ?? []
        return try database.write { db in
            if pageURL == nil, try db.rows("SELECT 1 FROM capture_window WHERE key = ?", [key]).isEmpty {
                let recent = try db.rows("SELECT key, last_lines FROM capture_window WHERE app = ? AND url IS NULL AND last_seen >= ? ORDER BY last_seen DESC",
                                         [app.bundleId, at - 30])
                let mine = Set(digests)
                for row in recent {
                    let theirs = Set((row[1] as? String ?? "").split(separator: "\n").map(String.init))
                    if !theirs.isEmpty, mine.intersection(theirs).count * 2 >= mine.count, let existing = row[0] as? String { key = existing; break }
                }
            }
            try db.execute("""
                INSERT INTO capture_window(key, app, app_name, title, url, first_seen, last_seen) VALUES(?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET app_name = excluded.app_name, title = excluded.title,
                                               url = COALESCE(excluded.url, capture_window.url), last_seen = excluded.last_seen
                """, [key, app.bundleId, app.name, windowTitle, pageURL, at, at])
            let row = try db.rows("SELECT id, last_lines, last_content FROM capture_window WHERE key = ?", [key])[0]
            let windowId = row[0] as! Int64
            let previous = Set((row[1] as? String ?? "").split(separator: "\n").map(String.init))
            let context = TreeContext(windowId: windowId, at: at, trigger: trigger, app: app, title: windowTitle, url: pageURL)
            if let prepared {
                try updateDrafts(db, windowId: windowId, at: at, fields: Self.inputs(in: prepared.tree))
                // The same tree apart from typed text: only the draft changed.
                if row[2] as? String == prepared.contentRoot {
                    try settleDrafts(db, windowId: windowId, at: at)
                    return .unchanged
                }
                try db.execute("UPDATE capture_window SET last_content = ? WHERE id = ?", [prepared.contentRoot, windowId])
            }
            if !current.isEmpty { try db.execute("UPDATE capture_window SET last_lines = ? WHERE id = ?", [digests.joined(separator: "\n"), windowId]) }
            if let prepared, !blocks.isEmpty { return try ingestBlocks(db, context, prepared, blocks) }
            return try ingestPage(db, context, prepared, current, previous: previous)
        }
    }

    // MARK: Read

    static let columns = "id, at, app, app_name, title, url, trigger, text, root"

    func capture(_ row: [Database.Value]) -> StoredCapture {
        let app = row[2] as? String ?? ""
        return StoredCapture(id: row[0] as? Int64 ?? 0, at: Date(timeIntervalSince1970: row[1] as? Double ?? 0), app: app,
                             appName: row[3] as? String ?? app, window: row[4] as? String ?? "", url: row[5] as? String,
                             trigger: row[6] as? String ?? "", text: filter.filterOnRead(row[7] as? String ?? "", app: app), root: row[8] as? String)
    }

    func capture(id: Int64) -> StoredCapture? {
        (try? database.read { try $0.rows("SELECT \(Self.columns) FROM capture WHERE id = ?", [id]) })?.first.map(capture)
    }

    /// The newest captures, newest first.
    func recent(limit: Int = 50) -> [StoredCapture] {
        let rows = (try? database.read { try $0.rows("SELECT \(Self.columns) FROM capture ORDER BY id DESC LIMIT ?", [limit]) }) ?? []
        return rows.map(capture)
    }

    /// Captures in a time range, oldest first, optionally of one app (bundle id or name) or one window (a part of its title or address).
    func list(app: String? = nil, window: String? = nil, since: Date? = nil, until: Date? = nil, limit: Int = maxListedCaptures) -> [StoredCapture] {
        var clauses: [String] = [], args: [Database.Value] = []
        if let app, !app.isEmpty { clauses.append("(app = ? COLLATE NOCASE OR app_name = ? COLLATE NOCASE)"); args += [app, app] }
        if let window, !window.isEmpty {
            clauses.append("(title LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\')")
            let pattern = "%" + Self.likeEscaped(window) + "%"
            args += [pattern, pattern]
        }
        if let since { clauses.append("at >= ?"); args.append(since.timeIntervalSince1970) }
        if let until { clauses.append("at < ?"); args.append(until.timeIntervalSince1970) }
        let filter = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        // One more than the cap, so a caller can tell that the range held more.
        args.append(max(1, min(limit, Self.maxListedCaptures + 1)))
        let rows = (try? database.read { try $0.rows("SELECT \(Self.columns) FROM capture \(filter) ORDER BY at DESC, id DESC LIMIT ?", args) }) ?? []
        // The newest are kept when the range holds more than the cap, and handed back oldest first.
        return rows.reversed().map(capture)
    }

    static func likeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    /// Turns what a person typed into an FTS5 query: every word must appear, and punctuation in a word cannot be read as query syntax.
    static func matchQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map { $0.replacingOccurrences(of: "\"", with: "") }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"" }.joined(separator: " ")
    }

    /// Captures whose text, window title, app name or page address has every word of `query`, best match first.
    func search(_ query: String, app: String? = nil, since: Date? = nil, until: Date? = nil, limit: Int = 20) -> [CaptureHit] {
        guard let match = Self.matchQuery(query) else { return [] }
        var clauses = ["capture_fts MATCH ?"], args: [Database.Value] = [match]
        if let app, !app.isEmpty { clauses.append("(c.app = ? COLLATE NOCASE OR c.app_name = ? COLLATE NOCASE)"); args += [app, app] }
        if let since { clauses.append("c.at >= ?"); args.append(since.timeIntervalSince1970) }
        if let until { clauses.append("c.at < ?"); args.append(until.timeIntervalSince1970) }
        args.append(max(1, min(limit, 100)))
        let sql = """
            SELECT c.id, c.at, c.app, c.app_name, c.title, c.url, snippet(capture_fts, 0, '[', ']', '…', 24)
            FROM capture_fts JOIN capture c ON c.id = capture_fts.rowid
            WHERE \(clauses.joined(separator: " AND ")) ORDER BY rank, c.id DESC LIMIT ?
            """
        let rows = (try? database.read { try $0.rows(sql, args) }) ?? []
        return rows.map { row in
            let app = row[2] as? String ?? ""
            return CaptureHit(id: row[0] as? Int64 ?? 0, at: Date(timeIntervalSince1970: row[1] as? Double ?? 0), app: app,
                              appName: row[3] as? String ?? app, window: row[4] as? String ?? "", url: row[5] as? String,
                              snippet: filter.filterOnRead(row[6] as? String ?? "", app: app))
        }
    }

    // MARK: Housekeeping

    var captureCount: Int {
        ((try? database.read { try $0.rows("SELECT COUNT(*) FROM capture") })?.first?.first as? Int64).map(Int.init) ?? 0
    }

    /// Apps that have captures, most captures first.
    func seenApps() -> [(bundleId: String, name: String, captures: Int)] {
        let rows = (try? database.read { try $0.rows("SELECT app, MAX(app_name), COUNT(*) FROM capture GROUP BY app ORDER BY COUNT(*) DESC") }) ?? []
        return rows.compactMap { row in
            guard let id = row[0] as? String else { return nil }
            return (id, row[1] as? String ?? id, Int(row[2] as? Int64 ?? 0))
        }
    }

    /// Deletes captures older than `days`, what was recorded about their blocks and drafts, the tree nodes no remaining capture
    /// reaches, and windows that have none left and were not seen for as long.
    @discardableResult
    func prune(olderThanDays days: Int, now: Date = Date()) -> Int {
        let cutoff = now.timeIntervalSince1970 - Double(days) * 86_400
        return (try? database.write { db in
            let removed = try db.rows("SELECT COUNT(*) FROM capture WHERE at < ?", [cutoff]).first?.first as? Int64 ?? 0
            try db.execute("DELETE FROM capture WHERE at < ?", [cutoff])
            try db.execute("DELETE FROM capture_block_seen WHERE seen < ?", [cutoff])
            try db.execute("DELETE FROM capture_draft WHERE updated < ?", [cutoff])
            try db.execute("DELETE FROM capture_window WHERE last_seen < ? AND id NOT IN (SELECT window_id FROM capture)", [cutoff])
            try db.execute("DELETE FROM capture_draft WHERE window_id NOT IN (SELECT id FROM capture_window)")
            if removed > 0 { try sweepNodes(db) }
            return Int(removed)
        }).map { removed in
            // The deleted text can still sit in the write-ahead log until it is folded into the file.
            database.checkpoint()
            return removed
        } ?? 0
    }

    /// Deletes every capture and window.
    func clear() {
        try? database.write { db in
            try db.execute("DELETE FROM capture")
            try db.execute("DELETE FROM capture_window")
            try db.execute("DELETE FROM capture_node")
            try db.execute("DELETE FROM capture_block_seen")
            try db.execute("DELETE FROM capture_draft")
            try db.execute("INSERT INTO capture_fts(capture_fts) VALUES('rebuild')")
        }
        database.checkpoint()
    }

    /// Makes the database file and its write-ahead files readable by the owner only.
    static func restrictPermissions(of database: Database) {
        guard let path = database.path else { return }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path + suffix)
        }
    }
}
