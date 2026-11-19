import XCTest
@testable import IronPet

/// Builds an `IronPetAPI` over in-memory stores, so an area's tests drive it only through the API. Each step adds its own
/// stores here as its namespace appears.
@MainActor
enum APITestSupport {
    /// The API over in-memory stores. `now` is the clock the task store uses.
    static func makeAPI(events: APIEventBus? = nil, now: @escaping () -> Date = Date.init) -> IronPetAPI {
        let tasks = TaskStore(database: memoryDatabase(), now: now, keepDoneDays: { 30 })
        return IronPetAPI(stores: .init(tasks: tasks), events: events)
    }

    static func memoryDatabase() -> Database {
        Database.open(path: nil, migrations: AppMigrations.all).database
    }
}
