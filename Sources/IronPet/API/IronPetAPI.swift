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
        var signals: SignalStore
        var bubbles: BubbleStore
        var sessions: SessionStore
        var chat: ChatSession
        var meeting: MeetingController
        var meetingLibrary: MeetingLibrary
        var config: ConfigStore
        /// Where pet sheets and background images live. The app's own folders unless a test says otherwise.
        var petFolders = PetFolders()
    }

    struct PetFolders {
        var library = PetLibrary.folder
        var bundled = PetLibrary.bundledFolder
        var backgrounds = ChatBackground.folder
    }

    let events: APIEventBus
    let tasks: TasksAPI
    let automations: AutomationsAPI
    let alerts: AlertsAPI
    let bubbles: BubblesAPI
    let agents: AgentsAPI
    let chat: ChatAPI
    let meetings: MeetingsAPI
    let settings: SettingsAPI
    let pet: PetAPI

    init(stores: Stores, events: APIEventBus? = nil) {
        let events = events ?? APIEventBus()
        self.events = events
        stores.tasks.events = events
        stores.automations.store.events = events
        tasks = TasksAPI(store: stores.tasks)
        automations = AutomationsAPI(service: stores.automations)
        stores.signals.events = events
        stores.bubbles.events = events
        alerts = AlertsAPI(store: stores.signals)
        bubbles = BubblesAPI(store: stores.bubbles)
        stores.sessions.events = events
        agents = AgentsAPI(store: stores.sessions)
        stores.chat.events = events
        chat = ChatAPI(session: stores.chat)
        stores.meeting.events = events
        stores.meetingLibrary.events = events
        stores.config.events = events
        settings = SettingsAPI(store: stores.config)
        pet = PetAPI(settings: settings, library: stores.petFolders.library, bundled: stores.petFolders.bundled,
                     backgrounds: stores.petFolders.backgrounds)
        pet.events = events
        if stores.config === ConfigStore.shared { PetAPI.live = pet }
        // Tests build their own API over a memory-only config and must not replace the app's.
        if stores.config === ConfigStore.shared { SettingsAPI.live = settings }
        meetings = MeetingsAPI(controller: stores.meeting, library: stores.meetingLibrary)
    }
}
