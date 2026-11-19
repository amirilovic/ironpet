import XCTest
@testable import IronPet

/// The generic `quiet` reply of a `prompt` automation.
@MainActor
final class QuietReplyTests: AutomationTestCase {
    private var chat: ChatSession!
    private var h: ChatHarness!
    private var turns: [ACPTurn] = []
    private var deliver: [(AgentEvent) -> Void] = []

    override func setUp() async throws {
        try await super.setUp()
        h = ChatHarness(); chat = h.session
        turns = []
        deliver = []
        chat.workspace = FileManager.default.temporaryDirectory
        chat.turnRunner = { [unowned self] turn, onEvent in
            turns.append(turn)
            deliver.append(onEvent)
        }
    }

    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    private func wired(_ automations: [Automation]? = nil) -> Rig {
        let rig = makeRig(automations ?? [quietAutomation("watch-x", quiet: "ALL_CLEAR")])
        rig.service.sendToChat = { [unowned self] id, message in chat.submitFromAutomation(message, automation: id) }
        rig.service.chatRunPending = { [unowned self] id in chat.hasAutomationRun(id) }
        chat.quietReply = { [weak store = rig.store] id in store?.automations.first { $0.id == id }?.action.quiet }
        chat.onAutomation = { [weak service = rig.service] id, event in service?.chatOutcome(id, event) }
        return rig
    }

    private func history(_ rig: Rig, _ id: String) -> [String] {
        rig.service.history(id, limit: 20).map { "\($0["outcome"] ?? ""): \($0["output"] ?? "")" }
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

    func testToolCallsDoNotKeepAQuietTurn() async {
        let rig = wired([quietAutomation("watch-x", quiet: "ALL_CLEAR")])
        run(rig, minutes: 10)
        await settle()
        deliver[0](.toolStarted(id: "t1", summary: "Ran gh pr list"))
        deliver[0](.toolFinished(id: "t1", ok: true))
        deliver[0](.assistant("ALL_CLEAR"))
        deliver[0](.finished(error: nil))
        await settle()
        XCTAssertTrue(chat.items.isEmpty)
        XCTAssertTrue(history(rig, "watch-x").contains("ok: no changes"))
    }

    func testToolCallsWithAnotherReplyStayVisible() async {
        let rig = wired([quietAutomation("watch-x", quiet: "ALL_CLEAR")])
        run(rig, minutes: 10)
        await settle()
        deliver[0](.toolStarted(id: "t1", summary: "Ran gh pr list"))
        deliver[0](.toolFinished(id: "t1", ok: true))
        deliver[0](.assistant("ALL_CLEAR plus one PR needs you"))
        deliver[0](.finished(error: nil))
        await settle()
        XCTAssertFalse(chat.items.isEmpty)
    }

    func testAnAnsweredFormKeepsAQuietTurn() async {
        let rig = wired([quietAutomation("watch-x", quiet: "ALL_CLEAR")])
        run(rig, minutes: 10)
        await settle()
        chat.items.append(.init(kind: .form(ElicitationRecord(message: "Which?", skipped: true, lines: []))))
        deliver[0](.assistant("ALL_CLEAR"))
        deliver[0](.finished(error: nil))
        await settle()
        XCTAssertFalse(chat.items.isEmpty)
    }

    func testAnApprovalKeepsAQuietTurn() async {
        let rig = wired([quietAutomation("watch-x", quiet: "ALL_CLEAR")])
        run(rig, minutes: 10)
        await settle()
        chat.handlePermission(ACPToolCall(id: "p1", title: "Run rm -rf x", kind: "execute", rawInput: nil)) { _ in }
        deliver[0](.assistant("ALL_CLEAR"))
        deliver[0](.finished(error: nil))
        await settle()
        XCTAssertFalse(chat.items.isEmpty)
    }

    func testAMessageTypedDuringTheTurnIsNeverRemoved() async {
        let rig = wired([quietAutomation("watch-x", quiet: "ALL_CLEAR")])
        run(rig, minutes: 10)
        await settle()
        h.model.input = "hello"
        await h.model.sendNow()
        deliver[0](.assistant("ALL_CLEAR"))
        deliver[0](.finished(error: nil))
        await settle()
        // The automation turn is gone, and the queued message started as the next turn.
        XCTAssertEqual(chat.items.compactMap { if case .user(let t) = $0.kind { t } else { nil } }, ["hello"])
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

    func testQuietMustNotBeEmpty() {
        let bad = quietAutomation("watch-x", quiet: "  ")
        let json = try! JSONEncoder().encode(AutomationFile(automations: [bad]))
        XCTAssertTrue(AutomationValidator.parse(json).errors.contains { $0.contains("action.quiet") })
    }

}
