import Foundation

struct UsageRequest: Codable, Equatable {
    /// How many days to total, ending today.
    var days = 7
    /// Cuts the buckets by hour. Only useful for one day.
    var hourly = false
}

/// ironpet's own usage history: requests, tokens and cost per feature and model. It stays on this Mac.
@MainActor
final class UsageAPI {
    private let store: UsageStore

    /// The running app's usage, for the Usage settings page. `IronPetAPI` sets it to its own.
    static var live: UsageAPI?

    init(store: UsageStore) { self.store = store }

    /// Why usage is only in memory, when the database could not be opened.
    var unavailable: String? { store.unavailable }

    func summary(_ request: UsageRequest = UsageRequest()) throws -> UsageSummary {
        guard (1...400).contains(request.days) else { throw APIError.invalid("days must be between 1 and 400") }
        return store.summary(days: request.days, hourly: request.hourly)
    }

    /// Records one request. Writes happen on a background queue.
    func record(_ event: UsageEvent) { store.record(event) }
}
