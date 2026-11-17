import Foundation

/// The latest run of each task, in `task_runs` of `ironpet.db`, so a relaunch knows which worktrees exist and which runs
/// were cut off.
@MainActor
final class TaskRunStore {
    /// One `user_version` is shared by every feature: 420 comes after welcome-back's activity log (400) and the daily brief (410).
    /// `IF NOT EXISTS`, so moving it to another number later changes nothing.
    nonisolated static let migration = Database.Migration(420, "tasks: agent runs", sql: """
        CREATE TABLE IF NOT EXISTS task_runs(task TEXT PRIMARY KEY, repo TEXT NOT NULL, worktree TEXT NOT NULL, branch TEXT NOT NULL,
                                             base TEXT NOT NULL, base_branch TEXT, agent TEXT NOT NULL, model TEXT, session TEXT,
                                             state TEXT NOT NULL, started REAL NOT NULL, ended REAL, summary TEXT, error TEXT,
                                             cleanup TEXT NOT NULL DEFAULT 'none', push_url TEXT, push_remote TEXT, git_dir TEXT,
                                             push_config TEXT) WITHOUT ROWID;
        """)

    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func all() -> [TaskRun] {
        (try? database.read { db in
            try db.rows("""
                SELECT task, repo, worktree, branch, base, base_branch, agent, model, session, state, started, ended, summary, error, cleanup,
                       push_url, push_remote, git_dir, push_config
                FROM task_runs
                """).compactMap(Self.run)
        }) ?? []
    }

    func save(_ run: TaskRun) {
        do {
            try database.write { db in
                try db.execute("""
                    INSERT OR REPLACE INTO task_runs(task, repo, worktree, branch, base, base_branch, agent, model, session, state,
                                                     started, ended, summary, error, cleanup, push_url, push_remote, git_dir, push_config)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [run.task, run.repo.path, run.worktree.path, run.branch, run.base, run.baseBranch, run.agent, run.model,
                          run.session, run.state.rawValue, run.started.timeIntervalSince1970,
                          run.ended?.timeIntervalSince1970, run.summary, run.error, run.cleanup.rawValue, run.pushURL, run.pushRemote,
                          run.gitDir?.path, run.pushConfig])
            }
        } catch {
            NSLog("ironpet: could not save the run of task \(run.task): \(error.localizedDescription)")
        }
    }

    func delete(_ task: String) {
        try? database.write { try $0.execute("DELETE FROM task_runs WHERE task = ?", [task]) }
    }

    /// Runs that were working when ironpet quit. Their agent process went with it.
    @discardableResult
    func markInterrupted(now: Date = Date()) -> [TaskRun] {
        let cut = all().filter { $0.state.isLive }.map { run in
            var run = run
            run.state = .interrupted
            run.ended = now
            return run
        }
        cut.forEach(save)
        return cut
    }

    private static func run(_ row: [Database.Value]) -> TaskRun? {
        guard let task = row[0] as? String, let repo = row[1] as? String, let worktree = row[2] as? String,
              let branch = row[3] as? String, let base = row[4] as? String, let agent = row[6] as? String,
              let state = (row[9] as? String).flatMap(TaskRun.State.init(rawValue:)), let started = row[10] as? Double else { return nil }
        return TaskRun(task: task, repo: URL(fileURLWithPath: repo), worktree: URL(fileURLWithPath: worktree), branch: branch, base: base,
                       baseBranch: row[5] as? String, agent: agent, model: row[7] as? String, session: row[8] as? String,
                       state: state, started: Date(timeIntervalSince1970: started),
                       ended: (row[11] as? Double).map(Date.init(timeIntervalSince1970:)), summary: row[12] as? String,
                       error: row[13] as? String, cleanup: (row[14] as? String).flatMap(TaskRun.Cleanup.init(rawValue:)) ?? .none,
                       pushURL: row[15] as? String, pushRemote: row[16] as? String, gitDir: (row[17] as? String).map(URL.init(fileURLWithPath:)),
                       pushConfig: row[18] as? String)
    }
}

/// For `--uninstall`: the worktrees task runs left behind. Clean ones are removed with their empty branches; one with
/// uncommitted changes stays, because removing it would lose that work.
enum TaskRunUninstall {
    @MainActor static func run(database file: URL = Paths.root.appendingPathComponent("ironpet.db")) -> [String] {
        guard FileManager.default.fileExists(atPath: file.path), let git = LoginShell.find("git")?.path else { return [] }
        let store = TaskRunStore(database: Database.open(path: file, migrations: AppMigrations.all).database)
        var lines: [String] = []
        var repos = Set<URL>()
        for run in store.all() where run.cleanup != .removed {
            repos.insert(run.repo)
            guard FileManager.default.fileExists(atPath: run.worktree.path) else { continue }
            let removed = sync(git, run.repo, ["worktree", "remove", run.worktree.path])
            guard removed.code == 0 else {
                lines.append("Kept \(run.worktree.path): \(GitWorktree.describe(removed))")
                continue
            }
            lines.append("Removed the task copy \(run.worktree.path)")
            let ahead = sync(git, run.repo, ["rev-list", "--count", "\(run.base)..\(run.branch)"])
            if ahead.code == 0, ahead.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
                _ = sync(git, run.repo, ["branch", "-d", run.branch])
            } else {
                lines.append("Kept the branch \(run.branch) in \(run.repo.path): it has the agent's commits")
            }
        }
        for repo in repos where FileManager.default.fileExists(atPath: repo.path) {
            _ = sync(git, repo, ["worktree", "prune"])
        }
        return lines
    }

    private static func sync(_ git: String, _ repo: URL, _ arguments: [String]) -> CommandResult {
        CommandRunner.runBlocking(executable: git, arguments: ["-C", repo.path] + GitWorktree.safety + arguments, timeout: 60,
                                  environment: GitWorktree.environment(), stdin: nil, maxBytes: 64 * 1024)
    }
}
