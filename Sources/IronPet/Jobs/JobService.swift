import Foundation

/// The part of an agent process a job needs. `ACPBackend` is the real one; tests script their own.
@MainActor
protocol JobAgent: AnyObject {
    var onPermission: ((ACPToolCall, @escaping (ApprovalDecision) -> Void) -> Void)? { get set }
    func runTurn(_ turn: ACPTurn, onEvent: @escaping (AgentEvent) -> Void) async
    func cancel()
    func shutdown()
}

extension ACPBackend: JobAgent {}

struct JobError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs background jobs: at most `maxRunning` at once, the rest in line. Each job gets its own agent process in its
/// folder. ironpet answers its permission requests with the Auto policy, so destructive commands still wait for Allow
/// in a bubble. A task tracks every job, the transcript is saved as a thread, and the state is kept in `ironpet.db`, so
/// a job that was running when ironpet quit shows as interrupted on the next launch.
@MainActor
final class JobService: ObservableObject {
    static let migrations: [Database.Migration] = [
        .init(500, "jobs: background jobs", sql: """
            CREATE TABLE jobs(id TEXT PRIMARY KEY, title TEXT NOT NULL, prompt TEXT NOT NULL, folder TEXT NOT NULL, agent TEXT NOT NULL,
                              model TEXT, thread TEXT, task TEXT, state TEXT NOT NULL, last_step TEXT, summary TEXT, error TEXT,
                              created REAL NOT NULL, started REAL, ended REAL) WITHOUT ROWID;
            CREATE INDEX jobs_by_created ON jobs(created);
            """),
    ]

    /// Finished jobs older than this are deleted at launch.
    static let retention: TimeInterval = 30 * 86_400
    /// Jobs kept in memory for `jobs_list`, newest first.
    static let listed = 50
    /// One agent turn longer than this fails the job, so a stuck agent can't hold a slot forever.
    static let turnTimeout: TimeInterval = 3_600
    /// Who job changes are recorded as in a task's history.
    static let taskAuthor = "agent:job"

    /// Newest first: the active jobs and the latest finished ones.
    @Published private(set) var jobs: [Job] = []

    /// The agent and model a new job runs with: the chat's.
    var currentAgent: () -> (agent: ACPAgent, model: String?)? = { nil }
    var maxRunning: () -> Int = { ConfigStore.shared.config.jobs.maxRunning }
    var makeAgent: (ACPAgent) -> JobAgent = { agent in
        let backend = ACPBackend(agent: agent)
        backend.usageFeature = .jobs
        backend.mcpServers = MCPEndpoint.jobScoped(ACPBackend.defaultMCPServers())
        // Nobody is watching a job to fill in a form, so the agent is told no and carries on.
        backend.onElicitation = { _, respond in respond(.decline) }
        return backend
    }
    /// The text a job's first turn starts with, before the request.
    var preamble: (Job) -> String = { job in JobService.instructions(job) + "\n\n" + Memory.preamble(for: URL(fileURLWithPath: job.folder)) }
    /// Shows Allow and Deny for a job's request. The id is unique per request; `clearApproval` takes it down.
    var askApproval: (_ id: String, _ job: Job, _ title: String, _ detail: String, _ decide: @escaping (Bool) -> Void) -> Void = { _, _, _, _, _ in }
    var clearApproval: (String) -> Void = { _ in }
    /// Every change to a job, for the Agents section and the bubbles.
    var onChange: (Job) -> Void = { _ in }
    /// A job saved its transcript, so the chat can reload its history list and the open thread.
    var onThreadSaved: (ChatThread) -> Void = { _ in }

    private let database: Database
    private let tasks: TaskStore?
    private let now: () -> Date
    private var runs: [String: Run] = [:]

    /// A job's live state while it holds an agent process.
    private final class Run {
        let agent: JobAgent
        var transcript: TranscriptRecorder
        var followUps: [String] = []
        var stopRequested = false
        var approvals: [String: Approval] = [:]

        struct Approval {
            let title: String
            let detail: String
            let decide: (Bool) -> Void
        }

        init(agent: JobAgent, transcript: TranscriptRecorder) {
            self.agent = agent
            self.transcript = transcript
        }
    }

    init(database: Database, tasks: TaskStore?, now: @escaping () -> Date = Date.init) {
        self.database = database
        self.tasks = tasks
        self.now = now
        prune()
        jobs = load()
        interruptLeftovers()
    }

    var unavailable: String? { database.unavailableReason }

    func job(_ id: String) -> Job? { jobs.first { $0.id == id } }
    func job(thread: String) -> Job? { jobs.first { $0.thread == thread } }
    var running: [Job] { jobs.filter { $0.state == .running || $0.state == .needsApproval } }

    // MARK: Operations

    /// Starts a job in `folder`, or queues it when `maxRunning` jobs already run. Creates its task at once.
    @discardableResult
    func start(title: String, prompt: String, folder: URL) throws -> Job {
        let title = title.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw JobError(message: "title is required: a few words saying what the job does") }
        guard title.count <= Job.titleLimit else { throw JobError(message: "title is at most \(Job.titleLimit) characters") }
        guard !prompt.isEmpty else { throw JobError(message: "prompt is required: the full instructions for the agent that does the work") }
        guard prompt.count <= Job.promptLimit else { throw JobError(message: "prompt is at most \(Job.promptLimit) characters") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw JobError(message: "\(folder.path) is not a folder")
        }
        guard let (agent, model) = currentAgent() else { throw JobError(message: "no agent is available to run the job") }
        var job = Job(id: Job.makeID(), title: title, prompt: prompt, folder: folder.standardizedFileURL.path, agent: agent.id,
                      model: model, created: now())
        if let tasks {
            let task = try? tasks.create(title: title, notes: "Background job \(job.id) in \(folder.lastPathComponent).",
                                         status: .inProgress, source: .agent, sourceRef: job.id, by: Self.taskAuthor)
            job.task = task?.id
        }
        jobs.insert(job, at: 0)
        save(job)
        onChange(job)
        pump()
        return self.job(job.id) ?? job
    }

    /// Sends another message to a job. A running job gets it after its current turn; a finished one starts again in the same
    /// session.
    @discardableResult
    func followUp(_ id: String, message: String) throws -> Job {
        guard let job = job(id) else { throw JobError(message: "no job with id \"\(id)\"") }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw JobError(message: "message is empty") }
        guard message.count <= Job.promptLimit else { throw JobError(message: "message is at most \(Job.promptLimit) characters") }
        if let run = runs[id] {
            run.followUps.append(message)
            return job
        }
        if job.state == .queued {
            pendingFollowUps[id, default: []].append(message)
            return job
        }
        guard job.thread != nil else { throw JobError(message: "the job ended before its agent session started; start a new job instead") }
        pendingFollowUps[id, default: []].append(message)
        update(id) { job in
            job.state = .queued
            job.error = nil
            job.ended = nil
        }
        if let task = job.task, tasks?.task(task)?.status != .inProgress {
            _ = try? tasks?.update(task, status: .inProgress, note: "Follow-up: \(String(message.prefix(200)))", by: Self.taskAuthor)
        }
        pump()
        return self.job(id) ?? job
    }

    /// Stops a job. A queued one never starts; a running one gets `session/cancel` and its process is closed.
    @discardableResult
    func stop(_ id: String) throws -> Job {
        guard let job = job(id) else { throw JobError(message: "no job with id \"\(id)\"") }
        guard job.state.isActive else { return job }
        if let run = runs[id] {
            run.stopRequested = true
            for (approval, pending) in run.approvals {
                clearApproval(approval)
                pending.decide(false)
            }
            run.approvals = [:]
            run.agent.cancel()
        } else {
            pendingFollowUps[id] = nil
            finish(id, state: .stopped, note: "Stopped before it started.")
        }
        return self.job(id) ?? job
    }

    /// The last few transcript lines of a job, for `jobs_get`: reply text and tool rows, newest last.
    func recentSteps(_ id: String, limit: Int = 8) -> [String] {
        let items = runs[id]?.transcript.items ?? job(id)?.thread.flatMap(ThreadStore.load)?.items ?? []
        return items.suffix(limit).compactMap { item in
            switch item.kind {
            case .user(let text): return "Prompt: " + String(text.prefix(300))
            case .assistant(let text): return String(text.prefix(600))
            case .tool(let summary, let ok): return "Tool: \(summary)" + (ok == false ? " (failed)" : "")
            case .error(let text): return "Error: " + text
            default: return nil
            }
        }
    }

    // MARK: Running

    private var pendingFollowUps: [String: [String]] = [:]

    /// Starts queued jobs, oldest first, while there are free slots.
    private func pump() {
        let limit = max(1, maxRunning())
        while runs.count < limit, let next = jobs.last(where: { $0.state == .queued }) {
            launch(next)
        }
    }

    private func launch(_ job: Job) {
        guard let agent = AgentCatalog.agent(id: job.agent) else {
            return finish(job.id, state: .failed, error: "The agent \(job.agent) is not available any more.")
        }
        let resumed = job.thread.flatMap(ThreadStore.load)
        let run = Run(agent: makeAgent(agent), transcript: TranscriptRecorder(items: resumed?.items ?? []))
        run.followUps = pendingFollowUps.removeValue(forKey: job.id) ?? []
        runs[job.id] = run
        let id = job.id
        run.agent.onPermission = { [weak self] call, respond in self?.permission(id, call, respond) ?? respond(.deny("The job ended")) }
        update(id) { job in
            job.state = .running
            job.started = job.started ?? self.now()
        }
        Task { [weak self] in await self?.drive(id, run: run, agent: agent, resume: job.thread) }
    }

    /// Runs the first prompt (or, for a job started again, the first follow-up), then each follow-up in turn.
    private func drive(_ id: String, run: Run, agent: ACPAgent, resume: String?) async {
        guard let job = job(id) else { return }
        var prompt: String? = resume == nil ? job.prompt : (run.followUps.isEmpty ? nil : run.followUps.removeFirst())
        var outcome: String?? = .none
        while let text = prompt {
            let turn = ACPTurn(prompt: text, preamble: resume == nil && outcome == nil ? preamble(job) : nil,
                               workspace: URL(fileURLWithPath: job.folder), resume: self.job(id)?.thread, model: job.model,
                               images: [], files: [])
            run.transcript.beginTurn(.init(kind: .user(text), origin: ChatSession.jobOrigin))
            let error = await turnResult(id, run: run, turn: turn, agentName: agent.name)
            outcome = .some(error)
            saveThread(id, run: run)
            if run.stopRequested || error != nil { break }
            prompt = run.followUps.isEmpty ? nil : run.followUps.removeFirst()
        }
        for approval in run.approvals.keys { clearApproval(approval) }
        run.approvals = [:]
        run.agent.shutdown()
        runs[id] = nil
        let answer = run.transcript.answer
        if run.stopRequested {
            finish(id, state: .stopped, note: "Stopped by the user.")
        } else if case .some(.some(let error)) = outcome {
            finish(id, state: .failed, error: error)
        } else {
            finish(id, state: .done, summary: AgentSession.firstSentence(answer))
        }
        pump()
    }

    /// One turn. Returns the error that ended it, or nil.
    private func turnResult(_ id: String, run: Run, turn: ACPTurn, agentName: String) async -> String? {
        var failure: String?
        let watchdog = Task { [weak run] in
            try? await Task.sleep(for: .seconds(Self.turnTimeout))
            guard !Task.isCancelled, let run else { return }
            failure = "The agent did not finish within \(Int(Self.turnTimeout / 60)) minutes."
            run.agent.cancel()
        }
        defer { watchdog.cancel() }
        await run.agent.runTurn(turn) { [weak self] event in
            guard let self else { return }
            run.transcript.record(event)
            switch event {
            case .session(let session):
                update(id) { $0.thread = session }
                linkTask(id, thread: session)
                saveThread(id, run: run)
            case .toolStarted, .toolUpdated:
                if let step = run.transcript.lastStep, job(id)?.lastStep != step { update(id) { $0.lastStep = step } }
            case .finished(let error):
                if let error { failure = failure ?? error }
            case .needsSignIn:
                failure = "\(agentName) needs you to sign in. Open it in the chat once, then start the job again."
            case .needsRuntime:
                failure = "\(agentName) needs Node 22 or Bun. Open it in the chat once to set that up."
            default:
                break
            }
        }
        if let failure { run.transcript.append(.init(kind: .error(failure))) }
        return failure
    }

    /// Answers with the Auto policy. Anything it would still ask about (a destructive command) waits for a click.
    private func permission(_ id: String, _ call: ACPToolCall, _ respond: @escaping (ApprovalDecision) -> Void) {
        guard let run = runs[id], let job = job(id) else { return respond(.deny("The job ended")) }
        switch ApprovalRules.policy(for: call, auto: true) {
        case .allow:
            respond(.allow)
        case .ask(let title, let detail):
            let approval = "job-approval:\(UUID().uuidString)"
            run.approvals[approval] = .init(title: title, detail: detail) { [weak self, weak run] allow in
                respond(allow ? .allow : .deny())
                guard let self, let run, run.approvals.isEmpty, self.job(id)?.state == .needsApproval else { return }
                update(id) { job in
                    job.state = .running
                    job.waitingFor = nil
                }
            }
            update(id) { job in
                job.state = .needsApproval
                job.waitingFor = title
            }
            show(approval, of: id)
        }
    }

    /// Shows a waiting approval again, say after its bubble was closed without an answer.
    func showApprovals(_ id: String) {
        for approval in runs[id]?.approvals.keys.sorted() ?? [] { show(approval, of: id) }
    }

    private func show(_ approval: String, of id: String) {
        guard let pending = runs[id]?.approvals[approval], let job = job(id) else { return }
        askApproval(approval, job, pending.title, pending.detail) { [weak self] allow in
            guard let pending = self?.runs[id]?.approvals.removeValue(forKey: approval) else { return }
            pending.decide(allow)
        }
    }

    private func finish(_ id: String, state: JobState, summary: String? = nil, error: String? = nil, note: String? = nil) {
        update(id) { job in
            job.state = state
            job.ended = self.now()
            job.waitingFor = nil
            job.summary = summary ?? (state == .done ? job.summary : nil)
            job.error = error
        }
        guard let job = job(id), let task = job.task, let tasks, tasks.task(task) != nil else { return }
        switch state {
        case .done:
            _ = try? tasks.close(task, note: "Job finished" + (summary.map { ": \($0)" } ?? "."), by: Self.taskAuthor)
        case .failed:
            _ = try? tasks.update(task, status: .needsYou, note: "Job failed: \(error ?? "unknown error")", by: Self.taskAuthor)
        case .stopped:
            _ = try? tasks.close(task, note: note ?? "Stopped.", by: Self.taskAuthor)
        default:
            break
        }
    }

    private func linkTask(_ id: String, thread: String) {
        guard let job = job(id), let task = job.task, let item = tasks?.task(task),
              !item.links.contains(where: { $0.kind == .thread && $0.ref == thread }) else { return }
        _ = try? tasks?.update(task, links: item.links + [TaskLink(kind: .thread, ref: thread, label: "Job transcript")], by: Self.taskAuthor)
    }

    private func saveThread(_ id: String, run: Run) {
        guard let job = job(id), let thread = job.thread else { return }
        let saved = ChatThread(id: thread, title: job.title, workspace: job.folder, updatedAt: now(), items: run.transcript.items,
                               agent: job.agent, job: job.id)
        ThreadStore.save(saved)
        onThreadSaved(saved)
    }

    private func update(_ id: String, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[index]
        change(&job)
        guard job != jobs[index] else { return }
        jobs[index] = job
        save(job)
        onChange(job)
    }

    /// A job that was queued or running when ironpet quit has no process any more. Its task goes back to the backlog.
    private func interruptLeftovers() {
        for job in jobs where job.state.isActive {
            update(job.id) { job in
                job.state = .interrupted
                job.ended = self.now()
                job.waitingFor = nil
            }
            if let task = job.task, tasks?.task(task)?.status == .inProgress {
                _ = try? tasks?.update(task, status: .backlog, note: "ironpet quit while this job was running. Ask Ghost to run it again.",
                                       by: Self.taskAuthor)
            }
        }
    }

    // MARK: Storage

    private func save(_ job: Job) {
        do {
            try database.write { db in
                try db.execute("""
                    INSERT OR REPLACE INTO jobs(id, title, prompt, folder, agent, model, thread, task, state, last_step, summary, error,
                                                created, started, ended)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [job.id, job.title, job.prompt, job.folder, job.agent, job.model, job.thread, job.task, job.state.rawValue,
                          job.lastStep, job.summary, job.error, job.created.timeIntervalSince1970,
                          job.started?.timeIntervalSince1970, job.ended?.timeIntervalSince1970])
            }
        } catch {
            NSLog("ironpet: could not save job \(job.id): \(error.localizedDescription)")
        }
    }

    private func load() -> [Job] {
        let rows = (try? database.read { db in
            try db.rows("""
                SELECT id, title, prompt, folder, agent, model, thread, task, state, last_step, summary, error, created, started, ended
                FROM jobs ORDER BY created DESC LIMIT ?
                """, [Self.listed])
        }) ?? []
        return rows.compactMap { row in
            guard let id = row[0] as? String, let title = row[1] as? String, let prompt = row[2] as? String, let folder = row[3] as? String,
                  let agent = row[4] as? String, let state = (row[8] as? String).flatMap(JobState.init(rawValue:)),
                  let created = row[12] as? Double else { return nil }
            func date(_ value: Any?) -> Date? { (value as? Double).map(Date.init(timeIntervalSince1970:)) }
            return Job(id: id, title: title, prompt: prompt, folder: folder, agent: agent, model: row[5] as? String,
                       thread: row[6] as? String, task: row[7] as? String, state: state, lastStep: row[9] as? String,
                       summary: row[10] as? String, error: row[11] as? String, created: Date(timeIntervalSince1970: created),
                       started: date(row[13]), ended: date(row[14]))
        }
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.retention).timeIntervalSince1970
        try? database.write { try $0.execute("DELETE FROM jobs WHERE ended IS NOT NULL AND ended < ?", [cutoff]) }
    }

    // MARK: Instructions

    /// What the job's agent is told before the request: it runs unattended, and how to end.
    nonisolated static func instructions(_ job: Job) -> String {
        """
        You are running as a background job (\(job.id), "\(job.title)") that the user handed off through ironpet. Nobody is watching \
        this session: do not ask questions, make reasonable choices and note them. Work only in \(job.folder) unless the request \
        says otherwise. Commands that could destroy data wait for the user's approval in ironpet; if one is denied, find another way \
        or stop. Do not push, open pull requests, or send messages to anyone unless the request asks for it. \
        End with a short reply whose first sentence says what happened (for example "Fixed the flaky login test: it waited on a \
        fixed sleep."), then any details. ironpet keeps the task for this job up to date, so you do not need to.
        """
    }
}
