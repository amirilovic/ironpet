import XCTest
@testable import IronPet

/// A `prompt` action with `session` new or own runs in its own thread instead of the open chat.
@MainActor
final class AutomationSessionTests: AutomationTestCase {
    private var threads: URL!
    private var savedThreads: URL!
    private var turns: [ACPTurn] = []
    private var nextSession = 0
    private var reply = "Checked 3 mails."

    override func setUp() async throws {
        try await super.setUp()
        savedThreads = ThreadStore.directory
        threads = dir.appendingPathComponent("threads")
        ThreadStore.directory = threads
        turns = []
        nextSession = 0
        reply = "Checked 3 mails."
    }

    override func tearDown() async throws {
        ThreadStore.directory = savedThreads
        try await super.tearDown()
    }

    /// A scripted agent. A turn with `resume` keeps that session id, like the real `session/load`.
    private var scripted: AutomationSession.TurnRunner {
        { [unowned self] turn, emit in
            turns.append(turn)
            if turn.resume == nil {
                nextSession += 1
                emit(.session("s\(nextSession)"))
            }
            emit(.toolStarted(id: "t", summary: "Run gh"))
            emit(.toolFinished(id: "t", ok: true))
            emit(.assistant(reply))
            emit(.finished(error: nil))
        }
    }

    private func job(session: String? = "new", quiet: String? = nil, allowed: [String]? = nil, denied: [String]? = nil,
                     model: String? = nil, prompt: String = "/am-check-emails 1") -> Automation {
        Automation(id: "mail", name: "Check mail", trigger: .init(type: "interval", minutes: 60, clock: "wall"),
                   action: .init(type: "prompt", prompt: prompt, agent: "cursor", model: model, quiet: quiet, session: session,
                                 allowedTools: allowed, disallowedTools: denied))
    }

    private func run(_ a: Automation, now: Date = Date()) async -> Result<String, AutomationError> {
        await AutomationSession.run(a, prompt: a.action.prompt ?? "", workspace: dir.appendingPathComponent("ws"), turnRunner: scripted, now: now)
    }

    // S1
    func testNoSessionAndChatKeepTheChatBehaviour() async {
        for session in [nil, "chat"] as [String?] {
            let rig = makeRig([job(session: session)])
            var sessionRuns = 0
            var chatMessages: [String] = []
            rig.service.runSession = { _, _ in sessionRuns += 1; return .success("x") }
            rig.service.sendToChat = { _, message in chatMessages.append(message); return true }
            run(rig, minutes: 60)
            XCTAssertEqual(sessionRuns, 0)
            XCTAssertEqual(chatMessages.count, 1, "session \(session ?? "nil") posts into the chat")
        }
    }

    // S2
    func testNewSessionMakesASeparateMarkedThreadEachRunAndLeavesTheChatAlone() async {
        let rig = makeRig([job()])
        var chatMessages: [String] = []
        rig.service.sendToChat = { _, message in chatMessages.append(message); return true }
        rig.service.runSession = { [unowned self] a, prompt in await AutomationSession.run(a, prompt: prompt, workspace: dir, turnRunner: scripted) }
        run(rig, minutes: 60)
        await until("first run") { ThreadStore.recent().count == 1 }
        run(rig, minutes: 60)
        await until("second run") { ThreadStore.recent().count == 2 }
        XCTAssertEqual(Set(ThreadStore.recent().map(\.id)), ["s1", "s2"])
        XCTAssertTrue(ThreadStore.recent().allSatisfy { $0.automation == "mail" && $0.automationName == "Check mail" && $0.isAutomationRun })
        XCTAssertEqual(chatMessages, [])
        XCTAssertEqual(turns.map(\.prompt), ["/am-check-emails 1", "/am-check-emails 1"], "the slash skill goes in verbatim")
        let thread = ThreadStore.load("s1")
        XCTAssertEqual(thread?.items.first?.origin, ChatSession.automationOrigin)
        XCTAssertEqual(thread?.items.count, 3, "prompt, tool row and reply")
    }

    // S3
    func testOwnSessionResumesTheSameThreadThenStartsFreshAfterTheLimit() async {
        let a = job(session: "own")
        // Thread files store whole seconds, so each run gets its own second.
        let start = Date()
        for i in 0..<2 { _ = await run(a, now: start.addingTimeInterval(Double(i) * 10)) }
        XCTAssertEqual(turns.map { $0.resume }, [nil, "s1"], "the second run resumes the first")
        XCTAssertEqual(ThreadStore.recent().map(\.id), ["s1"])
        XCTAssertEqual(ThreadStore.load("s1")?.runs, 2)
        XCTAssertEqual(ThreadStore.load("s1")?.items.count, 6)

        var full = try! XCTUnwrap(ThreadStore.load("s1"))
        full.runs = AutomationSession.ownRunLimit
        ThreadStore.save(full)
        _ = await run(a, now: start.addingTimeInterval(30))
        XCTAssertNil(turns.last?.resume, "after the limit the run starts a fresh session")
        XCTAssertEqual(ThreadStore.load("s2")?.runs, 1)
        _ = await run(a, now: start.addingTimeInterval(40))
        XCTAssertEqual(turns.last?.resume, "s2")
    }

    // S4
    func testToolListsAndModelReachTheAgentAndNoModelForcesNothing() async {
        _ = await run(job(allowed: ["Bash(gh:*)"], denied: ["WebFetch", "Bash(rm:*)"], model: "haiku"))
        XCTAssertEqual(turns.last?.allowedTools, ["Bash(gh:*)"])
        XCTAssertEqual(turns.last?.disallowedTools, ["WebFetch", "Bash(rm:*)"])
        XCTAssertEqual(turns.last?.model, "haiku")
        let meta = ACPBackend.toolRulesMeta(turns.last!)
        let options = ((meta?["claudeCode"] as? [String: Any])?["options"]) as? [String: Any]
        XCTAssertEqual(options?["allowedTools"] as? [String], ["Bash(gh:*)"])
        XCTAssertEqual(options?["disallowedTools"] as? [String], ["WebFetch", "Bash(rm:*)"])

        _ = await run(job())
        XCTAssertNil(turns.last?.model)
        XCTAssertNil(ACPBackend.toolRulesMeta(turns.last!))
    }

    // S5
    func testQuietReplyShowsNothingButStaysInHistoryAndThread() async {
        reply = "NOTHING_NEW"
        let rig = makeRig([job(quiet: "NOTHING_NEW")])
        rig.service.runSession = { [unowned self] a, prompt in await AutomationSession.run(a, prompt: prompt, workspace: dir, turnRunner: scripted) }
        run(rig, minutes: 60)
        await until("the quiet run") { rig.service.history("mail", limit: 5).first?["output"] as? String == "no changes" }
        XCTAssertNil(rig.notices.last("automation:mail"))
        XCTAssertEqual(ThreadStore.recent().count, 1)

        reply = "2 new mails"
        run(rig, minutes: 60)
        await until("the loud run") { rig.notices.last("automation:mail") != nil }
        XCTAssertEqual(rig.notices.last("automation:mail")?.body, "2 new mails")
    }

    func testFailureIsRecordedInTheThread() async {
        let failing: AutomationSession.TurnRunner = { _, emit in emit(.session("bad")); emit(.finished(error: "boom")) }
        let result = await AutomationSession.run(job(), prompt: "x", workspace: dir, turnRunner: failing)
        guard case .failure(let error) = result else { return XCTFail("expected a failure") }
        XCTAssertEqual(error.message, "boom")
        if case .error(let text)? = ThreadStore.load("bad")?.items.last?.kind { XCTAssertEqual(text, "boom") } else { XCTFail("no error row") }
    }

    func testAutomationThreadsDoNotCrowdOutTheUsersOwn() {
        for i in 0..<8 {
            ThreadStore.save(ChatThread(id: "a\(i)", title: "A", workspace: "/tmp", updatedAt: Date(), items: [], agent: "cursor", automation: "mail"))
        }
        ThreadStore.save(ChatThread(id: "mine", title: "Mine", workspace: "/tmp", updatedAt: Date().addingTimeInterval(-100), items: [], agent: "cursor"))
        let ids = ThreadStore.recent().map(\.id)
        XCTAssertEqual(ids.filter { $0.hasPrefix("a") }.count, 5)
        XCTAssertTrue(ids.contains("mine"))
        ThreadStore.prune(automation: "mail", keep: 2)
        XCTAssertEqual(ThreadStore.recent(limit: 50, automationLimit: 50).filter(\.isAutomationRun).count, 2)
    }

    func testItemDataKeepsAPromptInTheReadOnlyBackgroundRun() {
        let rig = makeRig([job(prompt: "Look at {{item.title}}")])
        rig.service.runSession = { _, _ in .success("") }
        XCTAssertFalse(rig.service.runsInSession(rig.store.automations[0]))
        XCTAssertTrue(rig.service.runsInSession(job()))
        XCTAssertFalse(rig.service.runsInSession(job(session: "chat")))
    }

    // S6
    func testValidationAndApproval() async {
        func errors(_ action: [String: Any]) async -> String? {
            let rig = makeRig()
            let args: [String: Any] = ["id": "m", "name": "M", "trigger": ["type": "interval", "minutes": 60, "clock": "wall"], "action": action]
            if case .failure(let error) = await rig.service.call("create", args, by: "agent:mcp") { return error.message }
            return nil
        }
        let bad = await errors(["type": "prompt", "prompt": "x", "session": "thread:abc"])
        XCTAssertTrue(bad?.contains("action.session must be one of chat, new, own") == true, bad ?? "no error")
        let notArray = await errors(["type": "prompt", "prompt": "x", "session": "new", "disallowedTools": "Bash"])
        XCTAssertNotNil(notArray)
        let notStrings = await errors(["type": "prompt", "prompt": "x", "session": "new", "allowedTools": [1, 2]])
        XCTAssertNotNil(notStrings)
        let withoutSession = await errors(["type": "prompt", "prompt": "x", "allowedTools": ["Bash"]])
        XCTAssertTrue(withoutSession?.contains("only applies when action.session is new or own") == true, withoutSession ?? "no error")
        let good = await errors(["type": "prompt", "prompt": "x", "session": "own", "allowedTools": ["Bash(gh:*)"], "disallowedTools": ["WebFetch"]])
        XCTAssertNil(good)

        let rig = makeRig()
        _ = await rig.service.call("create", ["id": "m", "name": "M", "trigger": ["type": "interval", "minutes": 60, "clock": "wall"],
                                              "action": ["type": "prompt", "prompt": "x"]], by: "agent:mcp")
        rig.service.approve("m")
        XCTAssertFalse(rig.service.needsApproval(rig.store.automations[0]))
        _ = await rig.service.call("update", ["id": "m", "changes": ["action": ["session": "new"]]], by: "agent:mcp")
        XCTAssertTrue(rig.service.needsApproval(rig.store.automations[0]), "a new session mode needs Approve again")
        rig.service.approve("m")
        _ = await rig.service.call("update", ["id": "m", "changes": ["action": ["disallowedTools": ["Bash"]]]], by: "agent:mcp")
        XCTAssertTrue(rig.service.needsApproval(rig.store.automations[0]), "changed tool lists need Approve again")
    }

    func testAnExistingPromptKeepsItsApprovalHash() {
        let old = Automation(id: "p", name: "P", trigger: .init(type: "interval", minutes: 5, clock: "wall"),
                             action: .init(type: "prompt", prompt: "hi", agent: "a", model: "m"))
        XCTAssertEqual(old.riskText, "prompt:hi|a|m")
        var chat = old
        chat.action.session = "chat"
        XCTAssertEqual(chat.riskText, old.riskText)
    }
}
