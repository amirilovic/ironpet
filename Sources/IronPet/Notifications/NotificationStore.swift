import Combine
import Foundation

/// Every bubble ironpet shows, kept in `ironpet.db` (`notification_items`, `notification_links`) so the Notifications section can
/// show the full text later. The description lives in the row itself, so a long report needs no file. Notifications are never
/// deleted by the user; rows older than `retention` are pruned at launch and once a day.
@MainActor
final class NotificationStore: ObservableObject {
    nonisolated static let retention: TimeInterval = 90 * 86_400

    nonisolated static let migrations: [Database.Migration] = [
        .init(530, "notifications: items and links", sql: """
            CREATE TABLE notification_items(id TEXT PRIMARY KEY, created REAL NOT NULL, source TEXT NOT NULL, type TEXT NOT NULL,
                                            title TEXT NOT NULL, summary TEXT NOT NULL, description TEXT NOT NULL, read REAL) WITHOUT ROWID;
            CREATE INDEX notification_items_by_time ON notification_items(created);
            CREATE TABLE notification_links(notification TEXT NOT NULL, position INTEGER NOT NULL, kind TEXT NOT NULL, ref TEXT NOT NULL,
                                            label TEXT, PRIMARY KEY(notification, position)) WITHOUT ROWID;
            """),
    ]

    /// How many are unread. Drives the sidebar badge.
    @Published private(set) var unreadCount = 0
    /// Changes whenever a row is added or marked read, so a view knows to read the list again.
    @Published private(set) var revision = 0

    /// Where changes are published. `IronPetAPI` sets it.
    var events: APIEventBus?

    private let database: Database
    private let now: () -> Date
    private var lastPrune = Date.distantPast

    init(database: Database, now: @escaping () -> Date = Date.init) {
        self.database = database
        self.now = now
        prune()
        unreadCount = countUnread()
    }

    struct Filter: Equatable {
        var since: Date?
        var until: Date?
        var source: String?
        var type: NotificationType?
        var unreadOnly = false
        var limit = 200
    }

    /// Stores a notification and returns it. Nil when the database refused the write.
    @discardableResult
    func add(_ draft: NotificationDraft) -> NotificationItem? {
        if now().timeIntervalSince(lastPrune) > 86_400 { prune() }
        let title = String(draft.title.prefix(NotificationDraft.maxTitle))
        let description = NotificationDraft.capped(draft.description)
        let summary = String((draft.summary.isEmpty ? NotificationDraft.summary(of: description.isEmpty ? title : description) : draft.summary)
            .prefix(NotificationDraft.maxSummary))
        let item = NotificationItem(id: UUID().uuidString, created: now(), source: draft.source, type: draft.type, title: title,
                                    summary: summary, description: description, read: nil,
                                    links: Array(draft.links.prefix(NotificationLink.maxLinks)))
        do {
            try database.write { db in
                try db.execute("INSERT INTO notification_items(id, created, source, type, title, summary, description, read) VALUES(?, ?, ?, ?, ?, ?, ?, NULL)",
                               [item.id, item.created.timeIntervalSince1970, item.source, item.type.rawValue, item.title, item.summary, item.description])
                for (position, link) in item.links.enumerated() {
                    try db.execute("INSERT INTO notification_links(notification, position, kind, ref, label) VALUES(?, ?, ?, ?, ?)",
                                   [item.id, position, link.kind.rawValue, link.ref, link.label])
                }
            }
        } catch {
            NSLog("ironpet: notification not stored: \(error.localizedDescription)")
            return nil
        }
        unreadCount += 1
        revision += 1
        events?.publish(.notificationsChanged, id: item.id)
        return item
    }

    /// Newest first. Links are filled in.
    func list(_ filter: Filter = Filter()) -> [NotificationItem] {
        var clauses: [String] = []
        var args: [Database.Value] = []
        if let since = filter.since { clauses.append("created >= ?"); args.append(since.timeIntervalSince1970) }
        if let until = filter.until { clauses.append("created < ?"); args.append(until.timeIntervalSince1970) }
        if let source = filter.source { clauses.append("source = ?"); args.append(source) }
        if let type = filter.type { clauses.append("type = ?"); args.append(type.rawValue) }
        if filter.unreadOnly { clauses.append("read IS NULL") }
        let limit = min(max(filter.limit, 1), 1000)
        let sql = "SELECT id, created, source, type, title, summary, description, read FROM notification_items"
            + (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")) + " ORDER BY created DESC, id LIMIT \(limit)"
        let rows = (try? database.read { try $0.rows(sql, args) }) ?? []
        return rows.compactMap(Self.item).map { withLinks($0) }
    }

    func get(_ id: String) -> NotificationItem? {
        let rows = (try? database.read {
            try $0.rows("SELECT id, created, source, type, title, summary, description, read FROM notification_items WHERE id = ?", [id])
        }) ?? []
        return rows.compactMap(Self.item).first.map { withLinks($0) }
    }

    /// The automations that have notifications, for the source filter.
    func sources() -> [String] {
        let rows = (try? database.read { try $0.rows("SELECT DISTINCT source FROM notification_items ORDER BY source") }) ?? []
        return rows.compactMap { $0.first as? String }
    }

    func markRead(_ id: String) {
        let changed = (try? database.write { db -> Bool in
            let unread = try db.rows("SELECT 1 FROM notification_items WHERE id = ? AND read IS NULL", [id]).count
            guard unread > 0 else { return false }
            try db.execute("UPDATE notification_items SET read = ? WHERE id = ?", [self.now().timeIntervalSince1970, id])
            return true
        }) ?? false
        if changed { refresh(id: id) }
    }

    func markAllRead() {
        _ = try? database.write { db in
            try db.execute("UPDATE notification_items SET read = ? WHERE read IS NULL", [self.now().timeIntervalSince1970])
        }
        refresh()
    }

    /// Deletes rows past the retention. Runs at launch and at most once a day after that.
    func prune() {
        lastPrune = now()
        let cutoff = now().addingTimeInterval(-Self.retention).timeIntervalSince1970
        let expired = ((try? database.read { try $0.rows("SELECT COUNT(*) FROM notification_items WHERE created < ?", [cutoff]) })?.first?.first as? Int64) ?? 0
        _ = try? database.write { db in
            try db.execute("DELETE FROM notification_links WHERE notification IN (SELECT id FROM notification_items WHERE created < ?)", [cutoff])
            try db.execute("DELETE FROM notification_items WHERE created < ?", [cutoff])
        }
        if expired > 0 { refresh() }
    }

    /// Reads the count again and tells views and the event bus. `id` is the one notification that changed, when it is one.
    private func refresh(id: String? = nil) {
        unreadCount = countUnread()
        revision += 1
        events?.publish(.notificationsChanged, id: id)
    }

    private func countUnread() -> Int {
        let rows = (try? database.read { try $0.rows("SELECT COUNT(*) FROM notification_items WHERE read IS NULL") }) ?? []
        return (rows.first?.first as? Int64).map(Int.init) ?? 0
    }

    private static func item(_ row: [Database.Value]) -> NotificationItem? {
        guard let id = row[0] as? String, let created = row[1] as? Double, let source = row[2] as? String, let type = row[3] as? String,
              let title = row[4] as? String, let summary = row[5] as? String, let description = row[6] as? String else { return nil }
        return NotificationItem(id: id, created: Date(timeIntervalSince1970: created), source: source,
                                type: NotificationType(rawValue: type) ?? .other, title: title, summary: summary, description: description,
                                read: (row[7] as? Double).map(Date.init(timeIntervalSince1970:)), links: [])
    }

    private func withLinks(_ item: NotificationItem) -> NotificationItem {
        var item = item
        let rows = (try? database.read {
            try $0.rows("SELECT kind, ref, label FROM notification_links WHERE notification = ? ORDER BY position", [item.id])
        }) ?? []
        item.links = rows.compactMap { row in
            guard let kind = (row[0] as? String).flatMap(NotificationLink.Kind.init(rawValue:)), let ref = row[1] as? String else { return nil }
            return NotificationLink(kind, ref, label: row[2] as? String)
        }
        return item
    }
}
