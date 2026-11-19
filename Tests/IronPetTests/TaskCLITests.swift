import XCTest
@testable import IronPet

final class TaskCLIParsingTests: XCTestCase {
    private func request(_ arguments: [String]) throws -> (op: String, args: NSDictionary) {
        let (op, args) = try TaskCLI.request(arguments)
        return (op, args as NSDictionary)
    }

    private func error(_ arguments: [String]) -> String? {
        do { _ = try TaskCLI.request(arguments); return nil } catch { return (error as? TaskError)?.message }
    }

    func testLabelOptions() throws {
        XCTAssertEqual(try request(["list", "--label", "merge=auto"]).args, ["labels": ["merge": "auto"]])
        XCTAssertEqual(try request(["list", "--label", "merge=auto", "--label", "repo=band"]).args, ["labels": ["merge": "auto", "repo": "band"]])
        XCTAssertEqual(try request(["add", "Ship", "--label", "merge=auto"]).args["labels"] as? NSDictionary, ["merge": "auto"])
        let update = try request(["update", "t", "--label", "a=1", "--unlabel", "b"])
        XCTAssertEqual(update.op, "update")
        let changes = try XCTUnwrap(update.args["changes"] as? NSDictionary)
        XCTAssertEqual(changes["labels"] as? NSDictionary, ["a": "1"])
        XCTAssertEqual(changes["remove_labels"] as? [String], ["b"])
        XCTAssertNotNil(error(["list", "--label", "nokey"]))
    }

    func testList() throws {
        XCTAssertEqual(try request(["list"]).op, "list")
        XCTAssertEqual(try request(["list"]).args, [:])
        XCTAssertEqual(try request(["list", "--all"]).args, ["include_done": true])
        XCTAssertEqual(try request(["list", "--status", "needs_you"]).args, ["status": "needs_you"])
        XCTAssertEqual(try request(["list", "--status", "backlog, in_progress"]).args, ["status": ["backlog", "in_progress"]])
    }

    func testSuggest() throws {
        let suggest = try request(["suggest", "--title", "Reply to Ana", "--id", "mail:abc", "--origin-kind", "email", "--origin-ref", "mail:abc",
                                   "--reason", "Ana asked", "--due", "2026-11-20", "--notes", "N", "--url", "https://x.test"])
        XCTAssertEqual(suggest.op, "suggest")
        XCTAssertEqual(suggest.args as NSDictionary, ["title": "Reply to Ana", "id": "mail:abc", "due": "2026-11-20", "notes": "N", "url": "https://x.test",
                                                      "origin": ["kind": "email", "ref": "mail:abc", "reason": "Ana asked"]] as NSDictionary)
    }

    func testShow() throws {
        let show = try request(["show", "write-docs"])
        XCTAssertEqual(show.op, "get")
        XCTAssertEqual(show.args, ["id": "write-docs"])
        XCTAssertEqual(error(["show"]), "show needs a task id")
    }

    func testAdd() throws {
        let plain = try request(["add", "Write", "the", "docs"])
        XCTAssertEqual(plain.op, "create")
        XCTAssertEqual(plain.args, ["title": "Write the docs"])
        let full = try request(["add", "Ship", "--notes", "After review", "it", "--due", "2026-11-20", "--status", "in_progress",
                                "--url", "https://example.com/pr/2"])
        XCTAssertEqual(full.args, ["title": "Ship it", "notes": "After review", "due": "2026-11-20", "status": "in_progress",
                                   "links": [["kind": "url", "ref": "https://example.com/pr/2"]]])
        XCTAssertEqual(try request(["add", "Send", "the", "deck", "--waiting-on", "Ana"]).args,
                       ["title": "Send the deck", "waiting_on": "Ana"])
        XCTAssertEqual(try request(["add", "Ship", "it", "--origin-kind", "pr", "--origin-ref", "u", "--reason", "r"]).args as NSDictionary,
                       ["title": "Ship it", "origin": ["kind": "pr", "ref": "u", "reason": "r"]] as NSDictionary)
        XCTAssertEqual(error(["add"]), "add needs a title")
        XCTAssertEqual(error(["add", "x", "--notes"]), "--notes needs a value")
        XCTAssertEqual(error(["add", "x", "--colour", "red"]), "unknown option --colour")
    }

    func testUpdate() throws {
        let update = try request(["update", "ship-it", "--json", #"{"title":"Ship it today","due":null}"#, "--note", "Moved up"])
        XCTAssertEqual(update.op, "update")
        XCTAssertEqual(update.args, ["id": "ship-it", "changes": ["title": "Ship it today", "due": NSNull()], "note": "Moved up"])
        XCTAssertEqual(error(["update", "ship-it"]), "update needs an id and --json '{...}'")
        XCTAssertEqual(error(["update", "ship-it", "--json", "[1]"]), "update needs an id and --json '{...}'")
    }

    func testStatus() throws {
        let status = try request(["status", "ship-it", "needs_you", "--note", "Needs your sign-off"])
        XCTAssertEqual(status.op, "update")
        XCTAssertEqual(status.args, ["id": "ship-it", "changes": ["status": "needs_you"], "note": "Needs your sign-off"])
        XCTAssertEqual(error(["status", "ship-it"]), "status needs an id and a status")
    }

    func testDoneAndDelete() throws {
        XCTAssertEqual(try request(["done", "ship-it"]).op, "close")
        XCTAssertEqual(try request(["done", "ship-it", "--note", "Merged"]).args, ["id": "ship-it", "note": "Merged"])
        let delete = try request(["delete", "ship-it"])
        XCTAssertEqual(delete.op, "delete")
        XCTAssertEqual(delete.args, ["id": "ship-it"])
        XCTAssertEqual(error(["delete"]), "delete needs a task id")
    }

    func testHelpAndUnknownCommands() {
        XCTAssertEqual(TaskCLI.execute(["help"]).code, 0)
        XCTAssertTrue(TaskCLI.execute(["--help"]).out.contains("usage: IronPet tasks"))
        XCTAssertEqual(TaskCLI.execute([]).code, 2)
        let unknown = TaskCLI.execute(["frobnicate"])
        XCTAssertEqual(unknown.code, 1)
        XCTAssertEqual(unknown.err, "ironpet: unknown command \"frobnicate\"")
    }
}

// MARK: - Through the loopback server

@MainActor
final class TaskCLIServerTests: XCTestCase {
    private var server: EventServer!
    private var store: TaskStore?
    private var savedEndpoint: (() -> (port: String, token: String)?)!

    override func setUp() async throws {
        try await super.setUp()
        store = TaskStore(database: Database.open(path: nil, migrations: AppMigrations.all).database, keepDoneDays: { 30 })
        server = EventServer(token: "test-token") { _ in }
        server.onAgentAPI = { [weak self] request, respond in
            MCPEndpoint.route(request, automations: { nil }, tasks: { self?.store.map { TasksAPI(store: $0) } }, respond: respond)
        }
        try server.start(preferredPort: 47440)
        let port = String(server.port)
        savedEndpoint = AutomationCLI.endpoint
        AutomationCLI.endpoint = { (port, "test-token") }
    }

    override func tearDown() async throws {
        AutomationCLI.endpoint = savedEndpoint
        server = nil
        store = nil
        try await super.tearDown()
    }

    private func cli(_ args: [String]) async -> (code: Int32, out: String, err: String) {
        // The CLI blocks on the server, which needs the main actor, so it runs off it.
        await Task.detached { TaskCLI.execute(args) }.value
    }

    func testAddStatusDoneAndDeleteReachTheStore() async throws {
        let incomplete = await cli(["add", "Renew", "the", "domain", "--origin-kind", "chat", "--origin-ref", "chat-1"])
        XCTAssertNotEqual(incomplete.code, 0)
        XCTAssertTrue(incomplete.err.contains("origin.reason"), incomplete.err)
        XCTAssertNil(store?.task("renew-the-domain"), "nothing is created without a full origin")
        let add = await cli(["add", "Renew", "the", "domain", "--due", "2026-12-01", "--url", "https://example.com/domains",
                             "--origin-kind", "agent", "--origin-ref", "cli-test", "--reason", "The domain expires soon"])
        XCTAssertEqual(add.code, 0, add.err)
        XCTAssertTrue(add.out.contains("\"id\" : \"renew-the-domain\""), add.out)
        let item = try XCTUnwrap(store?.task("renew-the-domain"))
        XCTAssertEqual(item.source, .agent)
        XCTAssertEqual(item.links.map(\.kind), [.url])
        XCTAssertEqual(store?.history(item.id).first?.by, "agent:cli")

        let status = await cli(["status", "renew-the-domain", "needs_you", "--note", "Card expired"])
        XCTAssertEqual(status.code, 0, status.err)
        XCTAssertEqual(store?.task("renew-the-domain")?.status, .needsYou)
        XCTAssertEqual(store?.history("renew-the-domain").last?.detail, "Card expired")

        let list = await cli(["list", "--status", "needs_you"])
        XCTAssertEqual(list.code, 0, list.err)
        XCTAssertTrue(list.out.contains("renew-the-domain"))

        let noEvidence = await cli(["done", "renew-the-domain"])
        XCTAssertNotEqual(noEvidence.code, 0)
        XCTAssertNotEqual(store?.task("renew-the-domain")?.status, .done)
        let done = await cli(["done", "renew-the-domain", "--note", "Renewed until 2027"])
        XCTAssertEqual(done.code, 0, done.err)
        XCTAssertEqual(store?.task("renew-the-domain")?.status, .done)
        let open = await cli(["list"])
        XCTAssertFalse(open.out.contains("renew-the-domain"))
        let all = await cli(["list", "--all"])
        XCTAssertTrue(all.out.contains("renew-the-domain"))

        let delete = await cli(["delete", "renew-the-domain"])
        XCTAssertEqual(delete.code, 0, delete.err)
        XCTAssertNil(store?.task("renew-the-domain"))
        let missing = await cli(["show", "renew-the-domain"])
        XCTAssertEqual(missing.code, 1)
        XCTAssertTrue(missing.err.contains("no task"), missing.err)
    }

    func testValidationErrorsArePrinted() async {
        let bad = await cli(["add", "Bad", "--status", "someday", "--origin-kind", "chat", "--origin-ref", "c", "--reason", "r"])
        XCTAssertEqual(bad.code, 1)
        XCTAssertTrue(bad.err.contains("status must be one of"), bad.err)
    }

    func testWithoutAStoreTheAppAnswers503() async {
        store = nil
        let result = await cli(["list"])
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(result.err, "ironpet: the app answered 503")
    }

    func testWithoutTheAppRunningFailsPlainly() async {
        AutomationCLI.endpoint = { nil }
        let result = await cli(["list"])
        XCTAssertEqual(result.code, 1)
        XCTAssertTrue(result.err.contains("not running"))
    }
}
