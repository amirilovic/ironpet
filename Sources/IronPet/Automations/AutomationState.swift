import CryptoKit
import Foundation

/// What a poll automation has already reported. The first successful run only records ("baseline"), so existing
/// items do not fire. After that an item fires when its id is new, or when its version changed.
struct SeenSet: Equatable {
    struct Entry: Equatable {
        var version: String
        var lastSeen: Date
    }

    var baselined = false
    var entries: [String: Entry] = [:]
    var lastFired: Date?

    /// Items that should fire for this run, after recording everything in `items`.
    mutating func apply(_ items: [PollItem], now: Date, pruneAfter: TimeInterval = AutomationState.seenRetention) -> [PollItem] {
        defer {
            baselined = true
            entries = entries.filter { now.timeIntervalSince($0.value.lastSeen) < pruneAfter }
        }
        var fresh: [PollItem] = []
        for item in items {
            let known = entries[item.id]
            entries[item.id] = Entry(version: item.version, lastSeen: now)
            if baselined, known == nil || known?.version != item.version { fresh.append(item) }
        }
        return fresh
    }
}

/// Everything an automation remembers between runs, kept in ironpet's common database (`ironpet.db`) in `automation_*`
/// tables: seen sets, the last runs, approvals and snoozes. Old seen items and old history are pruned.
/// Definitions are not here. `automations.json` stays the source of truth for those.
final class AutomationState {
    struct Run: Equatable {
        var date: Date
        /// `fired`, `ok`, `failed`, `baseline`, `skipped` or `waiting`.
        var outcome: String
        var output: String
    }

    static let historyLimit = 20
    static let historyRetention: TimeInterval = 30 * 24 * 3600
    static let seenRetention: TimeInterval = 7 * 24 * 3600

    /// The tables this feature owns. The app passes them, with other features' migrations, to `Database`.
    static let migrations: [Database.Migration] = [
        .init(1, "automations: seen sets, runs, approvals, snoozes", sql: """
            CREATE TABLE automation_seen(automation TEXT NOT NULL, item TEXT NOT NULL, version TEXT NOT NULL, last_seen REAL NOT NULL,
                                         PRIMARY KEY(automation, item)) WITHOUT ROWID;
            CREATE TABLE automation_state(automation TEXT PRIMARY KEY, baselined INTEGER NOT NULL, last_fired REAL) WITHOUT ROWID;
            CREATE TABLE automation_runs(id INTEGER PRIMARY KEY AUTOINCREMENT, automation TEXT NOT NULL, at REAL NOT NULL,
                                         outcome TEXT NOT NULL, output TEXT NOT NULL);
            CREATE INDEX automation_runs_by_automation ON automation_runs(automation, id);
            CREATE TABLE automation_approvals(automation TEXT PRIMARY KEY, approved TEXT, rejected TEXT) WITHOUT ROWID;
            CREATE TABLE automation_snoozes(automation TEXT PRIMARY KEY, due REAL NOT NULL) WITHOUT ROWID;
            """),
        .init(2, "automations: script state", sql: """
            CREATE TABLE automation_script_state(automation TEXT PRIMARY KEY, state TEXT NOT NULL) WITHOUT ROWID;
            """),
        .init(3, "automations: alerts shown", sql: """
            CREATE TABLE automation_alerts(automation TEXT NOT NULL, alert TEXT NOT NULL, hash TEXT NOT NULL,
                                           PRIMARY KEY(automation, alert)) WITHOUT ROWID;
            """),
        .init(4, "automations: execution logs", sql: """
            CREATE TABLE automation_logs(id INTEGER PRIMARY KEY AUTOINCREMENT, automation TEXT NOT NULL, at REAL NOT NULL, duration REAL NOT NULL,
                                         outcome TEXT NOT NULL, summary TEXT NOT NULL, detail TEXT NOT NULL);
            CREATE INDEX automation_logs_by_automation ON automation_logs(automation, id);
            CREATE INDEX automation_logs_by_time ON automation_logs(at);
            """),
        // Alerts used to live in memory only. The payload lets ironpet restore open alerts at launch. Hash rows from
        // before this migration have no payload, so their hash is blanked. The automation then re-adds them on its next
        // run, and an empty stored hash tells the service to do it without a bubble.
        .init(5, "automations: open alert payloads", sql: """
            ALTER TABLE automation_alerts ADD COLUMN payload TEXT;
            UPDATE automation_alerts SET hash = '';
            """),
        // Numbered above every other feature's migrations, because a database already at a higher version would skip it.
        .init(410, "automations: last daily slot", sql: """
            CREATE TABLE IF NOT EXISTS automation_daily(automation TEXT PRIMARY KEY, last_slot REAL NOT NULL) WITHOUT ROWID;
            """),
    ]

    private let database: Database

    /// Why the database is unavailable, when history is only in memory.
    var unavailable: String? { database.unavailableReason }

    /// Uses the app's shared database. `nil` makes a private in-memory one, for tests and previews.
    init(database: Database? = nil) {
        self.database = database ?? Database.open(path: nil, migrations: Self.migrations).database
    }

    // MARK: Seen sets

    func seen(_ id: String) -> SeenSet? {
        read { db in
            guard let state = try db.rows("SELECT baselined, last_fired FROM automation_state WHERE automation = ?", [id]).first else { return nil }
            var set = SeenSet(baselined: (state[0] as? Int64) == 1, entries: [:], lastFired: (state[1] as? Double).map(Date.init(timeIntervalSince1970:)))
            for row in try db.rows("SELECT item, version, last_seen FROM automation_seen WHERE automation = ?", [id]) {
                guard let item = row[0] as? String, let version = row[1] as? String, let at = row[2] as? Double else { continue }
                set.entries[item] = .init(version: version, lastSeen: Date(timeIntervalSince1970: at))
            }
            return set
        } ?? nil
    }

    /// Replaces the stored set. Entries that are no longer in `set` (pruned) are deleted.
    func setSeen(_ id: String, _ set: SeenSet) {
        write { db in
            try db.execute("DELETE FROM automation_seen WHERE automation = ?", [id])
            for (item, entry) in set.entries {
                try db.execute("INSERT INTO automation_seen(automation, item, version, last_seen) VALUES(?, ?, ?, ?)",
                               [id, item, entry.version, entry.lastSeen.timeIntervalSince1970])
            }
            try db.execute("INSERT OR REPLACE INTO automation_state(automation, baselined, last_fired) VALUES(?, ?, ?)",
                           [id, Int64(set.baselined ? 1 : 0), set.lastFired?.timeIntervalSince1970])
        }
    }

    func forgetSeen(_ id: String) {
        write { db in
            try db.execute("DELETE FROM automation_seen WHERE automation = ?", [id])
            try db.execute("DELETE FROM automation_state WHERE automation = ?", [id])
        }
    }

    // MARK: Script state

    /// The JSON text a script automation returned last time, or nil before its first run.
    func scriptState(_ id: String) -> String? { text("SELECT state FROM automation_script_state WHERE automation = ?", id) }

    func setScriptState(_ id: String, _ state: String) {
        write { try $0.execute("INSERT OR REPLACE INTO automation_script_state(automation, state) VALUES(?, ?)", [id, state]) }
    }

    // MARK: Daily slots

    /// The last `daily` slot that fired or was skipped on purpose, for triggers with `catchUpMinutes`.
    func dailySlot(_ id: String) -> Date? {
        (read { try $0.rows("SELECT last_slot FROM automation_daily WHERE automation = ?", [id]).first?.first as? Double } ?? nil)
            .map(Date.init(timeIntervalSince1970:))
    }

    func setDailySlot(_ id: String, _ slot: Date) {
        write { try $0.execute("INSERT OR REPLACE INTO automation_daily(automation, last_slot) VALUES(?, ?)", [id, slot.timeIntervalSince1970]) }
    }

    // MARK: Execution logs

    /// One execution: a poll, a script run, a reminder that fired, a shell command, a prompt.
    struct Log: Identifiable, Equatable {
        let id: Int64
        var automation: String
        var date: Date
        var duration: TimeInterval
        /// `ok`, `failed`, `baseline`, `skipped`, `waiting` or `fired`.
        var outcome: String
        var summary: String
        var detail: String
    }

    static let logsPerAutomation = 2000
    static let maxLogDetail = 8 * 1024

    func addLog(_ automation: String, date: Date, duration: TimeInterval, outcome: String, summary: String, detail: String) {
        write { db in
            try db.execute("INSERT INTO automation_logs(automation, at, duration, outcome, summary, detail) VALUES(?, ?, ?, ?, ?, ?)",
                           [automation, date.timeIntervalSince1970, duration, outcome, String(summary.prefix(500)), String(detail.prefix(Self.maxLogDetail))])
            try db.execute("""
                DELETE FROM automation_logs WHERE automation = ?1
                  AND id <= COALESCE((SELECT id FROM automation_logs WHERE automation = ?1 ORDER BY id DESC LIMIT 1 OFFSET ?2), 0)
                """, [automation, Int64(Self.logsPerAutomation)])
        }
    }

    /// Newest first. `automation` nil means all of them.
    func logs(automation: String? = nil, limit: Int = 300) -> [Log] {
        let rows: [[Database.Value]] = read { db in
            if let automation {
                return try db.rows("SELECT id, automation, at, duration, outcome, summary, detail FROM automation_logs WHERE automation = ? ORDER BY id DESC LIMIT ?",
                                   [automation, Int64(limit)])
            }
            return try db.rows("SELECT id, automation, at, duration, outcome, summary, detail FROM automation_logs ORDER BY id DESC LIMIT ?", [Int64(limit)])
        } ?? []
        return rows.compactMap { row in
            guard let id = row[0] as? Int64, let automation = row[1] as? String, let at = row[2] as? Double, let duration = row[3] as? Double,
                  let outcome = row[4] as? String, let summary = row[5] as? String, let detail = row[6] as? String else { return nil }
            return Log(id: id, automation: automation, date: Date(timeIntervalSince1970: at), duration: duration, outcome: outcome, summary: summary, detail: detail)
        }
    }

    func clearLogs(automation: String? = nil) {
        write { db in
            if let automation { try db.execute("DELETE FROM automation_logs WHERE automation = ?", [automation]) }
            else { try db.execute("DELETE FROM automation_logs") }
        }
    }

    /// Drops logs older than `days` days.
    func pruneLogs(olderThanDays days: Int, now: Date = Date()) {
        write { try $0.execute("DELETE FROM automation_logs WHERE at < ?", [now.addingTimeInterval(-Double(max(1, days)) * 86_400).timeIntervalSince1970]) }
    }

    // MARK: Alerts shown

    /// A hash of the alert as it was last shown, so a script that lists it again unchanged does not bring it back.
    func alertHash(_ automation: String, _ alert: String) -> String? {
        (read { try $0.rows("SELECT hash FROM automation_alerts WHERE automation = ? AND alert = ?", [automation, alert]).first?.first as? String }) ?? nil
    }

    /// Remembers the alert's fingerprint and, while it is open, its payload so it can be restored after a restart.
    func setAlertHash(_ automation: String, _ alert: String, _ hash: String, signal: Signal? = nil) {
        let payload = signal.flatMap { try? JSONEncoder().encode(StoredSignal($0)) }.flatMap { String(data: $0, encoding: .utf8) }
        write { try $0.execute("INSERT OR REPLACE INTO automation_alerts(automation, alert, hash, payload) VALUES(?, ?, ?, ?)", [automation, alert, hash, payload]) }
    }

    /// The user dismissed the alert. The hash stays so a script that lists it again unchanged does not bring it back.
    func closeAlert(signalID: String) {
        write { try $0.execute("UPDATE automation_alerts SET payload = NULL WHERE 'automation:' || automation || ':' || alert = ?", [signalID]) }
    }

    /// Alerts that are open (not dismissed, not resolved), oldest first.
    func openAlerts() -> [Signal] {
        let rows = read { try $0.rows("SELECT automation, alert, payload FROM automation_alerts WHERE payload IS NOT NULL") } ?? []
        return rows.compactMap { row -> Signal? in
            guard let automation = row[0] as? String, let alert = row[1] as? String, let text = row[2] as? String,
                  let stored = try? JSONDecoder().decode(StoredSignal.self, from: Data(text.utf8)) else { return nil }
            return stored.signal(id: "automation:\(automation):\(alert)")
        }.sorted { $0.date < $1.date }
    }

    private struct StoredSignal: Codable {
        var title: String, subtitle: String, url: String?, date: Double, label: String, symbol: String, mood: String, ask: String?

        init(_ s: Signal) {
            title = s.title; subtitle = s.subtitle; url = s.url?.absoluteString; date = s.date.timeIntervalSince1970
            label = s.label; symbol = s.symbol; mood = s.mood.rawValue; ask = s.ask
        }

        func signal(id: String) -> Signal {
            Signal(id: id, title: title, subtitle: subtitle, url: url.flatMap(URL.init(string:)), date: Date(timeIntervalSince1970: date),
                   label: label, symbol: symbol, mood: PetMood(rawValue: mood) ?? .needsInput, ask: ask)
        }
    }

    func clearAlert(_ automation: String, _ alert: String) {
        write { try $0.execute("DELETE FROM automation_alerts WHERE automation = ? AND alert = ?", [automation, alert]) }
    }

    // MARK: History

    /// Oldest first.
    func history(_ id: String, limit: Int = historyLimit) -> [Run] {
        (read { db in
            try db.rows("SELECT at, outcome, output FROM automation_runs WHERE automation = ? ORDER BY id DESC LIMIT ?", [id, Int64(limit)])
        } ?? []).reversed().compactMap { row in
            guard let at = row[0] as? Double, let outcome = row[1] as? String, let output = row[2] as? String else { return nil }
            return Run(date: Date(timeIntervalSince1970: at), outcome: outcome, output: output)
        }
    }

    func record(_ id: String, _ run: Run) {
        write { db in
            try db.execute("INSERT INTO automation_runs(automation, at, outcome, output) VALUES(?, ?, ?, ?)",
                           [id, run.date.timeIntervalSince1970, run.outcome, run.output])
            try db.execute("""
                DELETE FROM automation_runs WHERE automation = ?1
                  AND id <= COALESCE((SELECT id FROM automation_runs WHERE automation = ?1 ORDER BY id DESC LIMIT 1 OFFSET ?2), 0)
                """, [id, Int64(Self.historyLimit)])
        }
    }

    // MARK: Approvals

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func approved(_ id: String) -> String? { text("SELECT approved FROM automation_approvals WHERE automation = ?", id) }
    func rejected(_ id: String) -> String? { text("SELECT rejected FROM automation_approvals WHERE automation = ?", id) }

    func setApproved(_ id: String, _ hash: String?) {
        write { try $0.execute("INSERT INTO automation_approvals(automation, approved) VALUES(?1, ?2) ON CONFLICT(automation) DO UPDATE SET approved = ?2", [id, hash]) }
    }

    func setRejected(_ id: String, _ hash: String?) {
        write { try $0.execute("INSERT INTO automation_approvals(automation, rejected) VALUES(?1, ?2) ON CONFLICT(automation) DO UPDATE SET rejected = ?2", [id, hash]) }
    }

    // MARK: Snoozes

    func setSnooze(_ id: String, due: Date) {
        write { try $0.execute("INSERT OR REPLACE INTO automation_snoozes(automation, due) VALUES(?, ?)", [id, due.timeIntervalSince1970]) }
    }

    func clearSnooze(_ id: String) {
        write { try $0.execute("DELETE FROM automation_snoozes WHERE automation = ?", [id]) }
    }

    func snoozes() -> [String: Date] {
        var out: [String: Date] = [:]
        for row in read({ try $0.rows("SELECT automation, due FROM automation_snoozes") }) ?? [] {
            if let id = row[0] as? String, let due = row[1] as? Double { out[id] = Date(timeIntervalSince1970: due) }
        }
        return out
    }

    // MARK: Housekeeping

    private static let tables = ["automation_seen", "automation_state", "automation_runs", "automation_approvals", "automation_snoozes", "automation_script_state", "automation_alerts", "automation_logs", "automation_daily"]

    /// Forgets everything about an automation that was deleted.
    func forget(_ id: String) {
        write { db in for table in Self.tables { try db.execute("DELETE FROM \(table) WHERE automation = ?", [id]) } }
    }

    /// Drops seen items and history that are past their retention, and state of automations that no longer exist.
    func prune(now: Date = Date(), keeping ids: Set<String>? = nil) {
        write { db in
            try db.execute("DELETE FROM automation_seen WHERE last_seen < ?", [now.addingTimeInterval(-Self.seenRetention).timeIntervalSince1970])
            try db.execute("DELETE FROM automation_runs WHERE at < ?", [now.addingTimeInterval(-Self.historyRetention).timeIntervalSince1970])
            try db.execute("DELETE FROM automation_snoozes WHERE due < ?", [now.addingTimeInterval(-3600).timeIntervalSince1970])
            guard let ids else { return }
            for table in Self.tables {
                let stored = try db.rows("SELECT DISTINCT automation FROM \(table)").compactMap { $0[0] as? String }
                for stale in Set(stored).subtracting(ids) { try db.execute("DELETE FROM \(table) WHERE automation = ?", [stale]) }
            }
        }
    }

    /// Row counts, for tests.
    func count(_ table: String) -> Int {
        Int((read { try $0.rows("SELECT COUNT(*) FROM \(table)").first?.first as? Int64 } ?? nil) ?? 0)
    }

    // MARK: Database

    private func text(_ sql: String, _ id: String) -> String? {
        (read { try $0.rows(sql, [id]).first?.first as? String }) ?? nil
    }

    private func read<T>(_ body: (Database.Connection) throws -> T) -> T? {
        do { return try database.read(body) } catch {
            NSLog("ironpet: database read failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func write(_ body: (Database.Connection) throws -> Void) {
        do { try database.write(body) } catch { NSLog("ironpet: database write failed: \(error.localizedDescription)") }
    }
}
