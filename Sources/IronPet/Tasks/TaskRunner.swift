import AppKit
import Foundation

/// Runs agents on tasks, each in its own git worktree and ACP session. The agent's work stays on a local branch: it
/// cannot push, and Open PR is the user's own action. Approvals go through Ghost like the chat's.
@MainActor
final class TaskRunner: ObservableObject {
    /// The author of every task change a run makes, in the task's history.
    static let author = "task-run"
    /// The app's runner, for the test endpoints.
    static var shared: TaskRunner?

    @Published private(set) var runs: [String: TaskRun] = [:]

    private let tasks: TaskStore
    private let store: TaskRunStore
    var config: () -> Config.TaskRuns = { ConfigStore.shared.config.taskRuns }
    var git: () -> GitWorktree? = GitWorktree.locate
    var worktreeRoot = Paths.worktrees
    var ironpetRoot = Paths.root
    var now: () -> Date = Date.init
    /// The chat's agent and model, used when `taskRuns.agent` is not set.
    var chatAgent: () -> (agent: ACPAgent, model: String?)? = { nil }
    var makeBackend: (ACPAgent) -> ACPBackend = { ACPBackend(agent: $0) }
    var shareMCPSignIns: () -> Bool = { ConfigStore.shared.config.integrations.shareMCPSignIns }
    /// Set in test mode: Open PR hands its commands here instead of running them.
    var recordOpenPR: (([String]) -> Void)?
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    var onApproval: ((TaskRun, TaskRun.Approval) -> Void)?
    var onApprovalResolved: ((UUID) -> Void)?
    var onFinished: ((TaskRun) -> Void)?
    var onFailed: ((TaskRun) -> Void)?
    var onPushed: ((TaskRun, String) -> Void)?

    private struct Live {
        let backend: ACPBackend
        let turn: UUID
        var transcript = ChatTranscript()
        var items: [ChatSession.Item]
        var title: String
        var pending: [(approval: TaskRun.Approval, respond: (ApprovalDecision) -> Void)] = []
        var limit: Task<Void, Never>?
    }

    private var live: [String: Live] = [:]

    init(tasks: TaskStore, store: TaskRunStore) {
        self.tasks = tasks
        self.store = store
        for run in store.all() { runs[run.task] = run }
    }

    /// Sample runs for `--render-previews`. Nothing is stored.
    func loadPreview(_ list: [TaskRun]) {
        runs = Dictionary(uniqueKeysWithValues: list.map { ($0.task, $0) })
    }

    // MARK: Reading

    var liveCount: Int { runs.values.filter(\.state.isLive).count }

    var limit: Int { config().maxConcurrent }

    func run(for task: String) -> TaskRun? { runs[task] }

    func row(for task: TaskItem) -> TaskRunRow {
        TaskRunRow.state(task: task, run: runs[task.id], enabled: config().enabled, running: liveCount, limit: limit)
    }

    /// True while a run owns this chat thread, so the chat does not open it and start a second agent on the session.
    func isLive(thread: String) -> Bool {
        runs.values.contains { $0.session == thread && $0.state.isLive }
    }

    /// Runs that need the user, oldest first.
    var waiting: [TaskRun] { runs.values.filter { $0.state == .needsApproval }.sorted { $0.started < $1.started } }

    /// Waiting on an approval wins over working.
    var mood: PetMood? {
        if runs.values.contains(where: { $0.state == .needsApproval }) { return .needsInput }
        return runs.values.contains(where: \.state.isLive) ? .working : nil
    }

    /// What the Agents section lists: live runs, and ended ones whose task still waits on the user.
    func shown(in tasks: TaskStore) -> [(run: TaskRun, task: TaskItem)] {
        runs.values.compactMap { run -> (run: TaskRun, task: TaskItem)? in
            guard run.cleanup != .removed, let task = tasks.task(run.task) else { return nil }
            let ended = [.finished, .failed, .interrupted].contains(run.state) && task.status == .needsYou
            return run.state.isLive || ended ? (run, task) : nil
        }
        .sorted { $0.run.started > $1.run.started }
    }

    /// The folder of a watched agent session, for a task's session link.
    var sessionWorkspace: (String) -> String? = { _ in nil }

    /// The agents the Start popover offers.
    var agents: () -> [ACPAgent] = { AgentCatalog.present() }

    /// The folders a task's Start popover offers, best first.
    func candidates(for task: TaskItem) -> [URL] {
        TaskProject.candidates(for: task, threadWorkspace: { ThreadStore.load($0)?.workspace }, sessionWorkspace: sessionWorkspace,
                               lastRun: runs[task.id], ironpetRoot: ironpetRoot)
    }

    /// The agent a run uses unless the popover picked another.
    func defaultAgent() -> (agent: ACPAgent, model: String?)? {
        let settings = config()
        if let id = settings.agent, let agent = AgentCatalog.agent(id: id) { return (agent, settings.model) }
        guard let chat = chatAgent() else { return nil }
        return (chat.agent, settings.model ?? chat.model)
    }

    // MARK: Start, stop, retry

    /// Starts or continues a run. A run that still has its worktree continues there and resumes its session. Returns
    /// why it could not start, or nil.
    @discardableResult
    func start(task id: String, project: URL?, agent: ACPAgent, model: String?, auto: Bool) async -> String? {
        guard config().enabled else { return "Task runs are turned off in taskRuns.enabled." }
        guard let task = tasks.task(id), task.status != .done else { return "That task is closed." }
        if let existing = runs[id], existing.state.isLive { return "An agent is already working on this task." }
        guard liveCount < limit else { return "\(liveCount) tasks are already running. The limit is taskRuns.maxConcurrent." }
        guard let git = git() else { return "git was not found. Install the Xcode command line tools, then try again." }

        var run: TaskRun
        let fresh: Bool
        if var previous = runs[id], previous.cleanup != .removed, FileManager.default.fileExists(atPath: previous.worktree.path) {
            previous.agent = agent.id
            previous.model = model
            previous.auto = auto
            run = previous
            fresh = false
        } else {
            guard let project else { return "Choose the project folder for this task." }
            do {
                let repo = try await git.repoRoot(of: project)
                let head = try await git.head(repo)
                let slot = await git.freeSlot(repo, task: id, parent: GitWorktree.parent(for: repo, root: worktreeRoot))
                try await git.addWorktree(repo: repo, folder: slot.folder, branch: slot.branch, base: head.sha)
                run = TaskRun(task: id, repo: repo, worktree: slot.folder, branch: slot.branch, base: head.sha, baseBranch: head.branch,
                              agent: agent.id, model: model, session: nil, auto: auto, state: .starting, started: now(),
                              ended: nil, summary: nil, error: nil)
            } catch {
                return error.localizedDescription
            }
            fresh = true
        }
        // A run started again after the task changed hands is live again; one that was cleaned up starts a new session.
        if fresh { run.session = nil }
        run.state = .starting
        run.started = now()
        run.ended = nil
        run.error = nil
        run.summary = nil
        run.approval = nil
        run.cleanup = .none
        let previousError = runs[id]?.error
        put(run)
        setStatus(id, .inProgress)

        let backend = makeBackend(agent)
        backend.usageFeature = .taskRuns
        backend.extraEnvironment = GitWorktree.pushBlockEnvironment(remotes: await git.remotes(run.repo))
        backend.onPermission = { [weak self] call, respond in self?.permission(id, call, respond) }
        backend.onBackground = { [weak self] event in self?.background(id, event) }
        if agent.id == "cursor", shareMCPSignIns() { MCPAuthSharing.prepare(workspace: run.worktree) }

        let prompt = fresh || run.session == nil
            ? TaskRunPrompt.start(task: task, repo: run.repo, branch: run.branch, baseBranch: run.baseBranch)
            : TaskRunPrompt.resume(task: task, lastError: previousError)
        var items = run.session.flatMap { ThreadStore.load($0)?.items } ?? []
        items.append(ChatSession.Item(kind: .user(prompt), origin: ChatSession.taskRunOrigin))
        let title = task.title.count > 54 ? "Task: " + task.title.prefix(51) + "…" : "Task: " + task.title
        let turnID = UUID()
        live[id] = Live(backend: backend, turn: turnID, items: items, title: title,
                        limit: Task { [weak self] in await self?.enforceLimit(id, turn: turnID) })
        let turn = ACPTurn(prompt: prompt, preamble: run.session == nil ? Memory.preamble(for: run.repo) : nil, workspace: run.worktree,
                           resume: run.session, model: model, images: [], files: [])
        update(id) { $0.state = .running; $0.activity = "Thinking" }
        Task { [weak self] in
            await backend.runTurn(turn) { event in self?.handle(id, turn: turnID, event) }
        }
        return nil
    }

    /// Stops the agent. The worktree and branch stay, and the task goes back to the backlog.
    func stop(task id: String) {
        guard runs[id]?.state.isLive == true else { return }
        end(id, state: .stopped, error: nil)
        setStatus(id, .backlog)
    }

    /// At quit: live runs end as interrupted and their tasks wait on the user.
    func shutdown() {
        for id in runs.values.filter(\.state.isLive).map(\.task) {
            end(id, state: .interrupted, error: "ironpet quit while the agent was working.", notify: false)
            setStatus(id, .needsYou)
        }
    }

    /// At launch: runs that were live when ironpet last stopped are interrupted, and rows left by deleted tasks are cleaned up.
    func restore() async {
        for run in store.markInterrupted(now: now()) {
            runs[run.task] = run
            setStatus(run.task, .needsYou)
        }
        for run in runs.values {
            await refreshGit(run.task)
            await tidy(run.task)
        }
    }

    // MARK: Approvals

    func decide(id: UUID, allow: Bool) {
        guard let task = live.first(where: { $0.value.pending.contains { $0.approval.id == id } })?.key,
              let index = live[task]?.pending.firstIndex(where: { $0.approval.id == id }),
              let entry = live[task]?.pending.remove(at: index) else { return }
        entry.respond(allow ? .allow : .deny())
        onApprovalResolved?(id)
        let next = live[task]?.pending.first?.approval
        update(task) {
            $0.approval = next
            if next == nil, $0.state == .needsApproval { $0.state = .running }
        }
        if next == nil { setStatus(task, .inProgress) }
    }

    func hasPendingApproval(_ id: UUID) -> Bool {
        live.values.contains { $0.pending.contains { $0.approval.id == id } }
    }

    private func permission(_ task: String, _ call: ACPToolCall, _ respond: @escaping (ApprovalDecision) -> Void) {
        guard let run = runs[task], run.state.isLive else { return respond(.deny("The run ended")) }
        switch ApprovalRules.policy(for: call, auto: run.auto, run: RunScope(root: run.worktree)) {
        case .allow: respond(.allow)
        case .refuse(let message): respond(.deny(message))
        case .ask(let title, let detail):
            let approval = TaskRun.Approval(id: UUID(), title: title, detail: detail)
            live[task]?.pending.append((approval, respond))
            guard live[task]?.pending.count == 1 else { return }
            update(task) { $0.state = .needsApproval; $0.approval = approval }
            setStatus(task, .needsYou)
            if let run = runs[task] { onApproval?(run, approval) }
        }
    }

    // MARK: Events

    private func handle(_ task: String, turn: UUID, _ event: AgentEvent) {
        guard var state = live[task], state.turn == turn else { return }
        switch event {
        case .session(let session):
            update(task) { $0.session = session }
            link(task, thread: session)
            saveThread(task)
        case .assistant, .toolStarted, .toolUpdated, .toolFinished, .subagentTool:
            let outcome = state.transcript.apply(event, to: &state.items, running: true)
            live[task] = state
            if let activity = outcome.activity { update(task) { $0.activity = activity } }
            if case .toolFinished = event { saveThread(task) }
        case .needsSignIn:
            let name = runs[task]?.agentName ?? "The agent"
            end(task, state: .failed, error: "\(name) needs you to sign in. Open Chat with \(name), sign in, then Retry.")
        case .needsRuntime:
            end(task, state: .failed, error: "This agent needs a one-time runtime download. Start a chat with it to allow it, then Retry.")
        case .finished(let error):
            end(task, state: error == nil ? .finished : .failed, error: error)
        case .models, .commands:
            break
        }
    }

    private func background(_ task: String, _ event: AgentEvent) {
        guard var state = live[task] else { return }
        let outcome = state.transcript.apply(event, to: &state.items, running: false)
        live[task] = state
        if outcome.save { saveThread(task) }
    }

    private func enforceLimit(_ task: String, turn: UUID) async {
        let minutes = config().maxMinutes
        try? await Task.sleep(nanoseconds: UInt64(minutes * 60 * 1_000_000_000))
        guard !Task.isCancelled, live[task]?.turn == turn else { return }
        end(task, state: .failed, error: "Stopped after \(Int(minutes)) minutes, the limit in taskRuns.maxMinutes.")
    }

    /// Ends the turn: the agent process stops, waiting approvals are denied, and the transcript is saved.
    private func end(_ task: String, state: TaskRun.State, error: String?, notify: Bool = true) {
        guard let current = live.removeValue(forKey: task) else { return }
        current.limit?.cancel()
        for entry in current.pending {
            entry.respond(.deny("The run ended"))
            onApprovalResolved?(entry.approval.id)
        }
        current.backend.cancel()
        current.backend.shutdown()
        var items = current.items
        if let error { items.append(ChatSession.Item(kind: .error(error))) }
        saveThread(task, items: items, title: current.title)
        let reply = Self.lastReply(items)
        update(task) {
            $0.state = state
            $0.ended = self.now()
            $0.error = error
            $0.approval = nil
            $0.activity = nil
            $0.summary = reply.map(Self.firstSentence)
        }
        guard notify, state == .finished || state == .failed else { return }
        setStatus(task, .needsYou)
        Task { [weak self] in
            guard let self else { return }
            await self.refreshGit(task)
            guard let run = self.runs[task] else { return }
            if state == .finished { self.onFinished?(run) } else { self.onFailed?(run) }
        }
    }

    // MARK: Git

    func refreshGit(_ task: String) async {
        guard let run = runs[task], run.cleanup != .removed, let git = git(),
              FileManager.default.fileExists(atPath: run.worktree.path) else { return }
        let commits = await git.commitsAhead(run.worktree, base: run.base)
        let dirty = await git.hasUncommittedChanges(run.worktree)
        runs[task]?.commits = commits
        runs[task]?.dirty = dirty
    }

    /// Open PR: pushes the branch with ironpet's own git, then opens GitHub's new-PR page. Returns why it failed, or nil.
    @discardableResult
    func openPR(task id: String) async -> String? {
        await refreshGit(id)
        guard let run = runs[id] else { return "There is no run for this task." }
        guard run.canOpenPR else { return run.openPRHint ?? "There is nothing to push yet." }
        guard let git = git() else { return "git was not found." }
        guard let remote = await git.pushRemote(run.repo, baseBranch: run.baseBranch) else {
            return "\(run.repo.lastPathComponent) has no remote to push to."
        }
        let gh = LoginShell.find("gh")
        let prArguments = ["pr", "create", "--web", "--head", run.branch] + (run.baseBranch.map { ["--base", $0] } ?? [])
        if let record = recordOpenPR {
            record([git.git, "push", "-u", remote, run.branch])
            record([gh?.path ?? "gh"] + prArguments)
            onPushed?(run, remote)
            return nil
        }
        do {
            try await git.push(worktree: run.worktree, remote: remote, branch: run.branch)
        } catch {
            return "Push to \(remote) failed: \(error.localizedDescription)"
        }
        onPushed?(run, remote)
        if let gh {
            var env = LoginShell.environment()
            env["GH_PROMPT_DISABLED"] = "1"
            // gh reads the repository from the folder it runs in, and CommandRunner has no working directory.
            let result = await CommandRunner.run(executable: "/bin/sh", arguments: ["-c", #"cd "$1" && shift && exec "$@""#, "sh",
                                                                                    run.worktree.path, gh.path] + prArguments,
                                                 timeout: 30, environment: env, maxBytes: 64 * 1024)
            if result.code == 0 { return nil }
        }
        if let url = await git.remoteURL(run.repo, remote: remote),
           let page = GitWorktree.compareURL(remote: url, base: run.baseBranch, branch: run.branch) {
            openURL(page)
            return nil
        }
        return "Pushed \(run.branch) to \(remote). Open a pull request for it on your git host."
    }

    // MARK: Cleanup

    /// Called after any task change. A task that was closed or deleted gets its worktree removed when it is clean.
    func tasksChanged(_ id: String?) {
        let ids = id.map { [$0] } ?? Array(runs.keys)
        for id in ids where runs[id] != nil {
            let task = tasks.task(id)
            guard task == nil || task?.status == .done else { continue }
            if runs[id]?.state.isLive == true { end(id, state: .stopped, error: nil, notify: false) }
            Task { [weak self] in await self?.tidy(id) }
        }
    }

    /// Removes the worktree of a closed or deleted task when git agrees it is clean. A dirty one is kept for Remove Copy.
    private func tidy(_ id: String) async {
        guard var run = runs[id], !run.state.isLive else { return }
        let task = tasks.task(id)
        if run.cleanup == .removed {
            if task == nil { forget(id) }
            return
        }
        guard task == nil || task?.status == .done else { return }
        guard let git = git() else { return }
        if !FileManager.default.fileExists(atPath: run.worktree.path) {
            await git.prune(run.repo)
        } else {
            do {
                try await git.removeWorktree(repo: run.repo, folder: run.worktree, force: false)
            } catch {
                run.cleanup = .kept
                put(run)
                return
            }
        }
        await git.deleteBranchIfEmpty(repo: run.repo, branch: run.branch, base: run.base)
        removed(id)
    }

    /// Remove Copy: deletes a kept worktree and its uncommitted changes. The branch stays when it has commits.
    @discardableResult
    func removeCopy(task id: String) async -> String? {
        guard let run = runs[id], !run.state.isLive, run.cleanup != .removed else { return nil }
        guard let git = git() else { return "git was not found." }
        if FileManager.default.fileExists(atPath: run.worktree.path) {
            do {
                try await git.removeWorktree(repo: run.repo, folder: run.worktree, force: true)
            } catch {
                return error.localizedDescription
            }
        }
        await git.prune(run.repo)
        await git.deleteBranchIfEmpty(repo: run.repo, branch: run.branch, base: run.base)
        removed(id)
        return nil
    }

    /// The worktree is gone. The thread now points at the main working copy, so reopening it in the chat still works.
    private func removed(_ id: String) {
        guard var run = runs[id] else { return }
        if let session = run.session, var thread = ThreadStore.load(session) {
            thread.workspace = run.repo.path
            ThreadStore.save(thread)
        }
        run.cleanup = .removed
        run.commits = 0
        run.dirty = false
        if tasks.task(id) == nil { return forget(id) }
        put(run)
    }

    private func forget(_ id: String) {
        runs[id] = nil
        store.delete(id)
    }

    // MARK: Helpers

    private func put(_ run: TaskRun) {
        runs[run.task] = run
        store.save(run)
    }

    private func update(_ task: String, _ change: (inout TaskRun) -> Void) {
        guard var run = runs[task] else { return }
        let before = run
        change(&run)
        guard run != before else { return }
        runs[task] = run
        if run.state != before.state || run.session != before.session || run.summary != before.summary || run.error != before.error {
            store.save(run)
        }
    }

    private func setStatus(_ task: String, _ status: TaskStatus) {
        guard let item = tasks.task(task), item.status != .done, item.status != status else { return }
        try? tasks.update(task, status: status, by: Self.author)
    }

    private func link(_ task: String, thread: String) {
        guard let item = tasks.task(task), !item.links.contains(where: { $0.kind == .thread && $0.ref == thread }),
              item.links.count < TaskValidator.maxLinks else { return }
        try? tasks.update(task, links: item.links + [TaskLink(kind: .thread, ref: thread, label: "Agent run")], by: Self.author)
    }

    private func saveThread(_ task: String, items: [ChatSession.Item]? = nil, title: String? = nil) {
        guard let run = runs[task], let session = run.session,
              let items = items ?? live[task]?.items, let title = title ?? live[task]?.title else { return }
        ThreadStore.save(ChatThread(id: session, title: title, workspace: run.worktree.path, updatedAt: now(), items: items,
                                    agent: run.agent, task: task))
    }

    static func lastReply(_ items: [ChatSession.Item]) -> String? {
        for item in items.reversed() {
            if case .user = item.kind { return nil }
            if case .assistant(let text) = item.kind, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    /// The reply's first sentence or line, at most 140 characters, for the task row.
    static func firstSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        var sentence = line
        if let end = line.range(of: #"[.!?](\s|$)"#, options: .regularExpression) { sentence = String(line[..<end.lowerBound]) + String(line[end.lowerBound]) }
        sentence = sentence.trimmingCharacters(in: .whitespaces)
        return sentence.count > 140 ? String(sentence.prefix(139)) + "…" : sentence
    }
}
