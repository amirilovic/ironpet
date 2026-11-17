import Foundation

/// The latest run of each task, in `task_runs` of `ironpet.db`, so a relaunch knows which worktrees exist and which runs
/// were cut off.
@MainActor
final class TaskRunStore {
    /// Numbered after tasks' 305. `IF NOT EXISTS`, so moving it to another number later changes nothing.
    nonisolated static let migration = Database.Migration(306, "tasks: agent runs", sql: """
        CREATE TABLE IF NOT EXISTS task_runs(task TEXT PRIMARY KEY, repo TEXT NOT NULL, worktree TEXT NOT NULL, branch TEXT NOT NULL,
                                             base TEXT NOT NULL, base_branch TEXT, agent TEXT NOT NULL, model TEXT, session TEXT,
                                             auto INTEGER NOT NULL, state TEXT NOT NULL, started REAL NOT NULL, ended REAL,
                                             summary TEXT, error TEXT, cleanup TEXT NOT NULL DEFAULT 'none') WITHOUT ROWID;
        """)

    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func all() -> [TaskRun] {
        (try? database.read { db in
            try db.rows("""
                SELECT task, repo, worktree, branch, base, base_branch, agent, model, session, auto, state, started, ended, summary, error, cleanup
                FROM task_runs
                """).compactMap(Self.run)
        }) ?? []
    }

    func save(_ run: TaskRun) {
        do {
            try database.write { db in
                try db.execute("""
                    INSERT OR REPLACE INTO task_runs(task, repo, worktree, branch, base, base_branch, agent, model, session, auto, state,
                                                     started, ended, summary, error, cleanup)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [run.task, run.repo.path, run.worktree.path, run.branch, run.base, run.baseBranch, run.agent, run.model,
                          run.session, run.auto ? 1 : 0, run.state.rawValue, run.started.timeIntervalSince1970,
                          run.ended?.timeIntervalSince1970, run.summary, run.error, run.cleanup.rawValue])
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
        let cut = all().filter { $0.state.isLive }
        for var run in cut {
            run.state = .interrupted
            run.ended = now
            save(run)
        }
        return cut
    }

    private static func run(_ row: [Database.Value]) -> TaskRun? {
        guard let task = row[0] as? String, let repo = row[1] as? String, let worktree = row[2] as? String,
              let branch = row[3] as? String, let base = row[4] as? String, let agent = row[6] as? String,
              let state = (row[10] as? String).flatMap(TaskRun.State.init(rawValue:)), let started = row[11] as? Double else { return nil }
        return TaskRun(task: task, repo: URL(fileURLWithPath: repo), worktree: URL(fileURLWithPath: worktree), branch: branch, base: base,
                       baseBranch: row[5] as? String, agent: agent, model: row[7] as? String, session: row[8] as? String,
                       auto: (row[9] as? Int64 ?? 0) != 0, state: state, started: Date(timeIntervalSince1970: started),
                       ended: (row[12] as? Double).map(Date.init(timeIntervalSince1970:)), summary: row[13] as? String,
                       error: row[14] as? String, cleanup: (row[15] as? String).flatMap(TaskRun.Cleanup.init(rawValue:)) ?? .none)
    }
}
