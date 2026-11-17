import Foundation

/// The activity log in `ironpet.db` (`activity_events`): what ironpet announced or saw, kept 30 days so a summary of any
/// recent window can be built after a restart. Agent sessions live only in memory and a resolved alert's row is deleted,
/// so without this nothing could say what happened earlier. Nothing here leaves the Mac.
final class ActivityLog {
    static let retention: TimeInterval = 30 * 86_400

    static let migrations: [Database.Migration] = [
        .init(400, "activity: events", sql: """
            CREATE TABLE activity_events(id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, kind TEXT NOT NULL, ref TEXT NOT NULL,
                                         title TEXT NOT NULL, detail TEXT NOT NULL, url TEXT, extra TEXT);
            CREATE INDEX activity_events_by_time ON activity_events(at);
            """),
    ]

    private let database: Database
    private let now: () -> Date
    private var lastPrune = Date.distantPast

    /// Why the database is unavailable, when the log is only in memory.
    var unavailable: String? { database.unavailableReason }

    init(database: Database, now: @escaping () -> Date = Date.init) {
        self.database = database
        self.now = now
        prune()
    }

    func record(_ event: ActivityEvent) {
        if now().timeIntervalSince(lastPrune) > 86_400 { prune() }
        let extra = event.extra.isEmpty ? nil : (try? JSONEncoder().encode(event.extra)).map { String(decoding: $0, as: UTF8.self) }
        write { db in
            try db.execute("INSERT INTO activity_events(at, kind, ref, title, detail, url, extra) VALUES(?, ?, ?, ?, ?, ?, ?)",
                           [event.at.timeIntervalSince1970, event.kind.rawValue, event.ref, event.title, event.detail,
                            event.url?.absoluteString, extra])
        }
    }

    /// Events from the start of `window` up to, not including, its end, oldest first. `kinds` nil means all of them.
    func events(in window: DateInterval, kinds: Set<ActivityEvent.Kind>? = nil) -> [ActivityEvent] {
        let rows = read { db in
            try db.rows("SELECT at, kind, ref, title, detail, url, extra FROM activity_events WHERE at >= ? AND at < ? ORDER BY at, id",
                        [window.start.timeIntervalSince1970, window.end.timeIntervalSince1970])
        } ?? []
        return rows.compactMap { row -> ActivityEvent? in
            guard let at = row[0] as? Double, let kind = row[1] as? String, let ref = row[2] as? String, let title = row[3] as? String else { return nil }
            let event = ActivityEvent(at: Date(timeIntervalSince1970: at), kind: .init(kind), ref: ref, title: title,
                                      detail: row[4] as? String ?? "", url: (row[5] as? String).flatMap(URL.init(string:)),
                                      extra: (row[6] as? String).flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:])
            return kinds.map { $0.contains(event.kind) } ?? true ? event : nil
        }
    }

    /// Deletes events past the retention. Runs at launch and at most once a day after that.
    func prune() {
        lastPrune = now()
        write { try $0.execute("DELETE FROM activity_events WHERE at < ?", [now().addingTimeInterval(-Self.retention).timeIntervalSince1970]) }
    }

    private func read<T>(_ body: (Database.Connection) throws -> T) -> T? {
        do { return try database.read(body) } catch {
            NSLog("ironpet: activity log read failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func write(_ body: (Database.Connection) throws -> Void) {
        do { try database.write(body) } catch { NSLog("ironpet: activity log write failed: \(error.localizedDescription)") }
    }
}
