import Foundation

/// An agent working on a task in its own git worktree, started with Start in the Tasks section. One per task: a new
/// Start or Retry continues the same worktree and session.
struct TaskRun: Identifiable, Equatable {
    enum State: String, CaseIterable {
        case starting, running
        case needsApproval = "needs_approval"
        case finished, failed, stopped, interrupted

        /// The agent process is working or waiting on the user.
        var isLive: Bool { self == .starting || self == .running || self == .needsApproval }
    }

    /// What happened to the worktree after the task was closed or deleted.
    enum Cleanup: String {
        case none
        /// The worktree is gone.
        case removed
        /// It had uncommitted changes, so it stays until Remove Copy.
        case kept
    }

    var id: String { task }
    let task: String
    /// The main working copy the worktree came from.
    var repo: URL
    var worktree: URL
    var branch: String
    /// The commit the branch started from.
    var base: String
    /// The branch the working copy was on, for the PR base and the push remote. Nil when detached.
    var baseBranch: String?
    var agent: String
    var model: String?
    /// The ACP session id, which is also the chat thread id.
    var session: String?
    var state: State
    var started: Date
    var ended: Date?
    /// "Edited 3 files · First sentence of the reply."
    var summary: String?
    var error: String?
    var cleanup: Cleanup = .none
    /// Where Open PR may push: the push URL of the push remote when the run was created. Open PR refuses when it changed.
    var pushURL: String? = nil
    /// The remote `pushURL` belongs to, read from the main working copy's config at Start.
    var pushRemote: String? = nil
    /// The copy's git folder, resolved when git made the worktree. ironpet's git calls on the copy use it, and Open PR
    /// refuses when the copy's `.git` file no longer points there.
    var gitDir: URL? = nil
    /// The copy's config that can redirect or authenticate a push (`GitWorktree.pushConfigPattern`), read in the copy
    /// at Start. Open PR refuses when it changed, so an include or `insteadOf` the agent added cannot steer the push.
    var pushConfig: String? = nil

    // Not stored: refreshed from git and the running turn.
    /// "Running `npm test`", "Thinking".
    var activity: String?
    /// Commits on the branch that `base` does not have.
    var commits = 0
    /// Uncommitted changes in the worktree.
    var dirty = false
    /// The approval card waiting in this run, if any.
    var approval: Approval?
    /// Remotes with their own `pushurl`, which the agent's push block does not cover. Commands still ask.
    var unblockedRemotes: [String] = []

    struct Approval: Equatable {
        let id: UUID
        let title: String
        let detail: String
        /// False when the agent offered no allow-once answer: the request can only be denied.
        var canAllow = true

        /// Whether a bubble or notification, which show only the start of the detail, may offer Allow. A longer detail
        /// is allowed only where all of it shows: the task row, the Agents list or the chat strip.
        var allowableAtAGlance: Bool { canAllow && Self.fitsAtAGlance(detail) }

        static let glanceLimit = 240

        static func fitsAtAGlance(_ detail: String) -> Bool {
            detail.count <= glanceLimit && detail.split(separator: "\n", omittingEmptySubsequences: false).count <= 4
        }
    }

    var agentName: String { AgentCatalog.agent(id: agent)?.name ?? agent }

    var copy: GitWorktree.Copy? { gitDir.map { GitWorktree.Copy(worktree: worktree, gitDir: $0) } }

    /// Open PR pushes only committed work.
    var canOpenPR: Bool { !state.isLive && cleanup != .removed && commits > 0 && !dirty }

    /// Why Open PR is disabled, for its tooltip. Nil when it is enabled.
    var openPRHint: String? {
        if canOpenPR { return nil }
        if dirty { return "The agent left uncommitted changes. Open the chat and ask it to commit." }
        if commits == 0 { return "The agent has not committed anything on \(branch) yet." }
        return nil
    }
}

/// What a task row shows for its run: the rule behind the buttons, kept out of the view so tests reach it.
enum TaskRunRow: Equatable {
    /// No run, or one that ended long ago. `start` is nil when Start is hidden, else whether it is enabled and why not.
    case idle(start: StartButton?)
    case running(activity: String)
    case approval(title: String, detail: String)
    case finished(summary: String?, canOpenPR: Bool, hint: String?)
    case failed(error: String)
    case interrupted

    struct StartButton: Equatable {
        let enabled: Bool
        let help: String
    }

    static func state(task: TaskItem, run: TaskRun?, enabled: Bool, running: Int, limit: Int, starting: Bool = false) -> TaskRunRow {
        if starting, run?.state.isLive != true { return .running(activity: "Starting…") }
        if let run, run.cleanup != .removed {
            switch run.state {
            case .starting: return .running(activity: "Starting")
            case .running: return .running(activity: run.activity ?? "Working")
            case .needsApproval:
                return run.approval.map { .approval(title: $0.title, detail: $0.detail) } ?? .running(activity: "Waiting for you")
            case .finished: return .finished(summary: run.summary, canOpenPR: run.canOpenPR, hint: run.openPRHint)
            case .failed: return .failed(error: run.error ?? "The agent stopped.")
            case .interrupted: return .interrupted
            case .stopped: break
            }
        }
        guard enabled, task.status != .done, task.waitingOn == nil else { return .idle(start: nil) }
        if running >= limit {
            return .idle(start: StartButton(enabled: false, help: "\(running) \(running == 1 ? "task is" : "tasks are") already running"))
        }
        return .idle(start: StartButton(enabled: true, help: "Hand this task to an agent in its own copy of the project"))
    }
}
