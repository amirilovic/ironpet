import XCTest
@testable import IronPet

/// Builds an `IronPetAPI` over in-memory stores, so an area's tests drive it only through the API. Each step adds its own
/// stores here as its namespace appears.
@MainActor
enum APITestSupport {
    /// The API over in-memory stores. `now` is the clock the task store uses.
    static func makeAPI(events: APIEventBus? = nil, now: @escaping () -> Date = Date.init,
                        automations: [Automation] = [], clock: AutomationTestClock = AutomationTestClock(),
                        signals: SignalStore? = nil, bubbles: BubbleStore? = nil, sessions: SessionStore? = nil, chat: ChatSession? = nil,
                        meeting: MeetingController? = nil, meetingLibrary: MeetingLibrary? = nil, config: ConfigStore? = nil, petFolders: IronPetAPI.PetFolders? = nil) -> IronPetAPI {
        let tasks = TaskStore(database: memoryDatabase(), now: now, keepDoneDays: { 30 })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-api-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let paths = AutomationPaths(file: dir.appendingPathComponent("automations.json"), directory: dir.appendingPathComponent("automations"))
        let store = AutomationStore(paths: paths, defaults: { automations }, watch: false)
        let service = AutomationService(store: store, engine: AutomationEngine(env: clock.environment))
        service.runShell = { _, _ in CommandResult(code: 0, stdout: "ok") }
        return IronPetAPI(stores: .init(tasks: tasks, automations: service, signals: signals ?? SignalStore(), bubbles: bubbles ?? BubbleStore(), sessions: sessions ?? SessionStore(), chat: chat ?? ChatSession(restore: false),
                                 meeting: meeting ?? MeetingController(), meetingLibrary: meetingLibrary ?? MeetingLibrary(root: dir.appendingPathComponent("meetings")),
                                 config: config ?? ConfigStore(memory: Config()),
                                 petFolders: petFolders ?? .init(library: dir.appendingPathComponent("pets"), bundled: nil,
                                                                  backgrounds: dir.appendingPathComponent("backgrounds"))),
                          events: events)
    }

    static func memoryDatabase() -> Database {
        Database.open(path: nil, migrations: AppMigrations.all).database
    }
}
