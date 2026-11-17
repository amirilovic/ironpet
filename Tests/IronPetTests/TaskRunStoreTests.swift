import XCTest
@testable import IronPet

@MainActor
final class TaskRunStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-runs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    nonisolated static func sampleRun(_ task: String = "fix-login", state: TaskRun.State = .running) -> TaskRun {
        TaskRun(task: task, repo: URL(fileURLWithPath: "/code/app"), worktree: URL(fileURLWithPath: "/w/app-1/\(task)"), branch: "ironpet/\(task)",
                base: "abc123", baseBranch: "main", agent: "claude", model: "opus", session: "s-1", state: state,
                started: Date(timeIntervalSince1970: 1_800_000_000), ended: nil, summary: "Edited 2 files", error: nil,
                pushURL: "git@github.com:you/app.git", pushRemote: "origin", gitDir: URL(fileURLWithPath: "/code/app/.git/worktrees/\(task)"),
                pushConfig: "file:/Users/me/.gitconfig\tcredential.helper osxkeychain\n")
    }

    func testMigratesAnExistingDatabaseAndAgain() throws {
        let file = dir.appendingPathComponent("ironpet.db")
        // A database that already ran the migrations numbered before 420, including 400 and 410 from other features.
        let older = AppMigrations.all.filter { $0.version < 420 }
        let (existing, _) = Database.open(path: file, migrations: older)
        try existing.write { try $0.script("PRAGMA user_version = 410") }
        XCTAssertFalse(try existing.read { try TaskStore.columns($0, "task_runs") }.contains("cleanup"))
        let (database, error) = Database.open(path: file, migrations: AppMigrations.all)
        XCTAssertNil(error)
        XCTAssertTrue(try database.read { try TaskStore.columns($0, "task_runs") }.contains("cleanup"))
        // A second run of the same SQL (a renumbered copy) must not fail.
        XCTAssertNoThrow(try database.write { try TaskRunStore.migration.apply($0) })
    }

    func testSaveLoadRoundTrip() {
        let store = TaskRunStore(database: Database.open(path: nil, migrations: AppMigrations.all).database)
        var run = Self.sampleRun()
        run.cleanup = .kept
        run.ended = Date(timeIntervalSince1970: 1_800_000_100)
        store.save(run)
        XCTAssertEqual(store.all(), [run])
        run.state = .finished
        store.save(run)
        XCTAssertEqual(store.all().map(\.state), [.finished], "one row per task")
        store.delete(run.task)
        XCTAssertTrue(store.all().isEmpty)
    }

    func testLiveRunsBecomeInterruptedAtLaunch() {
        let store = TaskRunStore(database: Database.open(path: nil, migrations: AppMigrations.all).database)
        store.save(Self.sampleRun("a", state: .running))
        store.save(Self.sampleRun("b", state: .needsApproval))
        store.save(Self.sampleRun("c", state: .finished))
        let cut = store.markInterrupted()
        XCTAssertEqual(Set(cut.map(\.task)), ["a", "b"])
        XCTAssertEqual(Set(cut.map(\.state)), [.interrupted])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: store.all().map { ($0.task, $0.state) }),
                       ["a": .interrupted, "b": .interrupted, "c": .finished])
    }

    func testPruneDropsOnlyRemovedRunsOfMissingTasks() {
        let database = Database.open(path: nil, migrations: AppMigrations.all).database
        let runs = TaskRunStore(database: database)
        var removed = Self.sampleRun("gone")
        removed.cleanup = .removed
        runs.save(removed)
        runs.save(Self.sampleRun("still-on-disk"))
        _ = TaskStore(database: database)
        XCTAssertEqual(runs.all().map(\.task), ["still-on-disk"])
    }

    // MARK: Row state

    private func task(_ status: TaskStatus = .backlog, waitingOn: String? = nil) -> TaskItem {
        TaskItem(id: "fix-login", title: "Fix login", notes: "", status: status, source: .chat, due: nil, links: [],
                 created: Date(), updated: Date(), closed: nil, waitingOn: waitingOn)
    }

    func testRowStateWithoutARun() {
        XCTAssertEqual(TaskRunRow.state(task: task(), run: nil, enabled: true, running: 0, limit: 2),
                       .idle(start: .init(enabled: true, help: "Hand this task to an agent in its own copy of the project")))
        XCTAssertEqual(TaskRunRow.state(task: task(), run: nil, enabled: true, running: 2, limit: 2),
                       .idle(start: .init(enabled: false, help: "2 tasks are already running")))
        XCTAssertEqual(TaskRunRow.state(task: task(), run: nil, enabled: false, running: 0, limit: 2), .idle(start: nil))
        XCTAssertEqual(TaskRunRow.state(task: task(.done), run: nil, enabled: true, running: 0, limit: 2), .idle(start: nil))
        XCTAssertEqual(TaskRunRow.state(task: task(waitingOn: "Ana"), run: nil, enabled: true, running: 0, limit: 2), .idle(start: nil))
    }

    func testRowStateFollowsTheRun() {
        var run = Self.sampleRun()
        run.activity = "Running `npm test`"
        XCTAssertEqual(TaskRunRow.state(task: task(.inProgress), run: run, enabled: true, running: 1, limit: 2),
                       .running(activity: "Running `npm test`"))
        run.state = .needsApproval
        run.approval = .init(id: UUID(), title: "Run this command?", detail: "npm i")
        XCTAssertEqual(TaskRunRow.state(task: task(.needsYou), run: run, enabled: true, running: 1, limit: 2),
                       .approval(title: "Run this command?", detail: "npm i"))
        run.state = .finished
        run.commits = 1
        XCTAssertEqual(TaskRunRow.state(task: task(.needsYou), run: run, enabled: true, running: 0, limit: 2),
                       .finished(summary: "Edited 2 files", canOpenPR: true, hint: nil))
        run.dirty = true
        XCTAssertEqual(TaskRunRow.state(task: task(.needsYou), run: run, enabled: true, running: 0, limit: 2),
                       .finished(summary: "Edited 2 files", canOpenPR: false,
                                 hint: "The agent left uncommitted changes. Open the chat and ask it to commit."))
        run.state = .failed
        run.error = "boom"
        XCTAssertEqual(TaskRunRow.state(task: task(.needsYou), run: run, enabled: true, running: 0, limit: 2), .failed(error: "boom"))
        run.state = .interrupted
        XCTAssertEqual(TaskRunRow.state(task: task(.needsYou), run: run, enabled: true, running: 0, limit: 2), .interrupted)
        run.state = .stopped
        if case .idle(let start) = TaskRunRow.state(task: task(), run: run, enabled: true, running: 0, limit: 2) {
            XCTAssertEqual(start?.enabled, true, "a stopped run can start again")
        } else { XCTFail("stopped shows Start") }
    }
}
