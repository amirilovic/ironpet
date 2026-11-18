import XCTest
@testable import IronPet

@MainActor
final class AssistantMCPTests: XCTestCase {
    private var folder: URL!
    private var context: AssistantContext!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        context = AssistantContext()
        context.memory = FileMemoryStore(directory: folder.appendingPathComponent("memory"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func rpc(_ method: String, _ params: [String: Any] = [:], jobScope: Bool = false) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let (_, data) = await MCPEndpoint.handle(body, automations: nil, tasks: nil, assistant: context, jobScope: jobScope)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func call(_ name: String, _ args: [String: Any] = [:], jobScope: Bool = false) async throws -> (json: [String: Any], text: String, isError: Bool) {
        let reply = try await rpc("tools/call", ["name": name, "arguments": args], jobScope: jobScope)
        let result = try XCTUnwrap(reply["result"] as? [String: Any], "\(reply)")
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        return (json, text, result["isError"] as? Bool ?? false)
    }

    private func names(jobScope: Bool) async throws -> Set<String> {
        let reply = try await rpc("tools/list", jobScope: jobScope)
        let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        return Set(tools.compactMap { $0["name"] as? String })
    }

    func testToolsAreListedAndJobsCannotStartJobs() async throws {
        let all = try await names(jobScope: false)
        XCTAssertTrue(all.isSuperset(of: ["jobs_start", "jobs_list", "jobs_get", "jobs_followup", "jobs_stop", "jobs_open",
                                          "projects_resolve", "status_overview", "status_sessions", "status_alerts", "status_today",
                                          "status_meetings", "memory_recall", "memory_remember", "memory_forget", "memory_list"]))
        let inJob = try await names(jobScope: true)
        XCTAssertTrue(inJob.isDisjoint(with: MCPEndpoint.jobOnlyHidden))
        XCTAssertTrue(inJob.contains("status_overview"))
        let refused = try await call("jobs_start", ["title": "x", "prompt": "y", "folder": folder.path], jobScope: true)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("not available inside a background job"))
    }

    func testReadOnlyAssistantToolsSkipApprovalButStartingAJobAsks() {
        for tool in ["status_overview", "jobs_list", "memory_remember", "projects_resolve"] {
            XCTAssertTrue(ApprovalRules.isOwnTaskTool(server: "ironpet", tool: tool), tool)
        }
        for tool in ["jobs_start", "jobs_followup", "jobs_stop"] {
            XCTAssertFalse(ApprovalRules.isOwnTaskTool(server: "ironpet", tool: tool), tool)
        }
    }

    func testJobScopeAddsTheVariableOnlyToIronpetsServer() {
        let servers: [JSON] = [["name": "ironpet", "command": "/x", "args": ["mcp"], "env": [] as [JSON]], ["name": "other", "command": "/y"]]
        let scoped = MCPEndpoint.jobScoped(servers)
        XCTAssertEqual((scoped[0]["env"] as? [JSON])?.first?["value"] as? String, "job")
        XCTAssertNil(scoped[1]["env"])
    }

    func testJobsStartOnlyAcceptsAKnownFolder() async throws {
        let database = Database.open(path: nil, migrations: TaskStore.migrations + JobService.migrations).database
        let jobs = JobService(database: database, tasks: nil)
        jobs.currentAgent = { nil }
        context.jobs = { jobs }
        let cursorURL = try XCTUnwrap(URL(string: "file://" + folder.path + "/"))
        context.projects = { ProjectResolver.candidates(frontmost: cursorURL, chat: nil, cursor: [], recents: [], scratch: URL(fileURLWithPath: "/tmp/scratch")) }

        let invented = try await call("jobs_start", ["title": "Fix", "prompt": "Fix it", "folder": "/tmp/made-up"])
        XCTAssertTrue(invented.isError)
        XCTAssertTrue(invented.text.contains("projects_resolve"))

        let known = try await call("jobs_start", ["title": "Fix", "prompt": "Fix it", "folder": folder.path])
        XCTAssertTrue(known.isError, "no agent in this test")
        XCTAssertTrue(known.text.contains("no agent"))
    }

    func testMemoryToolsRememberListAndForget() async throws {
        let saved = try await call("memory_remember", ["text": "Prefers short answers", "kind": "fact"])
        XCTAssertFalse(saved.isError, saved.text)
        _ = try await call("memory_remember", ["text": "Sara leads the payments team", "kind": "person"])

        let recall = try await call("memory_recall")
        XCTAssertTrue((recall.json["memory"] as? String ?? "").contains("Sara leads the payments team"))
        let people = try await call("memory_list", ["kind": "person"])
        XCTAssertEqual((people.json["entries"] as? [[String: Any]])?.count, 1)

        let forgot = try await call("memory_forget", ["text": "payments"])
        XCTAssertEqual(forgot.json["forgotten"] as? [String], ["Sara leads the payments team"])
        let secret = try await call("memory_remember", ["text": "my token is ghp_abcdefghijklmnopqrstuvwxyz0123456789", "kind": "fact"])
        XCTAssertTrue(secret.isError)
        let badKind = try await call("memory_remember", ["text": "x y z", "kind": "dream"])
        XCTAssertTrue(badKind.isError)
    }

    func testStatusOverviewGathersSessionsAlertsAndTasks() async throws {
        let tasks = TaskStore(database: Database.open(path: nil, migrations: TaskStore.migrations).database)
        _ = try tasks.create(title: "Review Sara's PR", status: .needsYou, source: .user, by: "user")
        context.tasks = { tasks }
        var waiting = AgentSession(id: "claude:1", source: .claude, status: .needsInput, prompt: "Migrate the db")
        waiting.origin.workspace = "/Users/me/kokous"
        context.sessions = { [waiting] }
        context.alerts = { [Signal(id: "ci", title: "main is red", subtitle: "ironpet", url: nil, label: "CI failed", symbol: "xmark", mood: .failed)] }

        let overview = try await call("status_overview")
        XCTAssertFalse(overview.isError, overview.text)
        let sessions = try XCTUnwrap(overview.json["sessions"] as? [String: Any])
        XCTAssertEqual((sessions["need_you"] as? [[String: Any]])?.first?["project"] as? String, "kokous")
        XCTAssertEqual(((overview.json["tasks"] as? [String: Any])?["needs_you"] as? [[String: Any]])?.first?["title"] as? String, "Review Sara's PR")
        XCTAssertEqual((overview.json["alerts"] as? [[String: Any]])?.first?["title"] as? String, "main is red")
    }

    func testJobsOpenReportsWhyItCannotOpen() async throws {
        let database = Database.open(path: nil, migrations: JobService.migrations).database
        let jobs = JobService(database: database, tasks: nil)
        context.jobs = { jobs }
        let missing = try await call("jobs_open", ["id": "job-nope"])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("no job"))
    }
}

final class ProjectResolverTests: XCTestCase {
    private let scratch = URL(fileURLWithPath: "/Users/me/.ironpet/scratch")

    private func candidates(frontmost: URL? = nil) -> [ProjectCandidate] {
        ProjectResolver.candidates(frontmost: frontmost, chat: URL(fileURLWithPath: "/Users/me/ironpet"),
                                   cursor: [URL(fileURLWithPath: "/Users/me/kokous-app"), URL(fileURLWithPath: "/Users/me/ironpet")],
                                   recents: [URL(fileURLWithPath: "/Users/me/avaus"), URL(fileURLWithPath: "/Users/me/avaus-web"), scratch],
                                   scratch: scratch, exists: { _ in true })
    }

    func testCandidatesMergeSourcesAndEndWithNoProject() {
        let list = candidates()
        XCTAssertEqual(list.map(\.name), ["ironpet", "kokous-app", "avaus", "avaus-web", "No project"])
        XCTAssertEqual(list[0].sources, [.chat, .cursor])
    }

    func testMissingFoldersAreDropped() {
        let list = ProjectResolver.candidates(frontmost: nil, chat: URL(fileURLWithPath: "/gone"), cursor: [], recents: [],
                                              scratch: scratch, exists: { _ in false })
        XCTAssertEqual(list.map(\.name), ["No project"])
    }

    func testSpokenNamesMatch() {
        XCTAssertEqual(ProjectResolver.resolve("the Iron Pet repo", in: candidates()).best?.name, "ironpet")
        XCTAssertEqual(ProjectResolver.resolve("kokous", in: candidates()).best?.name, "kokous-app")
        XCTAssertEqual(ProjectResolver.resolve("avaus", in: candidates()).best?.name, "avaus", "an exact name beats a longer one")
        XCTAssertEqual(ProjectResolver.resolve("no project", in: candidates()).best?.name, "No project")
    }

    func testAmbiguousAndUnknownNamesHaveNoBest() {
        let ambiguous = ProjectResolver.resolve("ava", in: candidates())
        XCTAssertNil(ambiguous.best)
        XCTAssertTrue(ambiguous.ambiguous)
        XCTAssertEqual(ambiguous.matches.map(\.name), ["avaus", "avaus-web"])
        let unknown = ProjectResolver.resolve("zebra", in: candidates())
        XCTAssertNil(unknown.best)
        XCTAssertFalse(unknown.ambiguous)
    }

    func testCursorURLsAndPathsOfTheSameFolderAreOneCandidate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("resolver-\(UUID().uuidString)/ironpet")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let cursor = try XCTUnwrap(URL(string: "file://" + folder.path + "/"))
        let list = ProjectResolver.candidates(frontmost: cursor, chat: nil, cursor: [cursor], sessions: [URL(fileURLWithPath: folder.path)],
                                              recents: [URL(fileURLWithPath: folder.path, isDirectory: true)], scratch: scratch)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].sources, [.frontmost, .cursor, .session, .recent])
        XCTAssertEqual(ProjectResolver.resolve("ironpet", in: list).best?.url.path, folder.path)
        XCTAssertNotNil(ProjectResolver.candidate(at: folder.path + "/", in: list))
        XCTAssertNotNil(ProjectResolver.candidate(at: folder.path, in: list))
        XCTAssertNil(ProjectResolver.candidate(at: folder.path + "-other", in: list))
    }

    func testNoNamePrefersTheFrontmostProject() {
        XCTAssertEqual(ProjectResolver.resolve(nil, in: candidates()).best?.name, "ironpet")
        XCTAssertEqual(ProjectResolver.resolve("", in: candidates(frontmost: URL(fileURLWithPath: "/Users/me/avaus-web"))).best?.name, "avaus-web")
    }
}
