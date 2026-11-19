import Foundation

/// The in-process API every client uses: the ironpet window and its views, the MCP endpoint, the `IronPet` CLI, Telegram, and
/// later a remote client. It is the only code that reads or writes the app's stores.
///
/// Conventions, for every area that moves behind it:
/// - One namespace per area, a property on this type (`api.tasks`), that holds the stores it serves and nothing else holds them
///   for a client.
/// - A call takes a `Codable` request value and returns a `Codable` response value, or throws `APIError`. No call returns a
///   store type, an `NSImage` or a closure, so the same call can later cross a network.
/// - Every change a client needs to see is published on `events` by the store that made it.
/// - Views read state through the API and observe the same stores they always did for redraws, but they never call a store.
///   `BoundaryTests` fails when a client file names a store type.
@MainActor
final class IronPetAPI {
    /// The stores the API serves. Only `IronPetAPI` and the AppKit owners that create them hold these.
    struct Stores {
        var tasks: TaskStore
        var automations: AutomationService
    }

    let events: APIEventBus
    let tasks: TasksAPI
    let automations: AutomationsAPI

    init(stores: Stores, events: APIEventBus? = nil) {
        let events = events ?? APIEventBus()
        self.events = events
        stores.tasks.events = events
        stores.automations.store.events = events
        tasks = TasksAPI(store: stores.tasks)
        automations = AutomationsAPI(service: stores.automations)
    }
}
