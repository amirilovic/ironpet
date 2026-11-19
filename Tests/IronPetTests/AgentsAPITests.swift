import XCTest
@testable import IronPet

/// Drives agent sessions only through `IronPetAPI`. The hook events that create sessions go into the store the helper was given,
/// as the hook server does.
@MainActor
final class AgentsAPITests: XCTestCase {
    private var events: APIEventBus!
    private var seen: [APIEvent] = []
    private var sessions: SessionStore!
    private var api: IronPetAPI!

    override func setUp() async throws {
        events = APIEventBus()
        seen = []
        events.subscribe { [unowned self] in seen.append($0) }
        sessions = SessionStore()
        api = APITestSupport.makeAPI(events: events, sessions: sessions)
    }

    private func hook(_ name: String, session: String = "s1", payload: [String: Any] = [:], source: AgentSource = .claude) {
        var payload = payload
        payload["session_id"] = session
        sessions.apply(HookEvent(source: source, name: name, payload: payload, origin: SessionOrigin(workspace: "/Users/me/web-app")))
    }

    func testListAndGetShowWatchedSessionsMostUrgentFirst() throws {
        hook("UserPromptSubmit", session: "a", payload: ["prompt": "Fix login"])
        hook("Notification", session: "b", payload: ["message": "Needs permission"])
        let list = api.agents.list()
        XCTAssertFalse(list.isEmpty)
        XCTAssertEqual(list.first?.status, .needsInput)
        let session = try api.agents.get(list[0].id)
        XCTAssertEqual(session.workspaceName, "web-app")
        XCTAssertThrowsError(try api.agents.get("nope")) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
        XCTAssertEqual(api.agents.summary.status, .needsInput)
    }

    func testAcknowledgeClearsAFinishedSession() throws {
        hook("UserPromptSubmit")
        hook("Stop")
        let id = try XCTUnwrap(api.agents.list().first?.id)
        XCTAssertEqual(try api.agents.get(id).status, .done)
        try api.agents.acknowledge(id)
        XCTAssertEqual(try api.agents.get(id).status, .idle)
        XCTAssertTrue(api.agents.list().isEmpty, "idle sessions are not listed")
        XCTAssertThrowsError(try api.agents.acknowledge("nope")) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
    }

    func testAcknowledgeAll() {
        hook("UserPromptSubmit", session: "a"); hook("Stop", session: "a")
        hook("UserPromptSubmit", session: "b"); hook("Stop", session: "b")
        XCTAssertEqual(api.agents.list().count, 2)
        api.agents.acknowledgeAll()
        XCTAssertTrue(api.agents.list().isEmpty)
    }

    func testFocusAndAskNeedAHandlerAndPassTheSession() throws {
        hook("UserPromptSubmit")
        let id = try XCTUnwrap(api.agents.list().first?.id)
        XCTAssertThrowsError(try api.agents.focus(id)) { XCTAssertEqual(($0 as? APIError)?.code, .unavailable) }
        XCTAssertThrowsError(try api.agents.ask(id)) { XCTAssertEqual(($0 as? APIError)?.code, .unavailable) }
        var focused: [String] = []
        var asked: [String] = []
        api.agents.focusHandler = { focused.append($0.id) }
        api.agents.askHandler = { asked.append($0) }
        try api.agents.focus(id)
        try api.agents.ask(id)
        XCTAssertEqual(focused, [id])
        XCTAssertTrue(try XCTUnwrap(asked.first).contains("web-app"))
        XCTAssertThrowsError(try api.agents.focus("nope")) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
    }

    func testChangesArriveOnTheBus() {
        hook("UserPromptSubmit")
        XCTAssertTrue(seen.contains { $0.kind == .agentsChanged })
    }

    func testSessionsRoundTripAsJSON() throws {
        hook("UserPromptSubmit", payload: ["prompt": "Fix login"])
        let list = api.agents.list()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode([AgentSession].self, from: encoder.encode(list))
        XCTAssertEqual(back.map(\.id), list.map(\.id))
        XCTAssertEqual(back.first?.source, .claude)
        XCTAssertEqual(back.first?.origin.workspace, "/Users/me/web-app")
    }
}
