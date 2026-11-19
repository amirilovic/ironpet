import XCTest
@testable import IronPet

/// An agent process whose turns follow a script. `hold` keeps a turn open until `release()` or `cancel()`.
@MainActor
private final class FakeJobAgent: JobAgent {
    var onPermission: ((ACPToolCall, @escaping (ApprovalDecision) -> Void) -> Void)?
    var turns: [ACPTurn] = []
    var hold = false
    var permission: ACPToolCall?
    var decisions: [ApprovalDecision] = []
    var reply = "Fixed the flaky test. It waited on a fixed sleep."
    var error: String?
    /// The first turn fails with this; later ones use `error`.
    var firstError: String?
    /// Like an agent still starting: `cancel()` has no effect until the session is up, only `shutdown()` ends it.
    var slowStart = false
    /// Like a stuck agent: `cancel()` does nothing.
    var ignoresCancel = false
    private var startGate: CheckedContinuation<Void, Never>?
    private(set) var cancelled = false
    private(set) var shutDown = false
    private var gate: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { gate != nil }

    func runTurn(_ turn: ACPTurn, onEvent: @escaping (AgentEvent) -> Void) async {
        turns.append(turn)
        if slowStart {
            await withCheckedContinuation { startGate = $0 }
            if shutDown { return onEvent(.finished(error: "The agent closed")) }
        }
        onEvent(.session("session-1"))
        onEvent(.toolStarted(id: "t\(turns.count)", summary: "Run swift test"))
        if let call = permission {
            permission = nil
            let decision = await withCheckedContinuation { continuation in
                onPermission?(call) { continuation.resume(returning: $0) }
            }
            decisions.append(decision)
        }
        if hold, !cancelled { await withCheckedContinuation { gate = $0 } }
        if shutDown { return onEvent(.finished(error: "The agent closed")) }
        onEvent(.toolFinished(id: "t\(turns.count)", ok: true))
        if cancelled { return onEvent(.finished(error: nil)) }
        onEvent(.assistant(reply))
        let failure = turns.count == 1 ? firstError ?? error : error
        onEvent(.finished(error: failure))
    }

    /// Ends the turn that waits. Later turns wait too only with `holdingNext`.
    func release(holdingNext: Bool = false) {
        hold = holdingNext
        gate?.resume()
        gate = nil
    }

    func cancel() {
        guard startGate == nil, !ignoresCancel else { return }
        cancelled = true
        gate?.resume()
        gate = nil
    }

    func shutdown() {
        shutDown = true
        startGate?.resume()
        startGate = nil
        gate?.resume()
        gate = nil
    }
}

@MainActor
final class JobTests: XCTestCase {
    private var folder: URL!
    private var threads: URL!
    private var savedThreads: URL!
    private var database: Database!
    private var tasks: TaskStore!
    private var agents: [FakeJobAgent] = []
    private var asked: [(id: String, title: String, decide: (Bool) -> Void)] = []
    private var cleared: [String] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString)")
        threads = folder.appendingPathComponent("threads")
        try FileManager.default.createDirectory(at: threads, withIntermediateDirectories: true)
        savedThreads = ThreadStore.directory
        ThreadStore.directory = threads
        database = Database.open(path: nil, migrations: TaskStore.migrations + JobService.migrations).database
        tasks = TaskStore(database: database)
        agents = []
        asked = []
        cleared = []
    }

    override func tearDown() async throws {
        ThreadStore.directory = savedThreads
        try? FileManager.default.removeItem(at: folder)
    }

    private func service(max: Int = 3, configure: @escaping (FakeJobAgent) -> Void = { _ in }) -> JobService {
        let service = JobService(database: database, tasks: tasks)
        service.currentAgent = { (AgentCatalog.all[0], "fast-model") }
        service.maxRunning = { max }
        service.preamble = { _ in "PREAMBLE" }
        service.makeAgent = { [unowned self] _ in
            let agent = FakeJobAgent()
            configure(agent)
            agents.append(agent)
            return agent
        }
        service.askApproval = { [unowned self] id, _, title, _, decide in asked.append((id, title, decide)) }
        service.clearApproval = { [unowned self] id in cleared.append(id) }
        return service
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func testVoiceJobWaitsForThePetToAnswerThenItsHold() async throws {
        let jobs = service()
        jobs.voiceHoldSeconds = 0.1
        let job = try jobs.start(title: "Fix the flaky test", prompt: "Fix it", folder: folder, fromVoice: true)
        XCTAssertTrue(jobs.isFromVoice(job.id))
        XCTAssertEqual(jobs.job(job.id)?.state, .queued)
        try await Task.sleep(for: .milliseconds(250))
        // Still held: the pet has not said what it started.
        XCTAssertTrue(agents.isEmpty)
        jobs.releaseVoiceHolds()
        XCTAssertTrue(agents.isEmpty)
        await until { jobs.job(job.id)?.state == .done }
        XCTAssertEqual(agents.count, 1)
    }

    func testAnUnreleasedVoiceJobRunsAfterTheLimit() async throws {
        let jobs = service()
        jobs.voiceHoldLimit = 0.1
        let job = try jobs.start(title: "Fix the flaky test", prompt: "Fix it", folder: folder, fromVoice: true)
        await until { jobs.job(job.id)?.state == .done }
        XCTAssertEqual(agents.count, 1)
    }

    func testAVoiceFollowUpOnAFinishedJobIsHeldToo() async throws {
        let jobs = service()
        let job = try jobs.start(title: "Fix the flaky test", prompt: "Fix it", folder: folder)
        await until { jobs.job(job.id)?.state == .done }
        XCTAssertFalse(jobs.isFromVoice(job.id))
        let followed = try jobs.followUp(job.id, message: "Also fix the other one", fromVoice: true)
        XCTAssertEqual(followed.state, .queued)
        XCTAssertTrue(jobs.isFromVoice(job.id))
        let stopped = try XCTUnwrap(jobs.cancelHeldVoiceJob())
        XCTAssertEqual(stopped.id, job.id)
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertEqual(agents.count, 1)
    }

    func testCancelThatStopsAHeldVoiceJobBeforeItRuns() async throws {
        let jobs = service()
        jobs.voiceHoldSeconds = 0.2
        let plain = try jobs.start(title: "Plain job", prompt: "Do it", folder: folder)
        let voice = try jobs.start(title: "Voice job", prompt: "Do it", folder: folder, fromVoice: true)
        XCTAssertFalse(jobs.isFromVoice(plain.id))
        let stopped = try XCTUnwrap(jobs.cancelHeldVoiceJob())
        XCTAssertEqual(stopped.id, voice.id)
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(jobs.cancelHeldVoiceJob())
        jobs.releaseVoiceHolds()
        try await Task.sleep(for: .milliseconds(300))
        // Only the plain job ever got an agent.
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(jobs.job(voice.id)?.state, .stopped)
    }

    func testJobRunsTracksATaskAndSavesItsThread() async throws {
        let jobs = service()
        let job = try jobs.start(title: "Fix the flaky test", prompt: "Fix LoginTests.testRetry", folder: folder)
        let task = try XCTUnwrap(job.task.flatMap(tasks.task))
        XCTAssertEqual(task.status, .inProgress)
        XCTAssertEqual(task.source, .agent)

        await until { jobs.job(job.id)?.state == .done }
        let done = try XCTUnwrap(jobs.job(job.id))
        XCTAssertEqual(done.summary, "Fixed the flaky test.")
        XCTAssertEqual(done.thread, "session-1")
        XCTAssertEqual(done.lastStep, "Run swift test")
        XCTAssertEqual(agents[0].turns.first?.preamble, "PREAMBLE")
        XCTAssertEqual(agents[0].turns.first?.model, "fast-model")
        XCTAssertEqual(agents[0].turns.first?.workspace.path, folder.standardizedFileURL.path)
        XCTAssertTrue(agents[0].shutDown)

        let closed = try XCTUnwrap(tasks.task(task.id))
        XCTAssertEqual(closed.status, .done)
        XCTAssertTrue(closed.links.contains { $0.kind == .thread && $0.ref == "session-1" })
        let thread = try XCTUnwrap(ThreadStore.load("session-1"))
        XCTAssertEqual(thread.job, job.id)
        XCTAssertEqual(thread.title, "Fix the flaky test")
        XCTAssertTrue(thread.items.contains { if case .assistant(let text) = $0.kind { text.hasPrefix("Fixed") } else { false } })
    }

    func testFailedJobMarksItsTaskNeedsYou() async throws {
        let jobs = service { $0.error = "The agent crashed" }
        let job = try jobs.start(title: "Fix it", prompt: "Fix it", folder: folder)
        await until { jobs.job(job.id)?.state == .failed }
        XCTAssertEqual(jobs.job(job.id)?.error, "The agent crashed")
        XCTAssertEqual(job.task.flatMap(tasks.task)?.status, .needsYou)
        XCTAssertEqual(jobs.job(job.id)?.agentSession?.status, .failed)
    }

    func testJobsPastTheLimitWaitInLine() async throws {
        let jobs = service(max: 2) { $0.hold = true }
        let ids = try (1...3).map { try jobs.start(title: "Job \($0)", prompt: "Do \($0)", folder: folder).id }
        await until { agents.count == 2 }
        XCTAssertEqual(ids.map { jobs.job($0)?.state }, [.running, .running, .queued])
        XCTAssertEqual(jobs.job(ids[2])?.agentSession?.detail, "Waiting to start")

        agents[0].release()
        await until { jobs.job(ids[2])?.state == .running }
        XCTAssertEqual(jobs.job(ids[0])?.state, .done)
        XCTAssertEqual(agents.count, 3)
    }

    func testStopCancelsARunningJobAndDropsAQueuedOne() async throws {
        let jobs = service(max: 1) { $0.hold = true }
        let first = try jobs.start(title: "First", prompt: "One", folder: folder)
        let second = try jobs.start(title: "Second", prompt: "Two", folder: folder)
        await until { agents.count == 1 }

        try jobs.stop(second.id)
        XCTAssertEqual(jobs.job(second.id)?.state, .stopped)
        XCTAssertEqual(second.task.flatMap(tasks.task)?.status, .done)

        try jobs.stop(first.id)
        await until { jobs.job(first.id)?.state == .stopped }
        XCTAssertTrue(agents[0].cancelled)
        XCTAssertEqual(agents.count, 1, "a stopped job never starts")
        XCTAssertNil(jobs.job(first.id)?.agentSession, "a stopped job leaves the Agents section")
    }

    func testStopWhileTheAgentIsStartingClosesItsProcess() async throws {
        let jobs = service { $0.slowStart = true }
        jobs.stopGrace = 0.05
        let job = try jobs.start(title: "Fix", prompt: "Fix it", folder: folder)
        await until { agents.first?.turns.count == 1 }
        try jobs.stop(job.id)
        await until { jobs.job(job.id)?.state == .stopped }
        XCTAssertTrue(agents[0].shutDown)
        XCTAssertNil(jobs.job(job.id)?.lastStep, "nothing ran after the stop")
    }

    func testAStuckTurnTimesOutAndFreesItsSlot() async throws {
        let jobs = service(max: 1) { agent in
            agent.hold = true
            agent.ignoresCancel = true
        }
        jobs.turnTimeout = 0.05
        jobs.stopGrace = 0.05
        let job = try jobs.start(title: "Stuck", prompt: "Hang", folder: folder)
        let next = try jobs.start(title: "Next", prompt: "Go", folder: folder)
        await until { jobs.job(job.id)?.state == .failed }
        XCTAssertTrue(agents[0].shutDown)
        XCTAssertTrue(jobs.job(job.id)?.error?.contains("did not finish") == true)
        await until { jobs.job(next.id)?.state == .running }
        agents[1].shutdown()
    }

    func testQuittingClosesEveryJobsProcess() async throws {
        let jobs = service { $0.hold = true }
        _ = try jobs.start(title: "One", prompt: "1", folder: folder)
        _ = try jobs.start(title: "Two", prompt: "2", folder: folder)
        await until { agents.count == 2 && agents.allSatisfy(\.isWaiting) }
        jobs.shutdownAll()
        XCTAssertTrue(agents.allSatisfy(\.shutDown))
        await until { jobs.running.isEmpty }
    }

    func testAFollowUpWaitsWhileTheChatUsesTheSession() async throws {
        let jobs = service()
        let job = try jobs.start(title: "Fix", prompt: "Fix it", folder: folder)
        await until { jobs.job(job.id)?.state == .done }
        jobs.sessionBusy = { $0 == "session-1" }
        XCTAssertThrowsError(try jobs.followUp(job.id, message: "More")) { error in
            XCTAssertTrue((error as? JobError)?.message.contains("chat is using") == true)
        }
        XCTAssertEqual(agents.count, 1)
    }

    func testAStoppedJobDeniesPermissionsThatArriveLate() async throws {
        let call = ACPToolCall(id: "1", title: "Run", kind: "execute", rawInput: ["command": "swift test"])
        let jobs = service { $0.hold = true }
        let job = try jobs.start(title: "Fix", prompt: "Fix it", folder: folder)
        await until { agents.first?.isWaiting == true }
        try jobs.stop(job.id)
        var decision: ApprovalDecision?
        agents[0].onPermission?(call) { decision = $0 }
        XCTAssertEqual(decision?.allow, false)
        await until { jobs.job(job.id)?.state == .stopped }
    }

    func testAFollowUpStillRunsAfterAFailedTurn() async throws {
        let jobs = service { agent in
            agent.firstError = "Tests failed"
            agent.hold = true
        }
        let job = try jobs.start(title: "Fix", prompt: "Fix it", folder: folder)
        await until { agents.first?.isWaiting == true }
        try jobs.followUp(job.id, message: "Try again with Node 22")
        agents[0].release()
        await until { jobs.job(job.id)?.state.isActive == false }
        XCTAssertEqual(agents[0].turns.map(\.prompt), ["Fix it", "Try again with Node 22"])
        XCTAssertEqual(jobs.job(job.id)?.state, .done)
    }

    func testDestructiveCommandWaitsForAClick() async throws {
        let call = ACPToolCall(id: "1", title: "Run", kind: "execute", rawInput: ["command": "rm -rf build"])
        let jobs = service { $0.permission = call }
        let job = try jobs.start(title: "Clean", prompt: "Clean the build", folder: folder)
        await until { asked.count == 1 }
        XCTAssertEqual(jobs.job(job.id)?.state, .needsApproval)
        XCTAssertEqual(jobs.job(job.id)?.agentSession?.status, .needsInput)

        asked[0].decide(false)
        await until { jobs.job(job.id)?.state == .done }
        XCTAssertEqual(agents[0].decisions.map(\.allow), [false])
        XCTAssertTrue(cleared.isEmpty, "an answered bubble is already gone")
    }

    func testSafeCommandRunsWithoutAsking() async throws {
        let call = ACPToolCall(id: "1", title: "Run", kind: "execute", rawInput: ["command": "swift test"])
        let jobs = service { $0.permission = call }
        let job = try jobs.start(title: "Test", prompt: "Run the tests", folder: folder)
        await until { jobs.job(job.id)?.state == .done }
        XCTAssertTrue(asked.isEmpty)
        XCTAssertEqual(agents[0].decisions.map(\.allow), [true])
    }

    func testStoppingAJobDeniesItsWaitingApproval() async throws {
        let call = ACPToolCall(id: "1", title: "Run", kind: "execute", rawInput: ["command": "git push --force"])
        let jobs = service { $0.permission = call }
        let job = try jobs.start(title: "Push", prompt: "Push it", folder: folder)
        await until { asked.count == 1 }
        try jobs.stop(job.id)
        await until { jobs.job(job.id)?.state == .stopped }
        XCTAssertEqual(cleared, [asked[0].id])
        XCTAssertEqual(agents[0].decisions.map(\.allow), [false])
    }

    func testFollowUpRunsAfterTheCurrentTurnInTheSameSession() async throws {
        let jobs = service { $0.hold = true }
        let job = try jobs.start(title: "Fix", prompt: "Fix it", folder: folder)
        await until { agents.count == 1 }
        try jobs.followUp(job.id, message: "Also update the README")
        agents[0].release()
        await until { jobs.job(job.id)?.state == .done }
        XCTAssertEqual(agents[0].turns.map(\.prompt), ["Fix it", "Also update the README"])
        XCTAssertNil(agents[0].turns[1].preamble)
        XCTAssertEqual(agents[0].turns[1].resume, "session-1")
    }

    func testTheThreadShowsEachPromptAsSoonAsItsTurnStarts() async throws {
        let jobs = service { $0.hold = true }
        var saved: [ChatThread] = []
        jobs.onThreadSaved = { saved.append($0) }
        let job = try jobs.start(title: "Fix", prompt: "Fix it", folder: folder)
        await until { agents.count == 1 }
        try jobs.followUp(job.id, message: "Also update the README")
        await until { agents[0].isWaiting }
        agents[0].release(holdingNext: true)
        await until { agents[0].turns.count == 2 }
        let texts = saved.last?.items.compactMap { item -> String? in if case .user(let text) = item.kind { text } else { nil } }
        XCTAssertEqual(texts, ["Fix it", "Also update the README"], "the follow-up is in the thread while its turn runs")
        agents[0].release()
        await until { jobs.job(job.id)?.state == .done }
    }

    func testFollowUpOnAFinishedJobResumesItsSession() async throws {
        let jobs = service()
        let job = try jobs.start(title: "Fix", prompt: "Fix it", folder: folder)
        await until { jobs.job(job.id)?.state == .done }
        try jobs.followUp(job.id, message: "Now add a test")
        await until { agents.count == 2 && jobs.job(job.id)?.state == .done }
        XCTAssertEqual(agents[1].turns.map(\.prompt), ["Now add a test"])
        XCTAssertEqual(agents[1].turns[0].resume, "session-1")
        XCTAssertNil(agents[1].turns[0].preamble)
        let thread = try XCTUnwrap(ThreadStore.load("session-1"))
        XCTAssertEqual(thread.items.filter { if case .user = $0.kind { true } else { false } }.count, 2, "the thread keeps both turns")
    }

    func testJobsRunningAtQuitAreInterruptedOnLaunch() async throws {
        let jobs = service { $0.hold = true }
        let job = try jobs.start(title: "Long", prompt: "Long work", folder: folder)
        await until { agents.count == 1 }

        let relaunched = service()
        XCTAssertEqual(relaunched.job(job.id)?.state, .interrupted)
        XCTAssertNil(relaunched.job(job.id)?.agentSession)
        XCTAssertEqual(job.task.flatMap(tasks.task)?.status, .backlog)
        agents[0].release()
    }

    func testStartRejectsBadInput() throws {
        let jobs = service()
        XCTAssertThrowsError(try jobs.start(title: " ", prompt: "x", folder: folder))
        XCTAssertThrowsError(try jobs.start(title: "x", prompt: " ", folder: folder))
        XCTAssertThrowsError(try jobs.start(title: "x", prompt: "x", folder: folder.appendingPathComponent("missing")))
        XCTAssertThrowsError(try jobs.start(title: String(repeating: "a", count: Job.titleLimit + 1), prompt: "x", folder: folder))
        XCTAssertTrue(jobs.jobs.isEmpty)
        XCTAssertTrue(tasks.tasks.isEmpty)
    }

    func testJobRowsAnnounceOnceSurviveTheSweepAndStayAcknowledged() {
        let store = SessionStore()
        var announced: [AgentStatus] = []
        store.onAttention = { announced.append($0.status) }
        var job = Job(id: "job-abc123", title: "Fix", prompt: "Fix it", folder: "/tmp/ironpet", agent: "claude", state: .running,
                      created: Date(timeIntervalSince1970: 0), started: Date(timeIntervalSince1970: 0))
        let key = Job.sessionKey(job.id)
        store.setJob(key, job.agentSession)
        store.sweep(now: Date(timeIntervalSince1970: 10 * 3_600))
        XCTAssertEqual(store.sessions[key]?.status, .running, "the sweep leaves jobs alone")
        XCTAssertEqual(store.sessions[key]?.workspaceName, "ironpet")

        job.state = .done
        job.ended = Date(timeIntervalSince1970: 60)
        store.setJob(key, job.agentSession)
        store.setJob(key, job.agentSession)
        XCTAssertEqual(announced, [.done])
        store.acknowledge(key)
        store.setJob(key, job.agentSession)
        XCTAssertEqual(store.sessions[key]?.status, .idle, "an acknowledged row stays hidden")

        job.state = .stopped
        store.setJob(key, job.agentSession)
        XCTAssertNil(store.sessions[key])
    }

    func testAMessageTypedInARunningJobsThreadGoesToTheJobAndStaysVisible() {
        let chat = ChatSession(restore: false)
        func thread(_ prompts: [String]) -> ChatThread {
            ChatThread(id: "session-1", title: "Fix", workspace: folder.path, updatedAt: Date(),
                       items: prompts.map { .init(kind: .user($0), origin: ChatSession.jobOrigin) }, agent: AgentCatalog.all[0].id, job: "job-1")
        }
        chat.open(thread(["Fix it"]))
        var routed: [(String, String)] = []
        chat.jobFollowUp = { thread, text in
            routed.append((thread, text))
            return true
        }
        chat.input = "Also update the README"
        chat.send()
        XCTAssertEqual(routed.map(\.1), ["Also update the README"])
        XCTAssertEqual(routed.map(\.0), ["session-1"])
        XCTAssertEqual(chat.input, "")

        func prompts() -> [String] { chat.items.compactMap { if case .user(let text) = $0.kind { text } else { nil } } }
        chat.threadSaved(thread(["Fix it"]))
        XCTAssertEqual(prompts(), ["Fix it", "Also update the README"], "kept until the job starts on it")
        chat.threadSaved(thread(["Fix it", "Also update the README"]))
        XCTAssertEqual(prompts(), ["Fix it", "Also update the README"], "not shown twice")
    }

    func testRepliesAndAttachmentsInAJobThreadGoToTheJobToo() {
        let chat = ChatSession(restore: false)
        chat.open(ChatThread(id: "session-1", title: "Fix", workspace: folder.path, updatedAt: Date(), items: [],
                             agent: AgentCatalog.all[0].id, job: "job-1"))
        var routed: [String] = []
        chat.jobFollowUp = { _, text in
            routed.append(text)
            return true
        }
        let shot = folder.appendingPathComponent("shot.png")
        chat.attachments = [shot]
        chat.input = "Use this design"
        chat.send()
        XCTAssertEqual(routed, ["Use this design\n\nAttached files:\n- \(shot.path)"])
        XCTAssertTrue(chat.attachments.isEmpty)
        XCTAssertFalse(chat.isRunning, "the chat starts no agent of its own on the job's session")
        chat.threadSaved(ChatThread(id: "session-1", title: "Fix", workspace: folder.path, updatedAt: Date(),
                                    items: [.init(kind: .user(routed[0]), origin: ChatSession.jobOrigin)], agent: AgentCatalog.all[0].id, job: "job-1"))
        XCTAssertEqual(chat.items.count, 1, "the typed row is replaced by the job's own once it starts on it")
    }

    func testHookEventsCannotPoseAsAJob() {
        let store = SessionStore()
        store.apply(HookEvent(source: .job, name: "UserPromptSubmit", payload: ["session_id": "x"], origin: SessionOrigin()))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testSessionKeyRoundTrips() {
        XCTAssertEqual(Job.id(fromSessionKey: Job.sessionKey("job-abc123")), "job-abc123")
        XCTAssertNil(Job.id(fromSessionKey: "claude:job-abc123"))
    }
}
