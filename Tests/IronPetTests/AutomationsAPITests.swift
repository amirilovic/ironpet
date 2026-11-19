import XCTest
@testable import IronPet

/// Drives automations only through `IronPetAPI`, over a temporary file and the test clock.
@MainActor
final class AutomationsAPITests: XCTestCase {
    private var events: APIEventBus!
    private var seen: [APIEvent] = []

    override func setUp() async throws {
        events = APIEventBus()
        seen = []
        events.subscribe { [unowned self] in seen.append($0) }
    }

    private func reminder(_ id: String, enabled: Bool = true) -> Automation {
        Automation(id: id, name: id, enabled: enabled, trigger: .init(type: "interval", minutes: 45, clock: "wall"),
                   action: .init(type: "bubble", title: "\(id) title", body: "\(id) body"), createdBy: "user")
    }

    private func daily(_ id: String) -> Automation {
        Automation(id: id, name: id, enabled: true, trigger: .init(type: "daily", times: ["09:00"], weekdays: ["mon", "tue"]),
                   action: .init(type: "bubble", title: "t", body: "b"), createdBy: "user")
    }

    private func shell(_ id: String, by: String) -> Automation {
        Automation(id: id, name: id, enabled: true, trigger: .init(type: "interval", minutes: 60, clock: "wall"),
                   action: .init(type: "shell", command: "echo hi"), createdBy: by)
    }

    func testListGetAndStatus() throws {
        let api = APITestSupport.makeAPI(automations: [reminder("water"), reminder("eyes", enabled: false)])
        XCTAssertEqual(api.automations.list().map(\.id).sorted(), ["eyes", "water"])
        XCTAssertEqual(try api.automations.get("water").name, "water")
        XCTAssertThrowsError(try api.automations.get("nope")) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
        let status = try api.automations.status("water")
        XCTAssertTrue(status.trigger.contains("45 min"))
        XCTAssertNotNil(status.nextRun)
        XCTAssertNil(try api.automations.status("eyes").nextRun, "a paused automation has no next run")
        XCTAssertNil(status.approval)
    }

    func testCreateUpdateAndDelete() throws {
        let api = APITestSupport.makeAPI(events: events)
        let created = try api.automations.create(CreateAutomationRequest(
            definition: #"{"name": "Stretch", "trigger": {"type": "interval", "minutes": 30, "clock": "wall"}, "action": {"type": "bubble", "title": "Stretch", "body": "Up"}}"#))
        XCTAssertEqual(created.id, "stretch")
        XCTAssertEqual(created.createdBy, "user")
        let updated = try api.automations.update(UpdateAutomationRequest(id: "stretch", changes: #"{"name": "Stretch often"}"#, by: "user"))
        XCTAssertEqual(updated.name, "Stretch often")
        XCTAssertThrowsError(try api.automations.create(CreateAutomationRequest(definition: "not json"))) {
            XCTAssertEqual(($0 as? APIError)?.code, .invalid)
        }
        try api.automations.delete("stretch")
        XCTAssertTrue(api.automations.list().isEmpty)
        XCTAssertEqual(Set(seen.map(\.kind)), [.automationsChanged])
        XCTAssertGreaterThanOrEqual(seen.count, 3)
    }

    func testPauseResumeAndSchedule() throws {
        let api = APITestSupport.makeAPI(automations: [daily("standup")])
        try api.automations.setEnabled("standup", false)
        XCTAssertFalse(try api.automations.get("standup").enabled)
        try api.automations.setEnabled("standup", true)
        XCTAssertTrue(try api.automations.get("standup").enabled)
        try api.automations.setSchedule(SetAutomationScheduleRequest(id: "standup", times: ["10:30"], everyDay: true))
        let trigger = try api.automations.get("standup").trigger
        XCTAssertEqual(trigger.times, ["10:30"])
        XCTAssertNil(trigger.weekdays)
    }

    func testRunNowAndHistory() async throws {
        let api = APITestSupport.makeAPI(automations: [reminder("water")])
        let result = try await api.automations.runNow("water")
        XCTAssertEqual(result, AutomationRunResult(id: "water", status: "started"))
        XCTAssertNotNil(try api.automations.history(AutomationHistoryRequest(id: "water", limit: 5)))
        do { _ = try await api.automations.runNow("nope"); XCTFail("ran a missing automation") } catch {
            XCTAssertEqual((error as? APIError)?.code, .notFound)
        }
    }

    func testApproveAndRejectOfAnAgentsCommandAreAnAPICallAnyClientCanMake() throws {
        let api = APITestSupport.makeAPI(automations: [shell("agent-job", by: "agent:mcp"), shell("other-job", by: "agent:mcp")])
        XCTAssertEqual(try api.automations.status("agent-job").approval, .pending)
        XCTAssertEqual(try api.automations.approvalDetail("agent-job"), "echo hi")
        try api.automations.approve("agent-job")
        XCTAssertNil(try api.automations.status("agent-job").approval)

        try api.automations.reject("other-job")
        XCTAssertEqual(try api.automations.status("other-job").approval, .rejected)
        XCTAssertFalse(try api.automations.get("other-job").enabled, "a rejected automation is turned off")
        XCTAssertThrowsError(try api.automations.approve("nope")) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
    }

    func testApproveAndRejectPublishAutomationsChanged() throws {
        let events = APIEventBus()
        var seen: [APIEvent] = []
        events.subscribe { seen.append($0) }
        let api = APITestSupport.makeAPI(events: events, automations: [shell("a", by: "agent:mcp"), shell("b", by: "agent:mcp")])
        seen = []
        try api.automations.approve("a")
        XCTAssertEqual(seen.map(\.kind), [.automationsChanged])
        XCTAssertEqual(seen.first?.id, "a")
        seen = []
        try api.automations.reject("b")
        XCTAssertTrue(seen.allSatisfy { $0.kind == .automationsChanged })
        XCTAssertTrue(seen.contains { $0.id == "b" })
    }

    func testReplaceWithAHandEditedDefinition() throws {
        let api = APITestSupport.makeAPI(automations: [reminder("water")])
        var text = try api.automations.definition("water")
        text = text.replacingOccurrences(of: "\"minutes\" : 45", with: "\"minutes\" : 50")
        try api.automations.replace(id: "water", definition: text)
        XCTAssertEqual(try api.automations.get("water").trigger.minutes, 50)
        XCTAssertThrowsError(try api.automations.replace(id: "water", definition: "[]")) { XCTAssertEqual(($0 as? APIError)?.code, .invalid) }
    }

    func testJSONAdapterMatchesTheTypedCalls() async throws {
        let api = APITestSupport.makeAPI(automations: [reminder("water")])
        guard case .success(let value) = await api.automations.callJSON("pause", ["id": "water"], by: "agent:mcp") else { return XCTFail("pause failed") }
        XCTAssertEqual((value as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertFalse(try api.automations.get("water").enabled)
    }

    func testTypesRoundTripAsJSON() throws {
        let status = AutomationStatus(id: "a", trigger: "daily at 09:00", nextRun: Date(timeIntervalSince1970: 1_800_000_000),
                                      lastRun: AutomationRunInfo(date: Date(timeIntervalSince1970: 1_799_999_000), outcome: "ok", output: ""),
                                      approval: .pending, stream: nil, lastEvent: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(AutomationStatus.self, from: encoder.encode(status)), status)
    }
}
