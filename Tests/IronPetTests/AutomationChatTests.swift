import XCTest
@testable import IronPet

/// A `prompt` action goes into the user's chat. A prompt that uses poll item data stays in the restricted background run.
@MainActor
final class AutomationChatTests: AutomationTestCase {
    private var chat: ChatSession!
    private var turns: [ACPTurn] = []
    private var deliver: [(AgentEvent) -> Void] = []

    override func setUp() async throws {
        try await super.setUp()
        chat = ChatSession(restore: false)
        turns = []
        deliver = []
        chat.workspace = FileManager.default.temporaryDirectory
        chat.turnRunner = { [unowned self] turn, onEvent in
            turns.append(turn)
            deliver.append(onEvent)
        }
    }

    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    private func loop(_ id: String = "loop", prompt: String = "Check my tasks", by: String = "user") -> Automation {
        Automation(id: id, name: "Loop", trigger: .init(type: "interval", minutes: 5, clock: "wall"),
                   action: .init(type: "prompt", prompt: prompt, agent: "cursor", model: "x"), createdBy: by)
    }

    private func wired(_ list: [Automation]) -> (Rig, background: () -> [String]) {
        let rig = makeRig(list)
        var background: [String] = []
        rig.service.runPrompt = { _, prompt in background.append(prompt); return .success("answer") }
        rig.service.sendToChat = { [unowned self] id, message in chat.submitFromAutomation(message, automation: id) }
        rig.service.chatRunPending = { [unowned self] id in chat.hasAutomationRun(id) }
        chat.onAutomation = { [weak service = rig.service] id, event in service?.chatOutcome(id, event) }
        return (rig, { background })
    }

    private func history(_ rig: Rig, _ id: String = "loop") -> [String] {
        rig.service.history(id, limit: 20).map { "\($0["outcome"] ?? ""): \($0["output"] ?? "")" }
    }

    private var userTexts: [String] {
        chat.items.compactMap { if case .user(let text) = $0.kind { text } else { nil } }
    }

    // S1
    func testItSendsOneMessageWithAHeaderThroughTheChatNotTheBackgroundRunner() async {
        let (rig, background) = wired([loop()])
        run(rig, minutes: 5)
        await settle()
        XCTAssertEqual(userTexts, ["Automation \"Loop\" (every 5 min):\n\nCheck my tasks"])
        XCTAssertEqual(chat.items.first?.origin, ChatSession.automationOrigin)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.prompt, userTexts.first)
        XCTAssertTrue(background().isEmpty)
        XCTAssertNil(rig.notices.last("automation:loop"))
    }

    // S2
    func testItWaitsBehindTheUsersTurnAndLeavesTheDraftAlone() async {
        let (rig, _) = wired([loop()])
        chat.input = "first"
        chat.send()
        await settle()
        chat.input = "my draft"
        chat.attachments = [URL(fileURLWithPath: "/tmp/shot.png")]
        run(rig, minutes: 5)
        await settle()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(chat.queue.count, 1)
        XCTAssertEqual(chat.input, "my draft")
        XCTAssertEqual(chat.attachments, [URL(fileURLWithPath: "/tmp/shot.png")])
        deliver[0](.finished(error: nil))
        await settle()
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(userTexts.last, "Automation \"Loop\" (every 5 min):\n\nCheck my tasks")
        XCTAssertEqual(chat.input, "my draft")
    }

    // S3
    func testItSkipsATickWhileThePreviousRunIsQueuedOrRunning() async {
        let (rig, _) = wired([loop()])
        run(rig, minutes: 5)
        await settle()
        run(rig, minutes: 5)
        await settle()
        XCTAssertEqual(userTexts.count, 1)
        XCTAssertTrue(history(rig).contains("skipped: skipped: previous run still in the chat"))
        deliver[0](.finished(error: nil))
        await settle()
        run(rig, minutes: 5)
        await settle()
        XCTAssertEqual(userTexts.count, 2)
    }

    func testAtMostOneMessagePerAutomationIsQueued() async {
        let (rig, _) = wired([loop()])
        chat.input = "busy"
        chat.send()
        await settle()
        run(rig, minutes: 5)
        run(rig, minutes: 5)
        XCTAssertEqual(chat.queue.filter { $0.automation == "loop" }.count, 1)
    }

    // S4
    func testAPromptThatUsesItemDataStaysInTheRestrictedBackgroundRun() async {
        let a = loop(prompt: "Summarise {{item.title}}")
        let (rig, background) = wired([a])
        XCTAssertTrue(AutomationService.usesItemData("x {{ item.title }}"))
        XCTAssertFalse(AutomationService.usesItemData("{{name}} at {{now}}"))
        XCTAssertFalse(rig.service.runsInChat(a))
        rig.service.handle(.init(automations: [a], item: ["title": "T"], agentWorking: false))
        await until("the background run") { background() == ["Summarise T"] }
        XCTAssertTrue(chat.items.isEmpty)
        XCTAssertTrue(turns.isEmpty)
    }

    // S5
    func testAnAgentsChatPromptWaitsForApprovalAndAsksAgainWhenChanged() async {
        let (rig, _) = wired([loop(by: "agent:mcp")])
        XCTAssertTrue(rig.service.needsApproval(rig.store.automations[0]))
        run(rig, minutes: 5)
        await settle()
        XCTAssertTrue(chat.items.isEmpty)
        rig.service.approve("loop")
        await until("the approved run reaches the chat") { !self.userTexts.isEmpty }
        XCTAssertFalse(rig.service.needsApproval(rig.store.automations[0]))
        try? rig.store.update("loop") { $0.action.prompt = "Something else" }
        XCTAssertTrue(rig.service.needsApproval(rig.store.automations[0]))
    }

    // S6
    func testHistoryShowsSentToChatAndTheOutcome() async {
        let (rig, _) = wired([loop()])
        run(rig, minutes: 5)
        await settle()
        XCTAssertTrue(history(rig).contains("sent: sent to chat"))
        deliver[0](.assistant("a very long answer"))
        deliver[0](.finished(error: nil))
        await settle()
        XCTAssertTrue(history(rig).contains("ok: finished in the chat"))
        XCTAssertFalse(history(rig).contains { $0.contains("very long answer") })
        run(rig, minutes: 5)
        await settle()
        deliver[1](.finished(error: "boom"))
        await settle()
        XCTAssertTrue(history(rig).contains("failed: failed in the chat: boom"))
    }

    func testWithoutAFolderItUsesTheNoProjectFolderInsteadOfAskingForOne() async {
        let (rig, _) = wired([loop()])
        chat.workspace = nil
        run(rig, minutes: 5)
        await settle()
        XCTAssertEqual(chat.workspace, ChatSession.scratchWorkspace)
        XCTAssertFalse(chat.needsWorkspace)
        XCTAssertEqual(turns.count, 1)
    }
}
