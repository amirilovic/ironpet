import Foundation

/// A change to the memory files, for Settings → Memory → Recently learned and its Undo.
struct MemoryChange: Identifiable, Equatable {
    enum Action: String {
        /// A note was added. Undo removes it.
        case added
        /// A note was removed. Undo puts it back.
        case forgot
        /// A note replaced older ones (`previous`). Undo puts those back instead.
        case replaced
        /// The whole file was rewritten, by a tidy pass or the editor. `previous` is the `.history` file it can go back to.
        case tidied, edited
    }

    let id: Int64
    let at: Date
    /// The file's path inside the memory folder, such as `me.md` or `projects/ironpet-1a2b3c4d.md`.
    let file: String
    /// The person, for a note in `people.md`.
    let section: String?
    let action: Action
    /// The note line, or a short description for a whole-file change.
    let note: String
    let previous: String?
    let source: String
    var undone: Bool
}

/// Search over what Ghost has seen and kept, in ironpet's shared database: chat messages, meeting summaries and transcripts, the
/// notes and their earlier versions. FTS5 over an external-content table, as `capture_fts` does. Screen captures are not copied
/// here; `MemoryMCP` asks `CaptureStore` for them. Also holds where each thread's reflection stopped and the change log.
///
/// Tables are prefixed `memory_`. Indexing chats and meetings runs on a background queue, so a thread save never waits for it.
final class MemoryIndex: @unchecked Sendable { // `database` serializes its own reads and writes; `queue` is the only other state.
    static let migrations: [Database.Migration] = [
        .init(510, "memory: documents with a text index, reflection cursors and the change log", sql: """
            CREATE TABLE memory_docs(id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, ref TEXT NOT NULL, at REAL NOT NULL,
                                     title TEXT NOT NULL, text TEXT NOT NULL, UNIQUE(kind, ref));
            CREATE INDEX memory_docs_by_time ON memory_docs(at);
            CREATE VIRTUAL TABLE memory_fts USING fts5(text, title, content='memory_docs', content_rowid='id');
            CREATE TRIGGER memory_fts_insert AFTER INSERT ON memory_docs BEGIN
                INSERT INTO memory_fts(rowid, text, title) VALUES(new.id, new.text, new.title);
            END;
            CREATE TRIGGER memory_fts_delete AFTER DELETE ON memory_docs BEGIN
                INSERT INTO memory_fts(memory_fts, rowid, text, title) VALUES('delete', old.id, old.text, old.title);
            END;
            CREATE TRIGGER memory_fts_update AFTER UPDATE ON memory_docs BEGIN
                INSERT INTO memory_fts(memory_fts, rowid, text, title) VALUES('delete', old.id, old.text, old.title);
                INSERT INTO memory_fts(rowid, text, title) VALUES(new.id, new.text, new.title);
            END;
            CREATE TABLE memory_reflections(thread TEXT PRIMARY KEY, last_item TEXT NOT NULL, at REAL NOT NULL);
            CREATE TABLE memory_changes(id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, file TEXT NOT NULL, section TEXT,
                                        action TEXT NOT NULL, note TEXT NOT NULL, previous TEXT, source TEXT NOT NULL,
                                        undone INTEGER NOT NULL DEFAULT 0);
            """),
    ]

    enum Kind: String, CaseIterable {
        case chat, meeting, note, history
    }

    struct Hit: Equatable {
        let kind: Kind
        /// `chat`: `<thread>/<item>`. `meeting`: `<folder path>/summary` or `<folder path>/transcript#<n>`. `note`: `<file>|<n>`.
        /// `history`: the `.history` file's path inside the memory folder.
        let ref: String
        let at: Date
        let title: String
        let snippet: String
    }

    /// Lines per transcript document, so a hit points at a part of a long meeting.
    static let transcriptChunkLines = 40

    let database: Database
    private let queue = DispatchQueue(label: "ironpet.memory.index", qos: .utility)

    init(database: Database) {
        self.database = database
    }

    /// Waits for queued indexing. Tests call it before reading.
    func flush() { queue.sync {} }

    // MARK: Chats

    /// Indexes the user's and Ghost's messages of a thread, in the background. Tool output, screenshots and errors are left out,
    /// and so are automation runs and the prompts an automation sent, which can hold text from outside.
    func indexThread(_ thread: ChatThread) {
        queue.async { [self] in
            do { try write(thread) } catch { NSLog("ironpet: could not index thread \(thread.id): \(error.localizedDescription)") }
        }
    }

    /// The thread's messages as documents: `(item id, date, text)`.
    static func messages(of thread: ChatThread) -> [(id: String, at: Date, text: String)] {
        guard !thread.isAutomationRun else { return [] }
        return thread.items.compactMap { item in
            switch item.kind {
            case .user(let text) where item.origin != ChatSession.automationOrigin: return (item.id.uuidString, item.date ?? thread.updatedAt, text)
            case .assistant(let text): return (item.id.uuidString, item.date ?? thread.updatedAt, text)
            default: return nil
            }
        }.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func write(_ thread: ChatThread) throws {
        let messages = Self.messages(of: thread)
        let prefix = thread.id + "/"
        try database.write { db in
            let existing = try db.rows("SELECT ref FROM memory_docs WHERE kind = 'chat' AND substr(ref, 1, ?) = ?", [prefix.count, prefix])
                .compactMap { $0[0] as? String }
            let current = Set(messages.map { prefix + $0.id })
            for ref in existing where !current.contains(ref) {
                try db.execute("DELETE FROM memory_docs WHERE kind = 'chat' AND ref = ?", [ref])
            }
            for message in messages {
                try Self.upsert(db, .chat, prefix + message.id, at: message.at, title: thread.title, text: message.text)
            }
        }
    }

    private static func upsert(_ db: Database.Connection, _ kind: Kind, _ ref: String, at: Date, title: String, text: String) throws {
        try db.execute("""
            INSERT INTO memory_docs(kind, ref, at, title, text) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(kind, ref) DO UPDATE SET at = excluded.at, title = excluded.title, text = excluded.text
            WHERE memory_docs.text IS NOT excluded.text OR memory_docs.title IS NOT excluded.title OR memory_docs.at IS NOT excluded.at
            """, [kind.rawValue, ref, at.timeIntervalSince1970, title, text])
    }

    // MARK: Meetings

    /// Indexes a meeting's `summary.md` and its transcript in parts, in the background.
    func indexMeeting(_ folder: URL) {
        queue.async { [self] in
            do { try writeMeeting(folder) } catch { NSLog("ironpet: could not index meeting \(folder.lastPathComponent): \(error.localizedDescription)") }
        }
    }

    private func writeMeeting(_ folder: URL) throws {
        let at = MeetingLibrary.date(folderName: folder.lastPathComponent) ?? Date()
        let title = "Meeting " + folder.lastPathComponent
        let summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
        let transcript = (try? String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
        let lines = transcript.components(separatedBy: "\n")
        let chunks = stride(from: 0, to: lines.count, by: Self.transcriptChunkLines).map {
            lines[$0..<min(lines.count, $0 + Self.transcriptChunkLines)].joined(separator: "\n")
        }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let prefix = folder.path + "/"
        try database.write { db in
            try db.execute("DELETE FROM memory_docs WHERE kind = 'meeting' AND substr(ref, 1, ?) = ?", [prefix.count, prefix])
            if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try Self.upsert(db, .meeting, prefix + "summary", at: at, title: title + " · summary", text: summary)
            }
            for (n, chunk) in chunks.enumerated() {
                try Self.upsert(db, .meeting, prefix + "transcript#\(n)", at: at, title: title + " · transcript", text: chunk)
            }
        }
    }

    /// Drops a meeting from the index, when its folder goes to the Trash.
    func removeMeeting(_ folder: URL) {
        let prefix = folder.path + "/"
        queue.async { [self] in
            try? database.write { try $0.execute("DELETE FROM memory_docs WHERE kind = 'meeting' AND substr(ref, 1, ?) = ?", [prefix.count, prefix]) }
            database.checkpoint()
        }
    }

    // MARK: Notes

    /// Replaces the index of one memory file's notes. Runs at once: the files are small, and the next search must see the change.
    func indexNotes(file: String, title: String, entries: [MemoryDocument.Entry], modified: Date) {
        let prefix = file + "|"
        try? database.write { db in
            try db.execute("DELETE FROM memory_docs WHERE kind = 'note' AND substr(ref, 1, ?) = ?", [prefix.count, prefix])
            for (n, entry) in entries.enumerated() {
                let at = entry.note.date.flatMap(Self.dayFormatter.date(from:)) ?? modified
                let heading = entry.section.map { "\(title) · \($0)" } ?? title
                try Self.upsert(db, .note, prefix + "\(n)", at: at, title: heading, text: entry.note.text)
            }
        }
    }

    func indexHistory(ref: String, title: String, text: String, at: Date) {
        try? database.write { try Self.upsert($0, .history, ref, at: at, title: title, text: text) }
    }

    func removeHistory(ref: String) {
        try? database.write { try $0.execute("DELETE FROM memory_docs WHERE kind = 'history' AND ref = ?", [ref]) }
    }

    /// Drops the index of every note and earlier version, and the change log. Chats and meetings stay searchable.
    func clearNotes() {
        try? database.write { db in
            try db.execute("DELETE FROM memory_docs WHERE kind IN ('note', 'history')")
            try db.execute("DELETE FROM memory_changes")
        }
        database.checkpoint()
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: Backfill

    /// Indexes what is on disk: every saved thread and meeting, and drops the documents of threads and meetings that are gone, so a
    /// deleted chat or meeting is not found again. Runs in the background at launch; documents that did not change are left alone.
    func backfill(threads: @escaping @Sendable () -> [ChatThread], meetings: URL) {
        queue.async { [self] in
            let saved = threads()
            for thread in saved { try? write(thread) }
            let folders = ((try? FileManager.default.contentsOfDirectory(at: meetings, includingPropertiesForKeys: nil)) ?? [])
                .filter { MeetingLibrary.date(folderName: $0.lastPathComponent) != nil }
            for folder in folders { try? writeMeeting(folder) }
            do { try removeMissing(threads: Set(saved.map(\.id)), meetings: Set(folders.map { $0.standardizedFileURL.path })) } catch {
                NSLog("ironpet: could not prune the memory index: \(error.localizedDescription)")
            }
        }
    }

    private func removeMissing(threads: Set<String>, meetings: Set<String>) throws {
        let refs = try database.read { try $0.rows("SELECT kind, ref FROM memory_docs WHERE kind IN ('chat', 'meeting')") }
        var gone: [(String, String)] = []
        for row in refs {
            guard let kind = row[0] as? String, let ref = row[1] as? String else { continue }
            if kind == "chat", let slash = ref.firstIndex(of: "/"), !threads.contains(String(ref[..<slash])) { gone.append((kind, ref)) }
            if kind == "meeting", let slash = ref.lastIndex(of: "/"),
               !meetings.contains(URL(fileURLWithPath: String(ref[..<slash])).standardizedFileURL.path) { gone.append((kind, ref)) }
        }
        guard !gone.isEmpty else { return }
        try database.write { db in
            for (kind, ref) in gone { try db.execute("DELETE FROM memory_docs WHERE kind = ? AND ref = ?", [kind, ref]) }
        }
        database.checkpoint()
    }

    // MARK: Search

    /// Documents with every word of `query`, best match first.
    func search(_ query: String, kinds: Set<Kind>? = nil, since: Date? = nil, until: Date? = nil, limit: Int = 20) -> [Hit] {
        guard let match = CaptureStore.matchQuery(query) else { return [] }
        var clauses = ["memory_fts MATCH ?"], args: [Database.Value] = [match]
        if let kinds, !kinds.isEmpty {
            clauses.append("d.kind IN (\(kinds.map { _ in "?" }.joined(separator: ", ")))")
            args += kinds.map(\.rawValue).sorted()
        }
        if let since { clauses.append("d.at >= ?"); args.append(since.timeIntervalSince1970) }
        if let until { clauses.append("d.at < ?"); args.append(until.timeIntervalSince1970) }
        args.append(max(1, min(limit, 100)))
        let sql = """
            SELECT d.kind, d.ref, d.at, d.title, snippet(memory_fts, 0, '[', ']', '…', 24)
            FROM memory_fts JOIN memory_docs d ON d.id = memory_fts.rowid
            WHERE \(clauses.joined(separator: " AND ")) ORDER BY rank, d.at DESC LIMIT ?
            """
        let rows = (try? database.read { try $0.rows(sql, args) }) ?? []
        return rows.compactMap { row in
            guard let kind = (row[0] as? String).flatMap(Kind.init(rawValue:)), let ref = row[1] as? String else { return nil }
            return Hit(kind: kind, ref: ref, at: Date(timeIntervalSince1970: row[2] as? Double ?? 0), title: row[3] as? String ?? "",
                       snippet: row[4] as? String ?? "")
        }
    }

    /// One document's full text and title.
    func document(_ kind: Kind, _ ref: String) -> (title: String, text: String, at: Date)? {
        guard let row = (try? database.read { try $0.rows("SELECT title, text, at FROM memory_docs WHERE kind = ? AND ref = ?", [kind.rawValue, ref]) })?.first
        else { return nil }
        return (row[0] as? String ?? "", row[1] as? String ?? "", Date(timeIntervalSince1970: row[2] as? Double ?? 0))
    }

    /// The `.history` documents of one file, newest first.
    func history(of file: String) -> [(ref: String, at: Date)] {
        let prefix = FileMemoryStore.historyFolder(for: file) + "/"
        let rows = (try? database.read {
            try $0.rows("SELECT ref, at FROM memory_docs WHERE kind = 'history' AND substr(ref, 1, ?) = ? ORDER BY at DESC", [prefix.count, prefix])
        }) ?? []
        return rows.compactMap { row in (row[0] as? String).map { ($0, Date(timeIntervalSince1970: row[1] as? Double ?? 0)) } }
    }

    func count(_ kind: Kind) -> Int {
        ((try? database.read { try $0.rows("SELECT COUNT(*) FROM memory_docs WHERE kind = ?", [kind.rawValue]) })?.first?.first as? Int64)
            .map(Int.init) ?? 0
    }

    // MARK: Reflection cursors

    /// The last item the reflection pass read in this thread (or the digest of a meeting summary it read), and when.
    func cursor(_ thread: String) -> (item: String, at: Date)? {
        guard let row = (try? database.read { try $0.rows("SELECT last_item, at FROM memory_reflections WHERE thread = ?", [thread]) })?.first,
              let item = row[0] as? String else { return nil }
        return (item, Date(timeIntervalSince1970: row[1] as? Double ?? 0))
    }

    func setCursor(_ thread: String, item: String, at: Date = Date()) {
        try? database.write {
            try $0.execute("""
                INSERT INTO memory_reflections(thread, last_item, at) VALUES(?, ?, ?)
                ON CONFLICT(thread) DO UPDATE SET last_item = excluded.last_item, at = excluded.at
                """, [thread, item, at.timeIntervalSince1970])
        }
    }

    // MARK: Changes

    @discardableResult
    func record(at: Date, file: String, section: String?, action: MemoryChange.Action, note: String, previous: String?, source: String) -> Int64? {
        try? database.write { db in
            try db.execute("INSERT INTO memory_changes(at, file, section, action, note, previous, source) VALUES(?, ?, ?, ?, ?, ?, ?)",
                           [at.timeIntervalSince1970, file, section, action.rawValue, note, previous, source])
            return try db.rows("SELECT last_insert_rowid()").first?.first as? Int64
        }
    }

    /// The newest changes first.
    func changes(limit: Int = 20) -> [MemoryChange] {
        let rows = (try? database.read {
            try $0.rows("SELECT id, at, file, section, action, note, previous, source, undone FROM memory_changes ORDER BY id DESC LIMIT ?", [limit])
        }) ?? []
        return rows.compactMap(Self.change)
    }

    func change(_ id: Int64) -> MemoryChange? {
        (try? database.read {
            try $0.rows("SELECT id, at, file, section, action, note, previous, source, undone FROM memory_changes WHERE id = ?", [id])
        })?.first.flatMap(Self.change)
    }

    /// Whether a change to `file` after `id` is still in place.
    func hasLaterChange(to file: String, after id: Int64) -> Bool {
        let count = (try? database.read {
            try $0.rows("SELECT COUNT(*) FROM memory_changes WHERE file = ? AND id > ? AND undone = 0", [file, id])
        })?.first?.first as? Int64 ?? 0
        return count > 0
    }

    func markUndone(_ id: Int64) {
        try? database.write { try $0.execute("UPDATE memory_changes SET undone = 1 WHERE id = ?", [id]) }
    }

    private static func change(_ row: [Database.Value]) -> MemoryChange? {
        guard let id = row[0] as? Int64, let action = (row[4] as? String).flatMap(MemoryChange.Action.init(rawValue:)) else { return nil }
        return MemoryChange(id: id, at: Date(timeIntervalSince1970: row[1] as? Double ?? 0), file: row[2] as? String ?? "",
                            section: row[3] as? String, action: action, note: row[5] as? String ?? "", previous: row[6] as? String,
                            source: row[7] as? String ?? "", undone: (row[8] as? Int64 ?? 0) != 0)
    }
}
