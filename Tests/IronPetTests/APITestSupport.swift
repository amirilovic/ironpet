import XCTest
@testable import IronPet

/// Builds an `IronPetAPI` over in-memory stores, so an area's tests drive it only through the API. Each step adds its own
/// stores here as its namespace appears.
@MainActor
enum APITestSupport {
    static func makeAPI(events: APIEventBus? = nil) -> IronPetAPI {
        IronPetAPI(events: events)
    }

    static func memoryDatabase() -> Database {
        Database.open(path: nil, migrations: AppMigrations.all).database
    }
}
