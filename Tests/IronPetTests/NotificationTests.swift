import XCTest
@testable import IronPet

/// The notification store: every bubble kept with its full text and links.
@MainActor
final class NotificationStoreTests: XCTestCase {
    private var dir: URL!
    private var clock = Date(timeIntervalSince1970: 1_774_008_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("notifications-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func memoryStore() throws -> NotificationStore {
        NotificationStore(database: try Database(path: nil, migrations: AppMigrations.all), now: { [unowned self] in clock })
    }

    private func draft(_ title: String, source: String = "mail", type: NotificationType = .reminder, description: String = "",
                       links: [NotificationLink] = []) -> NotificationDraft {
        NotificationDraft(source: source, type: type, title: title, description: description, links: links)
    }

    // S3
    func testReadStateAndTheUnreadCount() throws {
        let store = try memoryStore()
        let a = try XCTUnwrap(store.add(draft("A")))
        _ = store.add(draft("B"))
        XCTAssertEqual(store.unreadCount, 2)
        store.markRead(a.id)
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(store.get(a.id)?.read, clock)
        store.markRead(a.id)
        XCTAssertEqual(store.unreadCount, 1, "reading twice changes nothing")
        store.markAllRead()
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertEqual(store.list(.init(unreadOnly: true)).count, 0)
    }

    // S4
    func testRowsAndReadStateSurviveReopeningTheDatabase() throws {
        let file = dir.appendingPathComponent("ironpet.db")
        var store: NotificationStore? = NotificationStore(database: try Database(path: file, migrations: AppMigrations.all), now: { [unowned self] in clock })
        let link = NotificationLink(.thread, "t1", label: "Run")
        let first = try XCTUnwrap(store?.add(draft("Report", type: .backgroundResult, description: "Line one\n\nLine two", links: [link])))
        _ = store?.add(draft("Other"))
        store?.markRead(first.id)
        store = nil

        let reopened = NotificationStore(database: try Database(path: file, migrations: AppMigrations.all), now: { [unowned self] in clock })
        XCTAssertEqual(reopened.unreadCount, 1)
        let item = try XCTUnwrap(reopened.get(first.id))
        XCTAssertEqual(item.description, "Line one\n\nLine two")
        XCTAssertEqual(item.links, [link])
        XCTAssertEqual(item.read, clock)
        XCTAssertEqual(item.type, .backgroundResult)
    }

    func testMigrationAddsTheTablesToAFileFromTheVersionBefore() throws {
        let file = dir.appendingPathComponent("ironpet.db")
        let before = AppMigrations.all.filter { $0.version < 530 }
        XCTAssertEqual(try Database(path: file, migrations: before).schemaVersion, before.map(\.version).max())
        let store = NotificationStore(database: try Database(path: file, migrations: AppMigrations.all))
        XCTAssertNotNil(store.add(draft("New")))
        XCTAssertEqual(NotificationStore.migrations.map(\.version), [530])
    }

    func testListIsNewestFirstAndFilters() throws {
        let store = try memoryStore()
        _ = store.add(draft("Old", source: "mail"))
        clock = clock.addingTimeInterval(60)
        _ = store.add(draft("Mid", source: "ci", type: .scriptBubble))
        clock = clock.addingTimeInterval(60)
        _ = store.add(draft("New", source: "mail", type: .backgroundResult))
        XCTAssertEqual(store.list().map(\.title), ["New", "Mid", "Old"])
        XCTAssertEqual(store.list(.init(source: "mail")).map(\.title), ["New", "Old"])
        XCTAssertEqual(store.list(.init(type: .scriptBubble)).map(\.title), ["Mid"])
        XCTAssertEqual(store.list(.init(since: clock.addingTimeInterval(-60))).map(\.title), ["New", "Mid"])
        XCTAssertEqual(store.list(.init(until: clock.addingTimeInterval(-60))).map(\.title), ["Old"])
        XCTAssertEqual(store.list(.init(limit: 1)).map(\.title), ["New"])
        XCTAssertEqual(store.sources(), ["ci", "mail"])
    }

    func testSummaryDefaultsToTheFirstLineOrFirst140Characters() throws {
        let store = try memoryStore()
        let heading = try XCTUnwrap(store.add(draft("T", description: "## Findings\nSecond line")))
        XCTAssertEqual(heading.summary, "Findings")
        let long = try XCTUnwrap(store.add(draft("T", description: String(repeating: "word ", count: 60))))
        XCTAssertEqual(long.summary.count, 140)
        XCTAssertTrue(long.summary.hasSuffix("…"))
        XCTAssertEqual(NotificationDraft.summary(of: "Drafted **v2.4** with `swift test`"), "Drafted v2.4 with swift test")
        let bare = try XCTUnwrap(store.add(draft("Only a title")))
        XCTAssertEqual(bare.summary, "Only a title")
    }

    func testDescriptionIsCappedAtSixtyFourKiBWithoutSplittingACharacter() throws {
        let store = try memoryStore()
        let big = String(repeating: "é", count: 40_000)
        let item = try XCTUnwrap(store.add(draft("Big", description: big)))
        XCTAssertLessThanOrEqual(item.description.utf8.count, NotificationDraft.maxDescription + "\n(cut off)".utf8.count)
        XCTAssertTrue(item.description.hasSuffix("(cut off)"))
        XCTAssertEqual(store.get(item.id)?.description, item.description)
    }

    func testRowsOlderThanNinetyDaysArePrunedAndNothingElseIs() throws {
        let store = try memoryStore()
        let old = try XCTUnwrap(store.add(draft("Old", links: [NotificationLink(.task, "t")])))
        clock = clock.addingTimeInterval(89 * 86_400)
        let recent = try XCTUnwrap(store.add(draft("Recent")))
        store.markRead(old.id)
        clock = clock.addingTimeInterval(2 * 86_400)
        store.prune()
        XCTAssertNil(store.get(old.id))
        XCTAssertNotNil(store.get(recent.id))
        XCTAssertEqual(store.unreadCount, 1)
    }

    // S5
    func testLinksKeepOnlyValidKindsAndHttpURLs() {
        let parsed = NotificationLink.parse([
            ["kind": "url", "ref": "https://example.com/pr/1", "label": "PR"],
            ["kind": "task", "ref": "t-1"],
            ["kind": "url", "ref": "ftp://example.com/x"],
            ["kind": "url", "ref": "javascript:alert(1)"],
            ["kind": "email", "ref": "a@b.c"],
            ["kind": "file", "ref": ""],
            "not an object",
        ])
        XCTAssertEqual(parsed.links.map(\.kind), [.url, .task])
        XCTAssertEqual(parsed.links.first?.label, "PR")
        XCTAssertEqual(parsed.dropped, 5)
        let many = NotificationLink.parse((0..<15).map { ["kind": "task", "ref": "t\($0)"] })
        XCTAssertEqual(many.links.count, NotificationLink.maxLinks)
        XCTAssertEqual(many.dropped, 5)
    }

    func testEachLinkKindOpensItsTarget() {
        var opened: [String] = []
        let opener = NotificationLinkOpener(openURL: { opened.append("url \($0.absoluteString)") },
                                            openFile: { opened.append("file \($0.path)") },
                                            openThread: { opened.append("thread \($0)") }, openSession: { opened.append("session \($0)") },
                                            openTask: { opened.append("task \($0)") }, openAlert: { opened.append("alert \($0)") })
        for link in [NotificationLink(.url, "https://example.com"), NotificationLink(.file, "/tmp/report.md"), NotificationLink(.thread, "t1"),
                     NotificationLink(.session, "s1"), NotificationLink(.task, "task-9"), NotificationLink(.alert, "automation:a:b"),
                     NotificationLink(.url, "file:///etc/passwd")] {
            opener.open(link)
        }
        XCTAssertEqual(opened, ["url https://example.com", "file /tmp/report.md", "thread t1", "session s1", "task task-9", "alert automation:a:b"])
    }

    // S2
    func testABubbleClickSelectsTheEntryAndMarksItRead() throws {
        let store = try memoryStore()
        let item = try XCTUnwrap(store.add(draft("Report", description: "Full text")))
        let model = NotificationsModel(store: store)
        XCTAssertEqual(model.unread, 1)
        let window = IronPetWindowModel(defaults: UserDefaults(suiteName: "notif-\(UUID().uuidString)")!)
        window.openNotification(item.id)
        XCTAssertEqual(window.section, .notifications)
        XCTAssertEqual(window.focusNotification, item.id)
        model.select(item.id)
        XCTAssertEqual(model.expanded, item.id)
        XCTAssertEqual(model.unread, 0)
        XCTAssertEqual(model.items.first?.description, "Full text")
        model.toggle(item.id)
        XCTAssertNil(model.expanded)
    }

    func testTheSectionSitsNextToAlertsAndHidesBubbles() {
        let all = IronPetSection.shown(chat: true, transcripts: true, automations: true)
        let alerts = all.firstIndex(of: .alerts)!
        XCTAssertEqual(all[alerts + 1], .notifications)
        XCTAssertTrue(IronPetSection.notifications.hidesBubbles)
        XCTAssertFalse(IronPetSection.shown(chat: true, transcripts: true, automations: true, notifications: false).contains(.notifications))
    }
}

/// What the automation service stores when it shows a bubble.
@MainActor
final class NotificationServiceTests: AutomationTestCase {
    private var threads: URL!
    private var savedThreads: URL!
    private var store: NotificationStore!

    override func setUp() async throws {
        try await super.setUp()
        savedThreads = ThreadStore.directory
        ThreadStore.directory = dir.appendingPathComponent("threads")
        store = NotificationStore(database: try Database(path: nil, migrations: AppMigrations.all))
    }

    override func tearDown() async throws {
        ThreadStore.directory = savedThreads
        try await super.tearDown()
    }

    private func job(quiet: String? = nil) -> Automation {
        Automation(id: "mail", name: "Check mail", trigger: .init(type: "interval", minutes: 60, clock: "wall"),
                   action: .init(type: "prompt", prompt: "Check my mail", agent: "cursor", quiet: quiet, session: "own"))
    }

    private let report = "Checked 3 mails.\n\nTwo need a reply:\n- Invoice from a vendor\n- Question about Friday\n\nThe third is a newsletter."

    // S1
    func testALongBackgroundReplyBecomesTheDescriptionAndTheBubbleShowsOneLine() async {
        let rig = makeRig([job()])
        rig.service.notifications = store
        rig.service.latestThread = { _ in "thread-7" }
        rig.service.runSession = { [report] _, _ in .success(report) }
        run(rig, minutes: 60)
        await until("the notification") { self.store.list().count == 1 }

        let item = store.list()[0]
        XCTAssertEqual(item.title, "Check mail")
        XCTAssertEqual(item.source, "mail")
        XCTAssertEqual(item.type, .backgroundResult)
        XCTAssertEqual(item.summary, "Checked 3 mails.")
        XCTAssertEqual(item.description, report)
        XCTAssertEqual(item.links, [NotificationLink(.thread, "thread-7", label: "Run in chat history")])
        let notice = rig.notices.last("automation:mail")
        XCTAssertEqual(notice?.title, "Check mail")
        XCTAssertEqual(notice?.body, "Checked 3 mails.")
        XCTAssertEqual(notice?.notificationID, item.id)
    }

    // S7
    func testAQuietRunStoresNothing() async {
        let rig = makeRig([job(quiet: "NOTHING_NEW")])
        rig.service.notifications = store
        rig.service.runSession = { _, _ in .success("NOTHING_NEW") }
        run(rig, minutes: 60)
        await until("the quiet run") { rig.service.history("mail", limit: 5).first?["output"] as? String == "no changes" }
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertNil(rig.notices.last("automation:mail"))
    }

    // S3
    func testDoneMarksTheNotificationReadAndSnoozeLeavesItUnread() {
        let rig = makeRig([bubble("water", minutes: 5)])
        rig.service.notifications = store
        run(rig, minutes: 5)
        let notice = rig.notices.last("automation:water")
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(store.list().first?.type, .reminder)
        let snooze = notice?.buttons.first { $0.title.hasPrefix("Snooze") }
        snooze?.run()
        XCTAssertEqual(store.unreadCount, 1)
        notice?.buttons.first { $0.title == "Done" }?.run()
        XCTAssertEqual(store.unreadCount, 0)
    }

    // S5
    func testAScriptBubbleStoresItsDescriptionAndValidLinks() {
        let a = bubble("script", minutes: 60)
        let rig = makeRig([a])
        rig.service.notifications = store
        rig.service.perform([["type": "bubble", "title": "Release ready", "body": "v2 is out", "description": "## Notes\nAll green.",
                              "links": [["kind": "url", "ref": "https://example.com/release", "label": "Release"],
                                        ["kind": "task", "ref": "ship-v2"],
                                        ["kind": "carrier-pigeon", "ref": "x"],
                                        ["kind": "url", "ref": "ftp://example.com/x"]]]], for: a, firstRun: false)
        let item = store.list().first
        XCTAssertEqual(item?.type, .scriptBubble)
        XCTAssertEqual(item?.title, "Release ready")
        XCTAssertEqual(item?.description, "## Notes\nAll green.")
        XCTAssertEqual(item?.links.map(\.kind), [.url, .task])
        XCTAssertTrue((rig.service.history("script", limit: 5).first?["output"] as? String ?? "").contains("2 link(s) left out"))
    }

    func testAnAlertCarriesItsDescriptionAndLinksToTheSignal() {
        let a = bubble("ci", minutes: 60)
        let rig = makeRig([a])
        var signals: [Signal] = []
        rig.service.alert = { signal, _ in signals.append(signal) }
        rig.service.perform([["type": "alert", "id": "pr1", "title": "CI failed", "description": "3 tests failed",
                              "links": [["kind": "session", "ref": "s9"]]]], for: a, firstRun: false)
        XCTAssertEqual(signals.first?.detail, "3 tests failed")
        XCTAssertEqual(signals.first?.links, [NotificationLink(.session, "s9")])
        let draft = NotificationDraft(signal: signals[0])
        XCTAssertEqual(draft.type, .alertAnnouncement)
        XCTAssertEqual(draft.source, "ci")
        XCTAssertEqual(draft.links.map(\.kind), [.session, .alert])
        XCTAssertEqual(draft.description, "3 tests failed")
    }

    func testAnApprovalRequestIsStoredAsAnApproval() {
        let danger = Automation(id: "danger", name: "Danger", trigger: .init(type: "interval", minutes: 5, clock: "wall"),
                                action: .init(type: "shell", command: "echo hi"), createdBy: "agent:mcp")
        let rig = makeRig([danger])
        rig.service.notifications = store
        // The first ask came while the rig started; a run asks again.
        run(rig, minutes: 5)
        let item = store.list().first
        XCTAssertEqual(item?.type, .approval)
        XCTAssertEqual(item?.source, "danger")
        XCTAssertTrue(item?.description.contains("echo hi") == true)
    }
}

/// The bubbles that do not come from an automation. `Announcer` needs a `Notifier`, which cannot start outside an app bundle, so
/// the drafts it stores are tested directly.
@MainActor
final class NotificationDraftTests: XCTestCase {
    func testAnAlertAnnouncementKeepsItsURLAndLinksToTheAlert() {
        let signal = Signal(id: "automation:github:pr-84", title: "Fix login", subtitle: "demo/app #84", url: URL(string: "https://example.com/pull/84"),
                            label: "CI failed", symbol: "xmark.octagon.fill", mood: .failed, ask: nil)
        let draft = NotificationDraft(signal: signal)
        XCTAssertEqual(draft.type, .alertAnnouncement)
        XCTAssertEqual(draft.source, "github")
        XCTAssertEqual(draft.title, "CI failed: Fix login")
        XCTAssertEqual(draft.links.map(\.kind), [.url, .alert])
        XCTAssertEqual(NotificationDraft(signal: Signal(id: "other", title: "t", subtitle: "", url: nil, label: "l", symbol: "bell", mood: .done)).source, "system")
    }

    func testANoticeBecomesADraftWithItsURLAsALink() {
        var notice = AutomationNotice(id: "n", symbol: "bell", title: "Title", body: "First line\nSecond line", automationIDs: ["mail"],
                                      url: URL(string: "https://example.com/x"))
        notice.notificationType = .scriptBubble
        let draft = NotificationDraft(notice: notice)
        XCTAssertEqual(draft.source, "mail")
        XCTAssertEqual(draft.summary, "First line")
        XCTAssertEqual(draft.description, "First line\nSecond line")
        XCTAssertEqual(draft.links, [NotificationLink(.url, "https://example.com/x")])
        XCTAssertEqual(NotificationDraft(notice: AutomationNotice(id: "m", symbol: "bell", title: "T")).source, "system")
    }
}

/// The agent-facing tools and the CLI.
@MainActor
final class NotificationMCPTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_774_008_000)
    private var store: NotificationStore!

    override func setUpWithError() throws {
        store = NotificationStore(database: try Database(path: nil, migrations: AppMigrations.all), now: { [unowned self] in clock })
    }

    private func result(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        switch NotificationMCP.call(name, args, store: store, now: clock) {
        case .success(let value): return try XCTUnwrap(value as? [String: Any])
        case .failure(let error): throw error
        }
    }

    // S6
    func testListReturnsTodaysNotificationsNewestFirstAndGetReturnsTheFullText() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: clock)
        clock = today.addingTimeInterval(-3600)
        _ = store.add(NotificationDraft(source: "mail", type: .reminder, title: "Yesterday"))
        clock = today.addingTimeInterval(3600)
        _ = store.add(NotificationDraft(source: "mail", type: .reminder, title: "First today"))
        clock = today.addingTimeInterval(7200)
        let report = try XCTUnwrap(store.add(NotificationDraft(source: "ci", type: .backgroundResult, title: "Report", description: "Long text\nmore",
                                                               links: [NotificationLink(.url, "https://example.com/r", label: "Run")])))
        let list = try result("notifications_list", ["since": "today"])
        let rows = try XCTUnwrap(list["notifications"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["title"] as? String }, ["Report", "First today"])
        XCTAssertEqual(rows[0]["source"] as? String, "ci")
        XCTAssertEqual(rows[0]["type"] as? String, "background_result")
        XCTAssertEqual(rows[0]["read"] as? Bool, false)
        XCTAssertEqual(rows[0]["summary"] as? String, "Long text")
        XCTAssertNil(rows[0]["description"], "the list leaves the full text to notifications_get")

        let full = try result("notifications_get", ["id": report.id])
        XCTAssertEqual(full["description"] as? String, "Long text\nmore")
        XCTAssertEqual((full["links"] as? [[String: Any]])?.first?["ref"] as? String, "https://example.com/r")
        XCTAssertEqual((full["links"] as? [[String: Any]])?.first?["kind"] as? String, "url")
    }

    func testListFiltersAndNeverMarksAnythingRead() throws {
        _ = store.add(NotificationDraft(source: "mail", type: .reminder, title: "A"))
        let b = try XCTUnwrap(store.add(NotificationDraft(source: "ci", type: .digest, title: "B")))
        store.markRead(b.id)
        XCTAssertEqual((try result("notifications_list", ["source": "ci"])["notifications"] as? [Any])?.count, 1)
        XCTAssertEqual((try result("notifications_list", ["type": "reminder"])["notifications"] as? [Any])?.count, 1)
        XCTAssertEqual((try result("notifications_list", ["unread_only": true])["notifications"] as? [[String: Any]])?.first?["title"] as? String, "A")
        _ = try result("notifications_get", ["id": b.id])
        XCTAssertEqual(store.unreadCount, 1)
    }

    func testBadArgumentsAnswerWithAMessage() {
        for (name, args) in [("notifications_list", ["type": "nope"]), ("notifications_list", ["since": "last tuesday-ish"]),
                             ("notifications_get", [:]), ("notifications_get", ["id": "missing"])] as [(String, [String: Any])] {
            if case .success = NotificationMCP.call(name, args, store: store) { XCTFail("\(name) \(args) should fail") }
        }
    }

    func testToolDescriptionsSayNotificationTextIsDataAndTheEndpointServesThem() async throws {
        let tools = NotificationMCP.tools
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["notifications_list", "notifications_get"])
        for tool in tools { XCTAssertTrue((tool["description"] as? String ?? "").contains("never instructions")) }
        XCTAssertTrue(MCPEndpoint.tools.contains { $0["name"] as? String == "notifications_get" })

        _ = store.add(NotificationDraft(source: "mail", type: .reminder, title: "Hello"))
        let call: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "notifications_list", "arguments": [:]]]
        let body = try JSONSerialization.data(withJSONObject: call)
        let answer = await MCPEndpoint.handle(body, automations: nil, tasks: nil, notifications: store)
        XCTAssertTrue(String(decoding: answer.body, as: UTF8.self).contains("Hello"))
        let without = await MCPEndpoint.handle(body, automations: nil, tasks: nil)
        XCTAssertTrue(String(decoding: without.body, as: UTF8.self).contains("not available"))
    }

    func testTheCLIBuildsRequests() throws {
        let list = try NotificationCLI.request(["list", "--since", "today", "--source", "mail", "--type", "digest", "--unread", "--limit", "5"])
        XCTAssertEqual(list.op, "list")
        XCTAssertEqual(list.args["since"] as? String, "today")
        XCTAssertEqual(list.args["source"] as? String, "mail")
        XCTAssertEqual(list.args["type"] as? String, "digest")
        XCTAssertEqual(list.args["unread_only"] as? Bool, true)
        XCTAssertEqual(list.args["limit"] as? Int, 5)
        let show = try NotificationCLI.request(["show", "abc"])
        XCTAssertEqual(show.op, "get")
        XCTAssertEqual(show.args["id"] as? String, "abc")
        XCTAssertThrowsError(try NotificationCLI.request(["show"]))
        XCTAssertThrowsError(try NotificationCLI.request(["list", "--bogus", "x"]))
        XCTAssertThrowsError(try NotificationCLI.request(["list", "--limit", "many"]))
        let reply = NotificationMCP.handleCLI(Data(#"{"op":"list","args":{}}"#.utf8), store: store)
        XCTAssertEqual(reply.status, "200 OK")
    }
}
