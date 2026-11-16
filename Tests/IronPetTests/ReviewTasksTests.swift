import XCTest
@testable import IronPet

/// The built-in "Review tasks" automation: always present, skipped without open tasks, and hidden when it changes nothing.
@MainActor
final class ReviewTasksTests: AutomationTestCase {
    private var chat: ChatSession!
    private var turns: [ACPTurn] = []
    private var deliver: [(AgentEvent) -> Void] = []
    private var open = true
    private let id = AutomationDefaults.reviewTasksID

    override func setUp() async throws {
        try await super.setUp()
        chat = ChatSession(restore: false)
        turns = []
        deliver = []
        open = true
        chat.workspace = FileManager.default.temporaryDirectory
        chat.turnRunner = { [unowned self] turn, onEvent in
            turns.append(turn)
            deliver.append(onEvent)
        }
    }

    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    private func wired() -> Rig {
        let rig = makeRig([AutomationDefaults.reviewTasks()])
        rig.service.sendToChat = { [unowned self] id, message in chat.submitFromAutomation(message, automation: id) }
        rig.service.chatRunPending = { [unowned self] id in chat.hasAutomationRun(id) }
        rig.service.hasOpenTasks = { [unowned self] in open }
        chat.onAutomation = { [weak service = rig.service] id, event in service?.chatOutcome(id, event) }
        return rig
    }

    private func history(_ rig: Rig) -> [String] {
        rig.service.history(id, limit: 20).map { "\($0["outcome"] ?? ""): \($0["output"] ?? "")" }
    }

    private var userTexts: [String] {
        chat.items.compactMap { if case .user(let text) = $0.kind { text } else { nil } }
    }

    private var assistantTexts: [String] {
        chat.items.compactMap { if case .assistant(let text) = $0.kind { text } else { nil } }
    }

    private func reply(_ text: String) async {
        deliver[0](.assistant(text))
        deliver[0](.finished(error: nil))
        await settle()
    }

    // S1
    func testAFreshConfigHasTheReviewOnWithNoApproval() {
        let store = AutomationStore(paths: paths, defaults: { [] }, builtIns: [AutomationDefaults.reviewTasks()], watch: false)
        assertReview(store)
    }

    func testAnExistingConfigWithoutTheKeyGetsItOn() throws {
        _ = AutomationStore(paths: paths, defaults: { [self.bubble("water", minutes: 45)] }, watch: false)
        let store = AutomationStore(paths: paths, defaults: { [] }, builtIns: [AutomationDefaults.reviewTasks()], watch: false)
        XCTAssertEqual(store.automations.map(\.id), ["water", id])
        assertReview(store)
        let again = AutomationStore(paths: paths, defaults: { [] }, builtIns: [AutomationDefaults.reviewTasks()], watch: false)
        XCTAssertEqual(again.automations.map(\.id), ["water", id])
    }

    private func assertReview(_ store: AutomationStore, enabled: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        guard let a = store.automations.first(where: { $0.id == id }) else { return XCTFail("review-tasks missing", file: file, line: line) }
        XCTAssertEqual(a.name, "Review tasks", file: file, line: line)
        XCTAssertEqual(a.enabled, enabled, file: file, line: line)
        XCTAssertEqual(a.trigger.type, "interval", file: file, line: line)
        XCTAssertEqual(a.trigger.minutes, 10, file: file, line: line)
        XCTAssertEqual(a.trigger.clock, "wall", file: file, line: line)
        XCTAssertEqual(a.action.type, "prompt", file: file, line: line)
        XCTAssertEqual(a.action.prompt, "/ironpet-tasks", file: file, line: line)
        let service = AutomationService(store: store, engine: AutomationEngine(env: clock.environment))
        XCTAssertFalse(service.needsApproval(a), file: file, line: line)
    }

    // S2
    func testItSkipsWithoutOpenTasks() async {
        let rig = wired()
        open = false
        run(rig, minutes: 10)
        await settle()
        XCTAssertTrue(chat.items.isEmpty)
        XCTAssertTrue(turns.isEmpty)
        XCTAssertTrue(history(rig).contains("skipped: skipped: no open tasks"))
    }

    // S3
    func testItSendsOnePromptAndNotASecondWhileItRuns() async {
        let rig = wired()
        run(rig, minutes: 10)
        await settle()
        XCTAssertEqual(userTexts, ["Automation \"Review tasks\" (every 10 min):\n\n/ironpet-tasks"])
        run(rig, minutes: 10)
        await settle()
        XCTAssertEqual(userTexts.count, 1)
        XCTAssertEqual(turns.count, 1)
        XCTAssertTrue(history(rig).contains("skipped: skipped: previous run still in the chat"))
    }

    // S4
    func testANoOpReplyRemovesBothMessagesAndIsRecorded() async {
        let rig = wired()
        run(rig, minutes: 10)
        await settle()
        await reply("  ironpet-tasks: no changes\n")
        XCTAssertTrue(chat.items.isEmpty)
        XCTAssertTrue(history(rig).contains("ok: no changes"))
        XCTAssertFalse(chat.hasAutomationRun(id))
    }

    func testAnyOtherReplyStaysVisible() async {
        let rig = wired()
        run(rig, minutes: 10)
        await settle()
        await reply("ironpet-tasks: no changes, but I moved one task")
        XCTAssertEqual(userTexts.count, 1)
        XCTAssertEqual(assistantTexts, ["ironpet-tasks: no changes, but I moved one task"])
        XCTAssertEqual(chat.items.first?.origin, ChatSession.automationOrigin)
        XCTAssertTrue(history(rig).contains("ok: finished in the chat"))
    }

    func testANoOpLineAfterOtherWorkStaysVisible() async {
        let rig = wired()
        run(rig, minutes: 10)
        await settle()
        deliver[0](.assistant("Moved one task to done."))
        deliver[0](.assistant("ironpet-tasks: no changes"))
        deliver[0](.finished(error: nil))
        await settle()
        XCTAssertEqual(userTexts.count, 1)
        XCTAssertTrue(history(rig).contains("ok: finished in the chat"))
    }

    func testANoOpLineFromAnotherAutomationStaysVisible() async {
        _ = chat.submitFromAutomation("Check", automation: "other")
        await settle()
        await reply("ironpet-tasks: no changes")
        XCTAssertEqual(assistantTexts, ["ironpet-tasks: no changes"])
    }

    // S5
    func testTurningItOffSurvivesARestart() throws {
        let store = AutomationStore(paths: paths, defaults: { [] }, builtIns: [AutomationDefaults.reviewTasks()], watch: false)
        try store.update(id) { $0.enabled = false }
        let restarted = AutomationStore(paths: paths, defaults: { [] }, builtIns: [AutomationDefaults.reviewTasks()], watch: false)
        assertReview(restarted, enabled: false)
        XCTAssertEqual(restarted.automations.filter { $0.id == id }.count, 1)
    }
}
