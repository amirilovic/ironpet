import Foundation

/// Captured items in ironpet's shared database. Change detection lives here: a thread (app plus thread key) keeps a hash of its
/// last content, and a new item is stored only when that content changed. Conversations keep message-level state, so an item holds
/// just the messages the thread had not seen. Documents and pages keep the last text, so an item holds the lines that are new.
///
/// Text is redacted before it is stored (`CaptureRedactor`): messages, document lines and the thread's change-detection text all hold
/// `[redacted:<kind>]` in place of a secret. The unredacted text of an item that had a secret is kept in `capture_originals` for
/// `originalRetention` (24 hours), so the user can look at what was redacted, and is then overwritten and deleted. It is never sent.
///
/// Tables are prefixed `capture_`. Captured text never goes into logs.
final class CaptureStore: @unchecked Sendable {
    /// Versions start at 300, after automations (1 to 5), usage (100) and tasks (200). The app passes these with the other features' migrations.
    static let migrations: [Database.Migration] = [
        .init(300, "capture: threads, messages, items", sql: """
            CREATE TABLE capture_threads(id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT NOT NULL, app TEXT NOT NULL, app_name TEXT NOT NULL,
                                         title TEXT NOT NULL, kind TEXT NOT NULL, url TEXT, first_seen REAL NOT NULL, last_seen REAL NOT NULL,
                                         last_hash TEXT NOT NULL DEFAULT '', last_text TEXT NOT NULL DEFAULT '',
                                         UNIQUE(app, key));
            CREATE TABLE capture_messages(thread_id INTEGER NOT NULL, fingerprint TEXT NOT NULL, author TEXT, body TEXT NOT NULL, sent_at TEXT,
                                          first_seen REAL NOT NULL, PRIMARY KEY(thread_id, fingerprint)) WITHOUT ROWID;
            CREATE TABLE capture_items(id INTEGER PRIMARY KEY AUTOINCREMENT, thread_id INTEGER NOT NULL, at REAL NOT NULL, hash TEXT NOT NULL,
                                       version INTEGER NOT NULL, new_messages INTEGER NOT NULL, body TEXT NOT NULL,
                                       state TEXT NOT NULL DEFAULT 'new', reason TEXT, secret REAL, related TEXT, calendar REAL, task REAL,
                                       sent_at REAL);
            CREATE INDEX capture_items_by_state ON capture_items(state, id);
            CREATE INDEX capture_items_by_thread ON capture_items(thread_id, id);
            CREATE INDEX capture_items_by_time ON capture_items(at);
            """),
        .init(301, "capture: ignored proposals, send log", sql: """
            CREATE TABLE capture_ignored(fingerprint TEXT PRIMARY KEY, kind TEXT NOT NULL, at REAL NOT NULL) WITHOUT ROWID;
            CREATE TABLE capture_send_log(id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, harness TEXT NOT NULL, model TEXT NOT NULL,
                                          items TEXT NOT NULL, bytes INTEGER NOT NULL, outcome TEXT NOT NULL);
            CREATE INDEX capture_send_log_by_time ON capture_send_log(at);
            """),
        .init(302, "capture: redaction and originals") { db in
            try db.script("""
                ALTER TABLE capture_items ADD COLUMN redactions TEXT;
                CREATE TABLE capture_originals(item_id INTEGER PRIMARY KEY, body TEXT NOT NULL, at REAL NOT NULL);
                """)
            try redactExisting(db)
        },
    ]

    /// Text stored by earlier builds is plain. Redact it once, keeping the old item text as an original for the usual 24 hours.
    private static func redactExisting(_ db: Database.Connection) throws {
        let now = Date().timeIntervalSince1970
        // In pages, so a large history is not held in memory at once.
        var lastId: Int64 = 0
        while true {
            let page = try db.rows("SELECT id, body FROM capture_items WHERE id > ? AND body != '' ORDER BY id LIMIT 200", [lastId])
            if page.isEmpty { break }
            for row in page {
                guard let id = row[0] as? Int64 else { continue }
                lastId = id
                guard let body = row[1] as? String else { continue }
                let (redacted, report) = CaptureRedactor.redact(body)
                guard !report.isEmpty else { continue }
                try db.execute("UPDATE capture_items SET body = ?, redactions = ? WHERE id = ?", [redacted, report.json, id])
                try db.execute("INSERT OR REPLACE INTO capture_originals(item_id, body, at) VALUES(?, ?, ?)", [id, body, now])
            }
        }
        for thread in try db.rows("SELECT id FROM capture_threads") {
            guard let threadId = thread[0] as? Int64 else { continue }
            for row in try db.rows("SELECT fingerprint, author, body, sent_at FROM capture_messages WHERE thread_id = ?", [threadId]) {
                guard let fingerprint = row[0] as? String, let body = row[2] as? String else { continue }
                let (redacted, report) = CaptureRedactor.redact(body)
                guard !report.isEmpty else { continue }
                // The fingerprint is of the redacted text, as it is for new messages, so a message read again is still the same message.
                // Two messages that differed only in the secret are now the same text, and are numbered as repeats.
                let base = CaptureMessage(author: row[1] as? String, text: redacted, sentAt: row[3] as? String).id
                var n = 0
                while !(try db.rows("SELECT 1 FROM capture_messages WHERE thread_id = ? AND fingerprint = ?", [threadId, "\(base)#\(n)"])).isEmpty { n += 1 }
                try db.execute("UPDATE capture_messages SET body = ?, fingerprint = ? WHERE thread_id = ? AND fingerprint = ?", [redacted, "\(base)#\(n)", threadId, fingerprint])
            }
        }
        for row in try db.rows("SELECT id, title, last_text FROM capture_threads") {
            guard let id = row[0] as? Int64 else { continue }
            let title = CaptureRedactor.redact(row[1] as? String ?? "").text, text = CaptureRedactor.redact(row[2] as? String ?? "").text
            try db.execute("UPDATE capture_threads SET title = ?, last_text = ? WHERE id = ?", [title, text, id])
        }
    }

    struct IngestResult: Equatable {
        var threadId: Int64
        /// The new item, when the content changed in a way that added something to read.
        var itemId: Int64?
        var newMessages: Int
        var changed: Bool
    }

    /// A stored item as the filter and the larger model see it.
    struct Item: Equatable {
        var id: Int64
        var threadId: Int64
        var threadKey: String
        var threadTitle: String
        var app: String
        var appName: String
        var kind: String
        var at: Date
        var version: Int
        var body: String
        var state: String
        /// What the redactor replaced in this item.
        var redactions = CaptureRedactor.Report()
    }

    /// How long the unredacted text of an item is kept.
    static let originalRetention: TimeInterval = 24 * 3600

    static let maxBodyBytes = 24_000

    let database: Database

    init(database: Database) { self.database = database }

    /// Lines of text with the case and spacing differences that are not changes removed.
    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func capped(_ text: String) -> String {
        text.utf8.count <= maxBodyBytes ? text : String(decoding: Array(text.utf8.prefix(maxBodyBytes)), as: UTF8.self)
    }

    // MARK: Ingest

    /// How many times each kind of redaction appears in text that has been through the redactor.
    static func report(of redacted: String) -> CaptureRedactor.Report {
        var report = CaptureRedactor.Report()
        let marker = try! NSRegularExpression(pattern: #"\[redacted:([a-z-]+)\]"#)
        for match in marker.matches(in: redacted, range: NSRange(redacted.startIndex..., in: redacted)) {
            if let range = Range(match.range(at: 1), in: redacted) { report.add(String(redacted[range])) }
        }
        return report
    }

    /// Stores `item` when its content changed since the thread's last capture. The same content twice stores nothing the second time.
    /// The text is redacted first: what is stored, hashed and fingerprinted is the redacted text, and the original of an item that had a
    /// secret goes to `capture_originals`.
    func ingest(_ item: CaptureItem, now: Date = Date()) throws -> IngestResult {
        let at = now.timeIntervalSince1970
        let title = CaptureRedactor.redact(item.threadTitle).text
        return try database.write { db in
            try db.execute("""
                INSERT INTO capture_threads(key, app, app_name, title, kind, url, first_seen, last_seen) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(app, key) DO UPDATE SET app_name = excluded.app_name, title = excluded.title, kind = excluded.kind,
                                               url = COALESCE(excluded.url, capture_threads.url), last_seen = excluded.last_seen
                """, [item.threadKey, item.app.bundleId, item.app.name, title, item.content.kindName, item.url, at, at])
            let thread = try db.rows("SELECT id, last_hash, last_text FROM capture_threads WHERE app = ? AND key = ?", [item.app.bundleId, item.threadKey])[0]
            let threadId = thread[0] as! Int64
            let lastHash = thread[1] as? String ?? ""
            let lastText = thread[2] as? String ?? ""

            // Drafts change on every keystroke and are the user's own unsent text, so they are not part of what a thread holds.
            var rawMessages: [CaptureMessage] = []
            var stable: CaptureContent
            switch item.content {
            case .conversation(let contentTitle, let isGroup, let messages):
                rawMessages = messages.filter { !$0.draft }
                let redacted = rawMessages.map { message -> CaptureMessage in
                    var copy = message
                    copy.text = CaptureRedactor.redact(message.text).text
                    return copy
                }
                stable = .conversation(title: contentTitle, isGroup: isGroup, messages: redacted)
            case .document(let contentTitle, let text):
                stable = .document(title: contentTitle, text: CaptureRedactor.redact(text).text)
            case .page(let contentTitle, let text):
                stable = .page(title: contentTitle, text: CaptureRedactor.redact(text).text)
            }
            let hash = CaptureHash.hex(CaptureJSON.string(stable) ?? "")
            if hash == lastHash { return IngestResult(threadId: threadId, itemId: nil, newMessages: 0, changed: false) }

            var body = ""
            var original = ""
            var newMessages = 0
            var newText = lastText
            switch stable {
            case .conversation(_, _, let messages):
                var seen: [String: Int] = [:]
                var fresh: [String] = []
                var freshOriginal: [String] = []
                for (index, message) in messages.enumerated() {
                    let base = message.id
                    let n = seen[base, default: 0]
                    seen[base] = n + 1
                    let fingerprint = "\(base)#\(n)"
                    if try !db.rows("SELECT 1 FROM capture_messages WHERE thread_id = ? AND fingerprint = ?", [threadId, fingerprint]).isEmpty { continue }
                    try db.execute("INSERT INTO capture_messages(thread_id, fingerprint, author, body, sent_at, first_seen) VALUES(?, ?, ?, ?, ?, ?)",
                                   [threadId, fingerprint, message.author, message.text, message.sentAt, at])
                    fresh.append(message.author.map { "\($0): \(message.text)" } ?? message.text)
                    let raw = rawMessages[index]
                    freshOriginal.append(raw.author.map { "\($0): \(raw.text)" } ?? raw.text)
                }
                newMessages = fresh.count
                body = fresh.joined(separator: "\n")
                original = freshOriginal.joined(separator: "\n")
            case .document(_, let text), .page(_, let text):
                let known = Set(Self.lines(lastText))
                let redactedLines = Self.lines(text)
                let rawText: String
                if case .document(_, let t) = item.content { rawText = t } else if case .page(_, let t) = item.content { rawText = t } else { rawText = text }
                let rawLines = Self.lines(rawText)
                let isAdded = { (line: String) in lastText.isEmpty || !known.contains(line) }
                body = redactedLines.filter(isAdded).joined(separator: "\n")
                // Redaction keeps lines apart unless a key block spans several, in which case the original is the whole text.
                original = rawLines.count == redactedLines.count
                    ? zip(redactedLines, rawLines).filter { isAdded($0.0) }.map(\.1).joined(separator: "\n")
                    : rawLines.joined(separator: "\n")
                newText = Self.capped(text)
            }
            try db.execute("UPDATE capture_threads SET last_hash = ?, last_text = ? WHERE id = ?", [hash, newText, threadId])
            guard !body.isEmpty else { return IngestResult(threadId: threadId, itemId: nil, newMessages: 0, changed: true) }
            let version = ((try db.rows("SELECT MAX(version) FROM capture_items WHERE thread_id = ?", [threadId]).first?.first as? Int64) ?? 0) + 1
            let report = Self.report(of: body)
            try db.execute("INSERT INTO capture_items(thread_id, at, hash, version, new_messages, body, redactions) VALUES(?, ?, ?, ?, ?, ?, ?)",
                           [threadId, at, hash, version, newMessages, Self.capped(body), report.json])
            let itemId = (try db.rows("SELECT last_insert_rowid()")[0][0]) as! Int64
            if !report.isEmpty {
                try db.execute("INSERT INTO capture_originals(item_id, body, at) VALUES(?, ?, ?)", [itemId, Self.capped(original), at])
            }
            return IngestResult(threadId: threadId, itemId: itemId, newMessages: newMessages, changed: true)
        }
    }

    // MARK: Originals

    /// The unredacted text of an item and when it will be deleted. Nil when it had none, or the 24 hours are over.
    func original(of itemId: Int64, now: Date = Date()) -> (text: String, expires: Date)? {
        let cutoff = now.addingTimeInterval(-Self.originalRetention).timeIntervalSince1970
        guard let row = ((try? database.read { try $0.rows("SELECT body, at FROM capture_originals WHERE item_id = ? AND at > ?", [itemId, cutoff]) }) ?? []).first,
              let text = row[0] as? String, let at = row[1] as? Double else { return nil }
        return (text, Date(timeIntervalSince1970: at + Self.originalRetention))
    }

    /// Keeps `text` as the item's original when it has none yet, so Reveal still works for an item whose stored text is about to be dropped.
    func keepOriginalIfMissing(_ itemId: Int64, text: String, now: Date = Date()) {
        try? database.write { db in
            guard try db.rows("SELECT 1 FROM capture_originals WHERE item_id = ?", [itemId]).isEmpty else { return }
            try db.execute("INSERT INTO capture_originals(item_id, body, at) VALUES(?, ?, ?)", [itemId, text, now.timeIntervalSince1970])
        }
    }

    /// Deletes originals older than 24 hours. The text is overwritten before the row goes. SQLite can keep freed pages until they are reused.
    @discardableResult
    func purgeOriginals(now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Self.originalRetention).timeIntervalSince1970
        return (try? database.write { db in
            let count = (try db.rows("SELECT COUNT(*) FROM capture_originals WHERE at <= ?", [cutoff]).first?.first as? Int64) ?? 0
            try db.execute("UPDATE capture_originals SET body = zeroblob(length(CAST(body AS BLOB))) WHERE at <= ?", [cutoff])
            try db.execute("DELETE FROM capture_originals WHERE at <= ?", [cutoff])
            return Int(count)
        }).map { count in
            // The write-ahead log may still hold the deleted text.
            if count > 0 { database.checkpoint() }
            return count
        } ?? 0
    }

    // MARK: Reads

    private static let itemColumns = """
        SELECT i.id, i.thread_id, t.key, t.title, t.app, t.app_name, t.kind, i.at, i.version, i.body, i.state, i.redactions
        FROM capture_items i JOIN capture_threads t ON t.id = i.thread_id
        """

    private static func item(_ row: [Database.Value]) -> Item {
        Item(id: row[0] as! Int64, threadId: row[1] as! Int64, threadKey: row[2] as! String, threadTitle: row[3] as! String,
             app: row[4] as! String, appName: row[5] as! String, kind: row[6] as! String, at: Date(timeIntervalSince1970: row[7] as! Double),
             version: Int(row[8] as! Int64), body: row[9] as! String, state: row[10] as! String,
             redactions: CaptureRedactor.Report(json: row[11] as? String) ?? CaptureRedactor.Report())
    }

    func items(inState state: String, limit: Int = 200) -> [Item] {
        ((try? database.read { try $0.rows(Self.itemColumns + " WHERE i.state = ? ORDER BY i.id LIMIT ?", [state, limit]) }) ?? []).map(Self.item)
    }

    func item(id: Int64) -> Item? {
        ((try? database.read { try $0.rows(Self.itemColumns + " WHERE i.id = ?", [id]) }) ?? []).first.map(Self.item)
    }

    func items(ids: [Int64]) -> [Item] { ids.compactMap(item(id:)) }

    func recent(limit: Int = 20) -> [Item] {
        ((try? database.read { try $0.rows(Self.itemColumns + " ORDER BY i.id DESC LIMIT ?", [limit]) }) ?? []).map(Self.item)
    }

    func count(inState state: String) -> Int {
        Int(((try? database.read { try $0.rows("SELECT COUNT(*) FROM capture_items WHERE state = ?", [state]) })?.first?.first as? Int64) ?? 0)
    }

    var itemCount: Int { Int(((try? database.read { try $0.rows("SELECT COUNT(*) FROM capture_items") })?.first?.first as? Int64) ?? 0) }

    /// Moves an item to a state and records what the filter measured.
    func setState(_ id: Int64, _ state: String, reason: String? = nil, secret: Double? = nil, related: [String]? = nil,
                  calendar: Double? = nil, task: Double? = nil) {
        try? database.write { db in
            try db.execute("""
                UPDATE capture_items SET state = ?, reason = COALESCE(?, reason), secret = COALESCE(?, secret), related = COALESCE(?, related),
                                         calendar = COALESCE(?, calendar), task = COALESCE(?, task) WHERE id = ?
                """, [state, reason, secret, related.flatMap(CaptureJSON.string), calendar, task, id])
        }
    }

    func markSent(_ ids: [Int64], at: Date) {
        try? database.write { db in
            for id in ids { try db.execute("UPDATE capture_items SET state = 'sent', sent_at = ? WHERE id = ?", [at.timeIntervalSince1970, id]) }
        }
    }

    /// Drops the stored text of an item the filter still flagged as a secret after redaction. The row stays so the decision is visible, and
    /// the text stays as the item's original for 24 hours, so the user can see what was flagged.
    func dropText(_ id: Int64) {
        if let item = item(id: id) { keepOriginalIfMissing(id, text: item.body) }
        try? database.write { db in
            try db.execute("UPDATE capture_items SET body = '' WHERE id = ?", [id])
            // The thread keeps the same text for change detection, so clear it there too.
            let thread = "(SELECT thread_id FROM capture_items WHERE id = ?)"
            try db.execute("UPDATE capture_messages SET body = '' WHERE thread_id = \(thread)", [id])
            try db.execute("UPDATE capture_threads SET last_text = '' WHERE id = \(thread)", [id])
        }
    }

    /// Apps that have been captured, with the number of items, most items first.
    func seenApps() -> [(bundleId: String, name: String, items: Int)] {
        let rows = (try? database.read {
            try $0.rows("SELECT t.app, t.app_name, COUNT(i.id) FROM capture_threads t LEFT JOIN capture_items i ON i.thread_id = t.id GROUP BY t.app, t.app_name ORDER BY 3 DESC")
        }) ?? []
        return rows.map { (bundleId: $0[0] as! String, name: $0[1] as! String, items: Int($0[2] as! Int64)) }
    }

    // MARK: Retention

    /// Deletes items older than `days` and threads that no longer have any. Returns the number of items removed.
    @discardableResult
    func prune(olderThanDays days: Int, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86400).timeIntervalSince1970
        return (try? database.write { db in
            let before = (try db.rows("SELECT COUNT(*) FROM capture_items WHERE at < ?", [cutoff]).first?.first as? Int64) ?? 0
            try db.execute("DELETE FROM capture_items WHERE at < ?", [cutoff])
            try db.execute("DELETE FROM capture_messages WHERE first_seen < ?", [cutoff])
            try db.execute("DELETE FROM capture_threads WHERE last_seen < ? AND id NOT IN (SELECT thread_id FROM capture_items)", [cutoff])
            try db.execute("DELETE FROM capture_send_log WHERE at < ?", [cutoff])
            try db.execute("DELETE FROM capture_originals WHERE item_id NOT IN (SELECT id FROM capture_items)")
            return Int(before)
        }) ?? 0
    }

    /// Deletes everything captured. Tasks the user kept stay.
    func clearCaptures() {
        try? database.write { db in
            for table in ["capture_items", "capture_messages", "capture_threads", "capture_originals"] { try db.execute("DELETE FROM \(table)") }
        }
        database.checkpoint()
    }

    /// The database file and its WAL files are readable by the user only.
    static func restrictPermissions(of database: Database) {
        guard let path = database.path?.path else { return }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path + suffix)
        }
    }
}

extension CaptureStore {
    /// A stored item with everything the filter recorded, for the capture viewer.
    struct InspectRow: Identifiable, Equatable {
        var id: Int64
        var at: Date
        var app: String
        var appName: String
        var threadKey: String
        var threadTitle: String
        var kind: String
        var url: String?
        var version: Int
        var newMessages: Int
        var body: String
        var state: String
        var reason: String?
        var secret: Double?
        var calendar: Double?
        var task: Double?
        var related: String?
        var sentAt: Date?
        var redactions = CaptureRedactor.Report()
        /// Whether the unredacted text is still kept, and until when.
        var originalUntil: Date?
    }

    /// What happened to an item, in words: what was redacted and whether it was sent or kept local.
    func outcome(of row: InspectRow) -> String {
        let redaction = row.redactions.summary
        switch row.state {
        case "sent": return "\(redaction), sent"
        case "ready": return "\(redaction), waiting to be sent"
        case "local" where row.reason == CaptureDecisionFilter.flaggedReason: return "\(redaction), \(CaptureDecisionFilter.flaggedReason)"
        case "local": return "\(redaction), kept local" + (row.reason.map { " (\($0))" } ?? "")
        default: return "\(redaction), waiting for the filter"
        }
    }

    /// The newest items first, optionally only those in `state`. The viewer in Settings uses it so the user can see what was kept.
    func inspect(state: String? = nil, limit: Int = 200, now: Date = Date()) -> [InspectRow] {
        purgeOriginals(now: now)
        let sql = """
            SELECT i.id, i.at, t.app, t.app_name, t.key, t.title, t.kind, t.url, i.version, i.new_messages, i.body, i.state, i.reason,
                   i.secret, i.calendar, i.task, i.related, i.sent_at, i.redactions,
                   (SELECT at FROM capture_originals o WHERE o.item_id = i.id)
            FROM capture_items i JOIN capture_threads t ON t.id = i.thread_id
            """
        let rows: [[Database.Value]] = (try? database.read { db -> [[Database.Value]] in
            if let state { return try db.rows(sql + " WHERE i.state = ? ORDER BY i.id DESC LIMIT ?", [state, limit]) }
            return try db.rows(sql + " ORDER BY i.id DESC LIMIT ?", [limit])
        }) ?? []
        return rows.map {
            InspectRow(id: $0[0] as! Int64, at: Date(timeIntervalSince1970: $0[1] as! Double), app: $0[2] as! String, appName: $0[3] as! String,
                       threadKey: $0[4] as! String, threadTitle: $0[5] as! String, kind: $0[6] as! String, url: $0[7] as? String,
                       version: Int(($0[8] as? Int64) ?? 0), newMessages: Int(($0[9] as? Int64) ?? 0), body: $0[10] as? String ?? "",
                       state: $0[11] as? String ?? "", reason: $0[12] as? String, secret: $0[13] as? Double, calendar: $0[14] as? Double,
                       task: $0[15] as? Double, related: $0[16] as? String, sentAt: ($0[17] as? Double).map { Date(timeIntervalSince1970: $0) },
                       redactions: CaptureRedactor.Report(json: $0[18] as? String) ?? CaptureRedactor.Report(),
                       originalUntil: ($0[19] as? Double).map { Date(timeIntervalSince1970: $0 + Self.originalRetention) }.flatMap { $0 > now ? $0 : nil })
        }
    }
}
