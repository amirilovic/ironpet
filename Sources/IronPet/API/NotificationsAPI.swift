import Combine
import Foundation

/// Which notifications `NotificationsAPI.list` returns. Every field narrows the list; the default is the newest 200.
struct ListNotificationsRequest: Codable, Equatable {
    var since: Date?
    var until: Date?
    var source: String?
    var type: NotificationType?
    var unreadOnly = false
    var limit = 200
}

/// The notifications that match, newest first, and how many are unread in all (not only among the matches).
struct NotificationList: Codable, Equatable {
    var notifications: [NotificationItem]
    var unread: Int
}

/// The notification history: every bubble ironpet showed, with its full text and links. Clients read it and set read state here.
/// Notifications are created by the owners that show a bubble (`Announcer`, `AutomationService`), not by a client.
@MainActor
final class NotificationsAPI: ObservableObject {
    private let store: NotificationStore
    private var forwarding: AnyCancellable?

    init(store: NotificationStore) {
        self.store = store
        forwarding = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// A history that holds nothing, for a view that is not shown yet.
    static func empty() -> NotificationsAPI {
        NotificationsAPI(store: NotificationStore(database: Database.open(path: nil, migrations: NotificationStore.migrations).database))
    }

    var unreadCount: Int { store.unreadCount }

    func list(_ request: ListNotificationsRequest = ListNotificationsRequest()) -> NotificationList {
        let filter = NotificationStore.Filter(since: request.since, until: request.until, source: request.source, type: request.type,
                                              unreadOnly: request.unreadOnly, limit: request.limit)
        return NotificationList(notifications: store.list(filter), unread: store.unreadCount)
    }

    /// One notification with its full description and links.
    func get(_ id: String) throws -> NotificationItem {
        guard let item = store.get(id) else { throw APIError.notFound("no notification with id \(id)") }
        return item
    }

    /// The sources that have notifications: automation ids, and `system`.
    func sources() -> [String] { store.sources() }

    func markRead(_ id: String) throws {
        guard store.get(id) != nil else { throw APIError.notFound("no notification with id \(id)") }
        store.markRead(id)
    }

    func markAllRead() { store.markAllRead() }
}
