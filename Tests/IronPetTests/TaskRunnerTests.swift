import XCTest
@testable import IronPet

/// Runs TaskRunner end to end: a real git repository and a scripted ACP agent that commits, asks, pushes or waits.
@MainActor
final class TaskRunnerTests: XCTestCase {
    private static let script = #"""
    #!/usr/bin/env python3
    import json, os, subprocess, sys
    log = open(os.environ["FAKE_LOG"], "a")
    def send(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    def note(o): log.write(json.dumps(o) + "\n"); log.flush()
    sid = None
    def update(u): send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": u}})
    def say(t): update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": t}})
    def ask(command):
        update({"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "`%s`" % command, "kind": "execute", "status": "pending", "rawInput": {"command": command}})
        send({"jsonrpc": "2.0", "id": 900, "method": "session/request_permission", "params": {"sessionId": sid,
              "toolCall": {"toolCallId": "t1", "title": "`%s`" % command, "kind": "execute", "rawInput": {"command": command}},
              "options": [{"optionId": "yes", "name": "Allow", "kind": "allow_once"}, {"optionId": "no", "name": "Reject", "kind": "reject_once"}]}})
        reply = json.loads(sys.stdin.readline())
        ok = reply.get("result", {}).get("outcome", {}).get("optionId") == "yes"
        note({"asked": command, "allowed": ok})
        update({"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed" if ok else "failed"})
    for line in sys.stdin:
        m = json.loads(line)
        method, mid, p = m.get("method"), m.get("id"), m.get("params", {})
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}}})
        elif method in ("session/new", "session/load"):
            sid = p.get("sessionId") or "sess-%d" % os.getpid()
            note({"method": method, "session": sid})
            send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": sid}})
        elif method == "session/prompt":
            text = "".join(b.get("text", "") for b in p["prompt"])
            note({"cwd": os.getcwd(), "pushurl": os.environ.get("GIT_CONFIG_VALUE_0", ""), "resume": "Continue the task" in text})
            if "SLOW" in text:
                say("working")
                for l in sys.stdin:
                    c = json.loads(l)
                    if c.get("method") == "session/cancel":
                        send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "cancelled"}}); break
                continue
            if "ASK" in text: ask("touch x")
            if "TWICE" in text:
                ask("touch y")
                ask("touch y")
            if "PUSH" in text: ask("git push origin HEAD")
            if "COMMIT" in text:
                open("feature.txt", "w").write("done\n")
                subprocess.run(["git", "add", "feature.txt"], check=True)
                subprocess.run(["git", "-c", "user.name=Agent", "-c", "user.email=a@example.com", "commit", "-qm", "feature"], check=True)
            if "DIRTY" in text:
                open("scratch.txt", "w").write("left behind\n")
            if "BROKEN" in text:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": "model overloaded"}}); continue
            say("Added the feature. Tests pass.\nMore detail here.")
            send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
    """#

    private var dir: URL!
    private var repo: URL!
    private var database: Database!
    private var tasks: TaskStore!
    private var runner: TaskRunner!
    private var settings = Config.TaskRuns()
    private var savedThreads: URL!
    private var approvals: [TaskRun.Approval] = []
    private var finished: [String] = []
    private var failed: [String] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-runner-\(UUID().uuidString)").resolvingSymlinksInPath()
        repo = dir.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try GitFixture.initRepo(repo)
        try GitFixture.sh(["git", "remote", "add", "origin", "git@github.com:you/app.git"], in: repo)
        try Self.script.write(to: dir.appendingPathComponent("fake-agent"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("fake-agent").path)
        setenv("FAKE_LOG", dir.appendingPathComponent("log").path, 1)
        savedThreads = ThreadStore.directory
        ThreadStore.directory = dir.appendingPathComponent("threads")
        settings = Config.TaskRuns()
        approvals = []
        finished = []
        failed = []
        database = Database.open(path: nil, migrations: AppMigrations.all).database
        tasks = TaskStore(database: database)
        runner = makeRunner()
    }

    override func tearDown() async throws {
        runner?.shutdown()
        runner = nil
        ThreadStore.directory = savedThreads
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeRunner() -> TaskRunner {
        let runner = TaskRunner(tasks: tasks, store: TaskRunStore(database: database))
        runner.config = { [unowned self] in settings }
        runner.worktreeRoot = dir.appendingPathComponent("worktrees")
        runner.ironpetRoot = dir.appendingPathComponent("ironpet")
        runner.shareMCPSignIns = { false }
        runner.allowedAgents.insert("fake")
        runner.onApproval = { [unowned self] _, approval in approvals.append(approval) }
        runner.onFinished = { [unowned self] in finished.append($0.task) }
        runner.onFailed = { [unowned self] in failed.append($0.task) }
        return runner
    }

    private var agent: ACPAgent { ACPAgent(id: "fake", name: "Fake", command: dir.appendingPathComponent("fake-agent").path, args: [], helper: nil) }

    private func newTask(_ title: String) throws -> String {
        try tasks.create(title: title, source: .chat, by: "test").id
    }

    @discardableResult
    private func start(_ id: String, project: URL? = nil) async -> String? {
        await runner.start(task: id, project: project ?? repo, agent: agent, model: nil)
    }

    private func wait(_ what: String, timeout: Double = 20, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func logged() -> [JSON] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? JSON }
    }

    private func git(_ arguments: String...) throws -> String { try GitFixture.sh(["git"] + arguments, in: repo) }

    // MARK: Tests

    func testARunCommitsInItsOwnWorktreeAndLeavesTheUsersCopyAlone() async throws {
        let id = try newTask("COMMIT the feature")
        let before = try git("rev-parse", "HEAD")
        let started = await start(id)
        XCTAssertNil(started)
        XCTAssertEqual(tasks.task(id)?.status, .inProgress)
        await wait("finish") { finished == [id] }
        let run = try XCTUnwrap(runner.run(for: id))
        XCTAssertEqual(run.state, .finished)
        XCTAssertEqual(run.branch, "ironpet/\(id)")
        XCTAssertEqual(run.baseBranch, "main")
        XCTAssertTrue(run.worktree.path.hasPrefix(dir.appendingPathComponent("worktrees").path))
        XCTAssertEqual(run.commits, 1)
        XCTAssertFalse(run.dirty)
        XCTAssertTrue(run.canOpenPR)
        XCTAssertEqual(run.gitDir?.path, repo.appendingPathComponent(".git/worktrees/\(run.worktree.lastPathComponent)").resolvingSymlinksInPath().path)
        XCTAssertEqual(run.pushRemote, "origin")
        XCTAssertEqual(TaskRunStore(database: database).all().first?.gitDir, run.gitDir)
        XCTAssertEqual(run.summary, "Added the feature.")
        XCTAssertEqual(tasks.task(id)?.status, .needsYou)
        XCTAssertEqual(tasks.history(id).last?.by, TaskRunner.author)

        XCTAssertEqual(try git("rev-parse", "HEAD"), before, "the user's branch did not move")
        XCTAssertEqual(try git("status", "--porcelain"), "")
        XCTAssertEqual(try git("symbolic-ref", "--short", "HEAD"), "main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("feature.txt").path))

        let prompt = try XCTUnwrap(logged().first { $0["cwd"] != nil })
        XCTAssertEqual((prompt["cwd"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       run.worktree.resolvingSymlinksInPath().path)
        XCTAssertEqual(prompt["pushurl"] as? String, "ironpet-no-push://task-runs-cannot-push")

        let session = try XCTUnwrap(run.session)
        XCTAssertTrue(tasks.task(id)?.links.contains(TaskLink(kind: .thread, ref: session, label: "Agent run")) == true)
        let thread = try XCTUnwrap(ThreadStore.load(session))
        XCTAssertEqual(thread.task, id)
        XCTAssertEqual(thread.title, "Task: COMMIT the feature")
        XCTAssertEqual(thread.workspace, run.worktree.path)
        guard case .user = thread.items.first?.kind else { return XCTFail("the prompt opens the thread") }
        XCTAssertEqual(thread.items.first?.origin, ChatSession.taskRunOrigin)
        XCTAssertFalse(runner.isLive(thread: session))
    }

    func testAnApprovalWaitsOnTheUserAndTheRunContinuesAfterIt() async throws {
        let id = try newTask("ASK before touching")
        await start(id)
        await wait("approval") { approvals.count == 1 }
        XCTAssertEqual(runner.run(for: id)?.state, .needsApproval)
        XCTAssertEqual(tasks.task(id)?.status, .needsYou)
        XCTAssertTrue(runner.isLive(thread: try XCTUnwrap(runner.run(for: id)?.session)))
        XCTAssertEqual(runner.row(for: try XCTUnwrap(tasks.task(id))), .approval(title: approvals[0].title, detail: approvals[0].detail))
        runner.decide(id: approvals[0].id, allow: true)
        XCTAssertEqual(tasks.task(id)?.status, .inProgress)
        await wait("finish") { finished == [id] }
        XCTAssertEqual(logged().first { $0["asked"] != nil }?["allowed"] as? Bool, true)
    }

    func testPushIsRefusedWithoutACard() async throws {
        let id = try newTask("PUSH the branch")
        await start(id)
        await wait("finish") { finished == [id] }
        XCTAssertTrue(approvals.isEmpty, "a push is refused, not asked")
        XCTAssertEqual(logged().first { $0["asked"] != nil }?["allowed"] as? Bool, false)
    }

    func testStopSendsTheTaskBackToTheBacklogAndKeepsTheWorktree() async throws {
        let id = try newTask("SLOW work")
        await start(id)
        await wait("running") { logged().contains { $0["cwd"] != nil } }
        runner.stop(task: id)
        let run = try XCTUnwrap(runner.run(for: id))
        XCTAssertEqual(run.state, .stopped)
        XCTAssertEqual(tasks.task(id)?.status, .backlog)
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.worktree.path))
        XCTAssertTrue(failed.isEmpty && finished.isEmpty)
    }

    func testTheConcurrencyLimitHoldsAndAFailedTurnIsReported() async throws {
        settings.maxConcurrent = 1
        let slow = try newTask("SLOW one")
        let other = try newTask("BROKEN two")
        await start(slow)
        let refused = await start(other)
        XCTAssertEqual(refused, "1 tasks are already running. The limit is taskRuns.maxConcurrent.")
        if case .idle(let button) = runner.row(for: try XCTUnwrap(tasks.task(other))) {
            XCTAssertEqual(button?.enabled, false)
        } else { XCTFail("idle row expected") }
        runner.stop(task: slow)
        let restarted = await start(other)
        XCTAssertNil(restarted)
        await wait("failure") { failed == [other] }
        XCTAssertEqual(runner.run(for: other)?.error, "model overloaded")
        XCTAssertEqual(tasks.task(other)?.status, .needsYou)
    }

    func testRetryContinuesTheSameWorktreeAndSession() async throws {
        let id = try newTask("BROKEN at first")
        await start(id)
        await wait("failure") { failed == [id] }
        let first = try XCTUnwrap(runner.run(for: id))
        try tasks.update(id, title: "Now it works", by: "test")
        let started = await start(id)
        XCTAssertNil(started)
        await wait("finish") { finished == [id] }
        let second = try XCTUnwrap(runner.run(for: id))
        XCTAssertEqual(second.worktree, first.worktree)
        XCTAssertEqual(second.session, first.session)
        XCTAssertTrue(logged().contains { $0["method"] as? String == "session/load" && $0["session"] as? String == first.session })
        XCTAssertEqual(logged().last { $0["cwd"] != nil }?["resume"] as? Bool, true)
    }

    func testAFolderOutsideGitCannotStart() async throws {
        let plain = dir.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let id = try newTask("COMMIT")
        let error = await start(id, project: plain)
        XCTAssertEqual(error, "notes is not a git repository. A task run works in its own copy, so it needs git.")
        XCTAssertNil(runner.run(for: id))
        XCTAssertEqual(tasks.task(id)?.status, .backlog)
    }

    func testClosingATaskRemovesItsCleanWorktreeAndKeepsCommittedWork() async throws {
        let id = try newTask("COMMIT and close")
        await start(id)
        await wait("finish") { finished == [id] }
        let run = try XCTUnwrap(runner.run(for: id))
        try tasks.close(id, by: "test")
        runner.tasksChanged(id)
        await wait("cleanup") { runner.run(for: id)?.cleanup == .removed }
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.worktree.path))
        XCTAssertNoThrow(try git("show-ref", "--verify", "refs/heads/\(run.branch)"), "the branch has a commit, so it stays")
        let workspace = try XCTUnwrap(ThreadStore.load(try XCTUnwrap(run.session))?.workspace)
        XCTAssertEqual(URL(fileURLWithPath: workspace).resolvingSymlinksInPath(), repo.resolvingSymlinksInPath())
    }

    func testUncommittedWorkIsKeptUntilRemoveCopy() async throws {
        let id = try newTask("DIRTY and delete")
        await start(id)
        await wait("finish") { finished == [id] }
        let run = try XCTUnwrap(runner.run(for: id))
        XCTAssertTrue(run.dirty)
        XCTAssertFalse(run.canOpenPR)
        try tasks.delete(id, by: "test")
        runner.tasksChanged(id)
        await wait("kept") { runner.run(for: id)?.cleanup == .kept }
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.worktree.appendingPathComponent("scratch.txt").path))
        let removeError = await runner.removeCopy(task: id)
        XCTAssertNil(removeError)
        XCTAssertNil(runner.run(for: id), "the task is gone, so the row goes too")
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.worktree.path))
        XCTAssertThrowsError(try git("show-ref", "--verify", "refs/heads/\(run.branch)"), "an empty branch is deleted")
    }

    func testOpenPRRecordsItsCommandsInTestMode() async throws {
        var commands: [[String]] = []
        runner.recordOpenPR = { commands.append($0) }
        let id = try newTask("COMMIT for a PR")
        await start(id)
        await wait("finish") { finished == [id] }
        let prError = await runner.openPR(task: id)
        XCTAssertNil(prError)
        let copy = try XCTUnwrap(runner.run(for: id)?.copy)
        XCTAssertEqual(commands.first?.dropFirst().map { $0 },
                       GitWorktree.pushArguments(copy: copy, url: "git@github.com:you/app.git", branch: "ironpet/\(id)"))
        XCTAssertEqual(commands.last?.suffix(9), ["pr", "create", "--web", "--head", "ironpet/\(id)", "--base", "main", "--repo", "you/app"])
    }

    func testOpenPRRefusesWhenThePushURLChangedSinceTheStart() async throws {
        var commands: [[String]] = []
        var refusals: [String] = []
        runner.recordOpenPR = { commands.append($0) }
        runner.onOpenPRFailed = { refusals.append($1) }
        let id = try newTask("COMMIT then redirect")
        await start(id)
        await wait("finish") { finished == [id] }
        XCTAssertEqual(runner.run(for: id)?.pushURL, "git@github.com:you/app.git")
        XCTAssertEqual(TaskRunStore(database: database).all().first?.pushURL, "git@github.com:you/app.git")
        _ = try git("config", "remote.origin.pushurl", "https://evil.example/app.git")
        let error = await runner.openPR(task: id)
        XCTAssertEqual(error, "The push URL of origin changed since the task started (now https://evil.example/app.git), so ironpet did not push. Check the repository's remotes.")
        XCTAssertEqual(refusals, error.map { [$0] })
        XCTAssertTrue(commands.isEmpty, "nothing is pushed")
        _ = try git("config", "--unset", "remote.origin.pushurl")
        let again = await runner.openPR(task: id)
        XCTAssertNil(again)
        XCTAssertEqual(commands.count, 2)
    }

    func testADoubleStartStartsOneAgent() async throws {
        let id = try newTask("SLOW once")
        async let first = start(id)
        async let second = start(id)
        let results = await [first, second]
        XCTAssertEqual(results.filter { $0 == nil }.count, 1, "\(results)")
        XCTAssertTrue(results.contains("An agent is already starting on this task."), "\(results)")
        await wait("running") { logged().contains { $0["cwd"] != nil } }
        XCTAssertEqual(runner.liveCount, 1)
        XCTAssertEqual(logged().filter { $0["method"] as? String == "session/new" }.count, 1)
        XCTAssertEqual(try git("worktree", "list").split(separator: "\n").count, 2, "one copy besides the user's")
    }

    func testStopDuringStartupCancelsIt() async throws {
        let id = try newTask("COMMIT never")
        let pending = Task { await start(id) }
        for _ in 0..<1000 where !runner.starting.contains(id) { await Task.yield() }
        XCTAssertTrue(runner.starting.contains(id))
        XCTAssertEqual(runner.liveCount, 1, "a start in progress counts against the limit")
        XCTAssertEqual(runner.row(for: try XCTUnwrap(tasks.task(id))), .running(activity: "Starting…"))
        runner.stop(task: id)
        let result = await pending.value
        XCTAssertEqual(result, "Stopped before the agent started.")
        XCTAssertNil(runner.run(for: id))
        XCTAssertFalse(runner.starting.contains(id))
        XCTAssertEqual(runner.liveCount, 0)
        XCTAssertFalse(logged().contains { $0["cwd"] != nil }, "no agent turn ran")
        XCTAssertEqual(try git("worktree", "list").split(separator: "\n").count, 1, "the new copy is removed")
        XCTAssertThrowsError(try git("show-ref", "--verify", "refs/heads/ironpet/\(id)"))
    }

    func testEveryRequestInARunAsksEvenWhenItRepeatsOne() async throws {
        let id = try newTask("TWICE the same command")
        await start(id)
        await wait("approval") { approvals.count == 1 }
        runner.decide(id: approvals[0].id, allow: true)
        await wait("second approval") { approvals.count == 2 }
        XCTAssertNotEqual(approvals[0].id, approvals[1].id)
        runner.decide(id: approvals[1].id, allow: false)
        await wait("finish") { finished == [id] }
        XCTAssertEqual(logged().filter { $0["asked"] as? String == "touch y" }.map { $0["allowed"] as? Bool }, [true, false])
    }

    func testOnlyAgentsKnownToAskCanStart() async throws {
        XCTAssertEqual(TaskRunner.agentsThatAsk, ["claude", "codex", "cursor", "gemini"])
        let catalog = ["claude", "codex", "cursor", "gemini", "pi", "opencode", "goose"].compactMap { AgentCatalog.agent(id: $0) }
        XCTAssertEqual(catalog.count, 7)
        for other in catalog where !TaskRunner.agentsThatAsk.contains(other.id) {
            let id = try newTask("COMMIT with \(other.id)")
            let refused = await runner.start(task: id, project: repo, agent: other, model: nil)
            XCTAssertEqual(refused, TaskRunner.cannotRun(other))
            XCTAssertNil(runner.run(for: id))
        }
        XCTAssertEqual(try git("worktree", "list").split(separator: "\n").count, 1, "no copy is made")
        XCTAssertEqual(TaskRunner.cannotRun(catalog[4]),
                       "Pi is not one of the agents known to ask ironpet before each change (Claude Code, Codex, Cursor and Gemini CLI), so it cannot work on a task.")

        runner.agents = { catalog + [self.agent] }
        XCTAssertEqual(runner.runnableAgents.map(\.id), ["claude", "codex", "cursor", "gemini", "fake"])
        let pi = catalog[4]
        runner.chatAgent = { (pi, nil) }
        XCTAssertNil(runner.defaultAgent(), "the chat's Pi is not offered as the run's agent")
        settings.agent = "claude"
        XCTAssertEqual(runner.defaultAgent()?.agent.id, "claude")
        settings.agent = "opencode"
        XCTAssertNil(runner.defaultAgent(), "an unverified agent in taskRuns.agent is not used")
        settings.agent = nil

        let excluded = TaskStartPopover.excluded(catalog + [agent], by: runner)
        XCTAssertEqual(excluded.map(\.id), ["pi", "opencode", "goose"])
        XCTAssertEqual(TaskStartPopover.excludedText([pi]),
                       "Pi is not offered: only Claude Code, Codex, Cursor and Gemini CLI are known to ask before each change.")
        XCTAssertEqual(TaskStartPopover.excludedText(Array(excluded.prefix(2))),
                       "Pi and OpenCode are not offered: only Claude Code, Codex, Cursor and Gemini CLI are known to ask before each change.")

        let fresh = TaskRunner(tasks: tasks, store: TaskRunStore(database: database))
        XCTAssertFalse(fresh.canRun(agent), "without the test's opt-in, an agent outside the list cannot run")
    }

    func testOpenPRRefusesWhenTheCopysGitFileWasRewritten() async throws {
        var commands: [[String]] = []
        runner.recordOpenPR = { commands.append($0) }
        let id = try newTask("COMMIT then repoint")
        await start(id)
        await wait("finish") { finished == [id] }
        let run = try XCTUnwrap(runner.run(for: id))
        let other = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try GitFixture.initRepo(other)
        try "gitdir: \(other.appendingPathComponent(".git").path)\n".write(to: run.worktree.appendingPathComponent(".git"),
                                                                         atomically: true, encoding: .utf8)
        let refusal = await runner.openPR(task: id)
        let error = try XCTUnwrap(refusal)
        XCTAssertTrue(error.hasPrefix("The copy's .git file no longer points at the git folder ironpet made for it"), error)
        XCTAssertTrue(commands.isEmpty, "nothing is pushed")
    }

    func testRetryRefusesWhileTheRunsThreadIsOpenInTheChat() async throws {
        let id = try newTask("BROKEN first")
        await start(id)
        await wait("failure") { failed == [id] }
        let session = try XCTUnwrap(runner.run(for: id)?.session)
        runner.threadOpenInChat = { $0 == session }
        let refused = await start(id)
        XCTAssertEqual(refused, TaskRunner.closeChatFirst)
        XCTAssertEqual(runner.run(for: id)?.state, .failed)
        XCTAssertEqual(runner.liveCount, 0)
        XCTAssertEqual(logged().filter { $0["cwd"] != nil }.count, 1, "no second agent turn")
        runner.threadOpenInChat = { _ in false }
        let started = await start(id)
        XCTAssertNil(started)
        await wait("second failure") { failed == [id, id] }
    }

    func testAStartThatFailsAfterPickingItsSlotLeavesNoBranch() async throws {
        let id = try newTask("COMMIT nowhere")
        try "not a folder".write(to: dir.appendingPathComponent("blocked"), atomically: true, encoding: .utf8)
        runner.worktreeRoot = dir.appendingPathComponent("blocked")
        let error = await start(id)
        XCTAssertNotNil(error)
        XCTAssertNil(runner.run(for: id))
        XCTAssertFalse(runner.starting.contains(id))
        XCTAssertThrowsError(try git("show-ref", "--verify", "refs/heads/ironpet/\(id)"))
        XCTAssertEqual(try git("worktree", "list").split(separator: "\n").count, 1)
    }

    func testRemotesWithTheirOwnPushURLAreReported() async throws {
        _ = try git("config", "remote.origin.pushurl", "git@github.com:you/app.git")
        let target = await runner.target(of: repo.appendingPathComponent("."))
        XCTAssertEqual(target?.repo.resolvingSymlinksInPath(), repo.resolvingSymlinksInPath())
        XCTAssertEqual(target?.branch, "main")
        XCTAssertEqual(target?.unblockedRemotes, ["origin"])
        let id = try newTask("COMMIT with a pushurl")
        await start(id)
        XCTAssertEqual(runner.run(for: id)?.unblockedRemotes, ["origin"])
        await wait("finish") { finished == [id] }
        let plain = dir.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let none = await runner.target(of: plain)
        XCTAssertNil(none)
        XCTAssertEqual(TaskStartPopover.unblockedText(["origin"]),
                       "origin has its own push URL, which the extra push block does not cover. Commands still ask before they run.")
    }

    func testLaunchMarksRunsThatWereLiveAsInterrupted() async throws {
        let id = try newTask("Was running")
        var run = TaskRunStoreTests.sampleRun(id, state: .running)
        run.worktree = dir.appendingPathComponent("gone")
        TaskRunStore(database: database).save(run)
        let restored = makeRunner()
        await restored.restore()
        XCTAssertEqual(restored.run(for: id)?.state, .interrupted)
        XCTAssertEqual(tasks.task(id)?.status, .needsYou)
        XCTAssertEqual(restored.row(for: try XCTUnwrap(tasks.task(id))), .interrupted)
    }

    func testMoodAttentionAndAgentsListFollowTheRun() async throws {
        let id = try newTask("ASK first")
        XCTAssertNil(runner.mood)
        await start(id)
        await wait("approval") { approvals.count == 1 }
        XCTAssertEqual(runner.mood, .needsInput)
        XCTAssertEqual(runner.shown(in: tasks).map(\.task.id), [id])
        let signals = SignalStore()
        XCTAssertEqual(IronPetSection.needingAttention(store: SessionStore(), signals: signals, tasks: tasks, runs: runner), .agents)
        runner.decide(id: approvals[0].id, allow: true)
        await wait("finish") { finished == [id] }
        XCTAssertNil(runner.mood)
        XCTAssertEqual(runner.shown(in: tasks).map(\.task.id), [id], "a finished run stays listed while its task needs the user")
        try tasks.update(id, status: .backlog, by: "test")
        XCTAssertTrue(runner.shown(in: tasks).isEmpty)
    }

    func testUninstallRemovesCleanCopiesAndKeepsDirtyOnes() async throws {
        let file = dir.appendingPathComponent("ironpet.db")
        database = Database.open(path: file, migrations: AppMigrations.all).database
        tasks = TaskStore(database: database)
        runner = makeRunner()
        let clean = try newTask("COMMIT clean")
        let dirty = try newTask("DIRTY left")
        await start(clean)
        await wait("first") { finished.count == 1 }
        await start(dirty)
        await wait("second") { finished.count == 2 }
        let cleanRun = try XCTUnwrap(runner.run(for: clean)), dirtyRun = try XCTUnwrap(runner.run(for: dirty))
        let lines = TaskRunUninstall.run(database: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanRun.worktree.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyRun.worktree.path))
        let kept = try XCTUnwrap(lines.first { $0.hasPrefix("Kept \(dirtyRun.worktree.path): ") }, "\(lines)")
        XCTAssertTrue(kept.contains("untracked") || kept.contains("modified"), "git's own reason: \(kept)")
        XCTAssertTrue(lines.contains("Kept the branch \(cleanRun.branch) in \(cleanRun.repo.path): it has the agent's commits"))
    }

    func testFirstSentence() {
        XCTAssertEqual(TaskRunner.firstSentence("Fixed it. Then more."), "Fixed it.")
        XCTAssertEqual(TaskRunner.firstSentence("  One line\nsecond"), "One line")
        XCTAssertEqual(TaskRunner.firstSentence("v1.2 is out"), "v1.2 is out")
        XCTAssertEqual(TaskRunner.firstSentence(String(repeating: "a", count: 200)).count, 140)
    }
}
