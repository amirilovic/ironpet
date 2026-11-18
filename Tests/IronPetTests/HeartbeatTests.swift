import XCTest
@testable import IronPet

/// The heartbeat checklist, the built-in Heartbeat automation, the generic `quiet` reply and the empty-checklist skip.
@MainActor
final class HeartbeatTests: AutomationTestCase {
    private var chat: ChatSession!
    private var turns: [ACPTurn] = []
    private var deliver: [(AgentEvent) -> Void] = []
    private var checklistReady = true
    private var heartbeatDir: URL!
    private var checklist: URL { heartbeatDir.appendingPathComponent("HEARTBEAT.md") }
    private let id = AutomationDefaults.heartbeatID

    override func setUp() async throws {
        try await super.setUp()
        heartbeatDir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-heartbeat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: heartbeatDir, withIntermediateDirectories: true)
        chat = ChatSession(restore: false)
        turns = []
        deliver = []
        checklistReady = true
        chat.workspace = FileManager.default.temporaryDirectory
        chat.turnRunner = { [unowned self] turn, onEvent in
            turns.append(turn)
            deliver.append(onEvent)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: heartbeatDir)
        try await super.tearDown()
    }

    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    private func wired(_ automations: [Automation]? = nil) -> Rig {
        let rig = makeRig(automations ?? [AutomationDefaults.heartbeat()])
        rig.service.sendToChat = { [unowned self] id, message in chat.submitFromAutomation(message, automation: id) }
        rig.service.chatRunPending = { [unowned self] id in chat.hasAutomationRun(id) }
        rig.service.checklistHasEntries = { [unowned self] in checklistReady }
        chat.quietReply = { [weak store = rig.store] id in store?.automations.first { $0.id == id }?.action.quiet }
        chat.onAutomation = { [weak service = rig.service] id, event in service?.chatOutcome(id, event) }
        return rig
    }

    private func history(_ rig: Rig, _ id: String? = nil) -> [String] {
        rig.service.history(id ?? self.id, limit: 20).map { "\($0["outcome"] ?? ""): \($0["output"] ?? "")" }
    }

    private var assistantTexts: [String] {
        chat.items.compactMap { if case .assistant(let text) = $0.kind { text } else { nil } }
    }

    private func reply(_ text: String) async {
        deliver[0](.assistant(text))
        deliver[0](.finished(error: nil))
        await settle()
    }

    private func quietAutomation(_ id: String, quiet: String?) -> Automation {
        Automation(id: id, name: id, trigger: .init(type: "interval", minutes: 10, clock: "wall"),
                   action: .init(type: "prompt", prompt: "Check the thing", quiet: quiet), createdBy: "user")
    }

    // S1
    func testDefaultsWriteTheChecklistOnceAndAddHeartbeatWithoutReviewTasks() throws {
        XCTAssertTrue(HeartbeatChecklist.ensureExists(at: checklist))
        let text = try String(contentsOf: checklist, encoding: .utf8)
        XCTAssertEqual(HeartbeatChecklist.entries(in: text).count, 3)
        XCTAssertTrue(text.contains("Resolve every pending task suggestion"))
        XCTAssertTrue(text.contains("Check every open task"))
        XCTAssertTrue(text.contains("screen activity since the last run"))

        let store = AutomationStore(paths: paths, defaults: { [] }, builtIns: AutomationDefaults.builtIns, watch: false)
        XCTAssertNil(store.automations.first { $0.id == "review-tasks" })
        let a = try XCTUnwrap(store.automations.first { $0.id == id })
        XCTAssertEqual(a.name, "Heartbeat")
        XCTAssertTrue(a.enabled)
        XCTAssertEqual(a.trigger.type, "interval")
        XCTAssertEqual(a.trigger.minutes, 15)
        XCTAssertEqual(a.trigger.clock, "wall")
        XCTAssertEqual(a.action.type, "prompt")
        XCTAssertEqual(a.action.prompt, "/heartbeat")
        XCTAssertEqual(a.action.quiet, "HEARTBEAT_OK")
        XCTAssertFalse(AutomationService(store: store, engine: AutomationEngine(env: clock.environment)).needsApproval(a))

        let edited = "- only this one\n"
        try edited.write(to: checklist, atomically: true, encoding: .utf8)
        XCTAssertFalse(HeartbeatChecklist.ensureExists(at: checklist))
        XCTAssertEqual(try Data(contentsOf: checklist), Data(edited.utf8), "an edited checklist stays byte for byte")
    }

    // S2
    func testAnExistingReviewTasksIsLeftAloneAndHeartbeatIsAddedNextToIt() throws {
        let review = Automation(id: "review-tasks", name: "Review tasks", trigger: .init(type: "interval", minutes: 10, clock: "wall"),
                                action: .init(type: "prompt", prompt: "/ironpet-tasks"), createdBy: "user",
                                note: "Asks the chat to review the task list. Skipped when no task is open, and hidden when nothing changed.")
        _ = AutomationStore(paths: paths, defaults: { [review] }, watch: false)
        let store = AutomationStore(paths: paths, defaults: { [] }, builtIns: AutomationDefaults.builtIns, watch: false)
        XCTAssertEqual(store.automations.first { $0.id == "review-tasks" }, review)
        XCTAssertNotNil(store.automations.first { $0.id == id })
        XCTAssertEqual(store.automations.map(\.id).prefix(2), ["review-tasks", id])
    }

    // S3
    func testAQuietReplyHidesTheTurnForAnyAutomation() async {
        let rig = wired([quietAutomation("watch-x", quiet: "ALL_CLEAR")])
        run(rig, minutes: 10)
        await settle()
        await reply("  ALL_CLEAR\n")
        XCTAssertTrue(chat.items.isEmpty)
        XCTAssertTrue(history(rig, "watch-x").contains("ok: no changes"))
        XCTAssertFalse(chat.hasAutomationRun("watch-x"))
    }

    func testAnyOtherReplyStaysVisible() async {
        let rig = wired([quietAutomation("watch-x", quiet: "ALL_CLEAR")])
        run(rig, minutes: 10)
        await settle()
        await reply("ALL_CLEAR, but I moved one task")
        XCTAssertEqual(assistantTexts, ["ALL_CLEAR, but I moved one task"])
        XCTAssertEqual(chat.items.first?.origin, ChatSession.automationOrigin)
        XCTAssertTrue(history(rig, "watch-x").contains("ok: finished in the chat"))
    }

    func testTheQuietLineAfterOtherWorkStaysVisible() async {
        let rig = wired([quietAutomation("watch-x", quiet: "ALL_CLEAR")])
        run(rig, minutes: 10)
        await settle()
        deliver[0](.assistant("Moved one task to done."))
        deliver[0](.assistant("ALL_CLEAR"))
        deliver[0](.finished(error: nil))
        await settle()
        XCTAssertFalse(chat.items.isEmpty)
        XCTAssertTrue(history(rig, "watch-x").contains("ok: finished in the chat"))
    }

    func testWithoutQuietNothingIsHidden() async {
        let rig = wired([quietAutomation("watch-x", quiet: nil)])
        run(rig, minutes: 10)
        await settle()
        await reply("ALL_CLEAR")
        XCTAssertEqual(assistantTexts, ["ALL_CLEAR"])
        XCTAssertTrue(history(rig, "watch-x").contains("ok: finished in the chat"))
    }

    func testAQuietLineFromAnotherAutomationStaysVisible() async {
        _ = wired([quietAutomation("watch-x", quiet: "ALL_CLEAR")])
        _ = chat.submitFromAutomation("Check", automation: "other")
        await settle()
        await reply("ALL_CLEAR")
        XCTAssertEqual(assistantTexts, ["ALL_CLEAR"])
    }

    func testHeartbeatOKHidesAHeartbeatRun() async {
        let rig = wired()
        run(rig, minutes: 15)
        await settle()
        XCTAssertEqual(turns.count, 1)
        await reply("HEARTBEAT_OK")
        XCTAssertTrue(chat.items.isEmpty)
        XCTAssertTrue(history(rig).contains("ok: no changes"))
    }

    func testQuietMustNotBeEmpty() {
        let bad = quietAutomation("watch-x", quiet: "  ")
        let json = try! JSONEncoder().encode(AutomationFile(automations: [bad]))
        XCTAssertTrue(AutomationValidator.parse(json).errors.contains { $0.contains("action.quiet") })
    }

    // S4
    func testAnEmptyChecklistSkipsTheRun() async throws {
        XCTAssertFalse(HeartbeatChecklist.hasEntries(at: checklist), "a missing file has no entries")
        try "# Heartbeat\n\n<!-- nothing yet -->\n<!--\n- hidden\n-->\n\n".write(to: checklist, atomically: true, encoding: .utf8)
        XCTAssertFalse(HeartbeatChecklist.hasEntries(at: checklist), "comments and blank lines are not entries")
        let rig = wired()
        checklistReady = false
        run(rig, minutes: 15)
        await settle()
        XCTAssertTrue(chat.items.isEmpty)
        XCTAssertTrue(turns.isEmpty)
        XCTAssertTrue(history(rig).contains("skipped: skipped: empty checklist"))
    }

    func testOneEntryRunsEvenWithNoOpenTask() async throws {
        try "# Heartbeat\n- Check the deploy\n".write(to: checklist, atomically: true, encoding: .utf8)
        XCTAssertTrue(HeartbeatChecklist.hasEntries(at: checklist))
        let rig = wired()
        run(rig, minutes: 15)
        await settle()
        XCTAssertEqual(turns.count, 1)
        XCTAssertFalse(history(rig).contains { $0.contains("empty checklist") })
    }

    func testItSendsOnePromptAndNotASecondWhileItRuns() async {
        let rig = wired()
        run(rig, minutes: 15)
        await settle()
        let users = chat.items.compactMap { if case .user(let text) = $0.kind { text } else { nil } }
        XCTAssertEqual(users, ["Automation \"Heartbeat\" (every 15 min):\n\n/heartbeat"])
        run(rig, minutes: 15)
        await settle()
        XCTAssertEqual(turns.count, 1)
        XCTAssertTrue(history(rig).contains("skipped: skipped: previous run still in the chat"))
    }

    func testTurningItOffSurvivesARestart() throws {
        let store = AutomationStore(paths: paths, defaults: { [] }, builtIns: AutomationDefaults.builtIns, watch: false)
        try store.update(id) { $0.enabled = false }
        let restarted = AutomationStore(paths: paths, defaults: { [] }, builtIns: AutomationDefaults.builtIns, watch: false)
        XCTAssertEqual(restarted.automations.first { $0.id == id }?.enabled, false)
        XCTAssertEqual(restarted.automations.filter { $0.id == id }.count, 1)
    }
}
