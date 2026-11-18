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
/// Text is redacted (`CaptureRedactor`) before it is stored. A window keeps the lines of its last capture, and a new capture stores
/// only the lines that were not in it, with a few lines of context. Tables are prefixed `capture_`. Captured text never goes into logs.
final class CaptureStore: @unchecked Sendable {
    /// Versions start at 440, after every migration of the other features that the old capture pipeline's tables were created beside.
    /// The old capture tables are dropped without being read: nothing is carried over.
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
                                        title TEXT NOT NULL, url TEXT, last_text TEXT NOT NULL DEFAULT '', first_seen REAL NOT NULL,
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
    ]

    /// What a read of the stored text may return per call. A tool result this large is already more than an agent should read at once.
    static let maxListedCaptures = 60
    static let maxListedCharacters = 60_000

    let database: Database
    var filter: CapturePrivacyFilter

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

    /// Stores what is new in a window since its last capture. The text is redacted, then passed through the privacy filter, then compared
    /// with the window's last lines. The window keeps the whole of the new text as its last lines, so a line that goes away and comes
    /// back counts as new again.
    @discardableResult
    func ingest(app: CaptureApp, title: String?, url: String?, trigger: CaptureTrigger, lines: [String], now: Date = Date()) throws -> IngestResult {
        let windowTitle = CaptureRedactor.redact(title ?? "").text
        let pageURL = url.map(CaptureURL.redact)
        let redacted = CaptureRedactor.redact(lines.joined(separator: "\n")).text
        let filtered = filter.filterOnWrite(redacted, app: app.bundleId)
        let current = filtered.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard !current.isEmpty else { return .empty }
        let at = now.timeIntervalSince1970
        let key = Self.windowKey(app: app.bundleId, title: windowTitle, url: pageURL)
        return try database.write { db in
            try db.execute("""
                INSERT INTO capture_window(key, app, app_name, title, url, first_seen, last_seen) VALUES(?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET app_name = excluded.app_name, title = excluded.title,
                                               url = COALESCE(excluded.url, capture_window.url), last_seen = excluded.last_seen
                """, [key, app.bundleId, app.name, windowTitle, pageURL, at, at])
            let row = try db.rows("SELECT id, last_text FROM capture_window WHERE key = ?", [key])[0]
            let windowId = row[0] as! Int64
            let previous = (row[1] as? String ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            try db.execute("UPDATE capture_window SET last_text = ? WHERE id = ?", [current.joined(separator: "\n"), windowId])
            guard let text = CaptureDiff.fresh(previous: previous, current: current) else { return .unchanged }
            try db.execute("INSERT INTO capture(window_id, at, app, app_name, title, url, trigger, text) VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
                           [windowId, at, app.bundleId, app.name, windowTitle, pageURL, trigger.rawValue, text])
            return .stored(id: (try db.rows("SELECT last_insert_rowid()")[0][0] as? Int64) ?? 0)
        }
    }

    // MARK: Read

    private static let columns = "id, at, app, app_name, title, url, trigger, text"

    private func capture(_ row: [Database.Value]) -> StoredCapture {
        let app = row[2] as? String ?? ""
        return StoredCapture(id: row[0] as? Int64 ?? 0, at: Date(timeIntervalSince1970: row[1] as? Double ?? 0), app: app,
                             appName: row[3] as? String ?? app, window: row[4] as? String ?? "", url: row[5] as? String,
                             trigger: row[6] as? String ?? "", text: filter.filterOnRead(row[7] as? String ?? "", app: app))
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
        let rows = (try? database.read { try $0.rows("SELECT \(Self.columns) FROM capture \(filter) ORDER BY at, id LIMIT ?", args) }) ?? []
        return rows.map(capture)
    }

    private static func likeEscaped(_ text: String) -> String {
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

    /// Deletes captures older than `days`, and windows that have none left and were not seen for as long.
    @discardableResult
    func prune(olderThanDays days: Int, now: Date = Date()) -> Int {
        let cutoff = now.timeIntervalSince1970 - Double(days) * 86_400
        return (try? database.write { db in
            let removed = try db.rows("SELECT COUNT(*) FROM capture WHERE at < ?", [cutoff]).first?.first as? Int64 ?? 0
            try db.execute("DELETE FROM capture WHERE at < ?", [cutoff])
            try db.execute("DELETE FROM capture_window WHERE last_seen < ? AND id NOT IN (SELECT window_id FROM capture)", [cutoff])
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
