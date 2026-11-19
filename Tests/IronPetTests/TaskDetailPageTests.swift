import XCTest
@testable import IronPet

@MainActor
final class TaskDetailPageTests: XCTestCase {
    private var store: TaskStore!
    private var api: TasksAPI!

    override func setUp() async throws {
        store = TaskStore(database: Database.open(path: nil, migrations: AppMigrations.all).database)
        api = TasksAPI(store: store)
    }

    override func tearDown() async throws { store = nil }

    private func make(_ title: String = "Draft the report", labels: [String: String] = [:]) throws -> String {
        try store.create(title: title, source: .user, labels: labels, by: "user").id
    }

    // S1: navigation

    func testNavigationOpensAndCloses() {
        var nav = TaskNavigation()
        XCTAssertNil(nav.openTask)
        nav.open("a")
        XCTAssertEqual(nav.openTask, "a")
        nav.close()
        XCTAssertNil(nav.openTask)
    }

    // S2: markdown to attributed string

    func testNotesRenderFormattedWithThreeKindsOfLinks() throws {
        let notes = """
        # Plan

        - first **bold** item with `code`
        - see [the docs](https://docs.example.com/a) and https://example.com/b

        Write to team@example.com today.
        """
        let attributed = MarkdownText.attributed(Markdown.parse(notes), size: 14)
        var links: [String] = []
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let url = value as? URL { links.append(url.absoluteString) }
            else if let text = value as? String { links.append(text) }
        }
        XCTAssertTrue(links.contains("https://docs.example.com/a"))
        XCTAssertTrue(links.contains("https://example.com/b"))
        XCTAssertTrue(links.contains("mailto:team@example.com"))
        XCTAssertFalse(attributed.string.contains("**"))
        XCTAssertFalse(attributed.string.contains("# Plan"))
        let bold = (attributed.string as NSString).range(of: "bold")
        let font = attributed.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }


    // S3: editing notes keeps the raw markdown

    func testSavingNotesStoresRawMarkdown() throws {
        let id = try make()
        let raw = "## Steps\n\n- one **two**\n- [three](https://example.com)"
        try TaskEdits.setNotes(raw, of: id, in: api)
        XCTAssertEqual(store.task(id)?.notes, raw)
        XCTAssertEqual(TaskDetail(task: store.task(id)!, history: []).notes, raw)
    }

    // S4: label suggestions and validation

    func testKeySuggestionsComeFromOtherTasks() {
        let others = [["merge": "auto", "repo": "app"], ["merge": "manual"]]
        XCTAssertEqual(TaskLabelEditing.keySuggestions(for: "me", others: others), ["merge"])
        XCTAssertEqual(TaskLabelEditing.keySuggestions(for: "", others: others), ["merge", "repo"])
        XCTAssertEqual(TaskLabelEditing.keySuggestions(for: "me", others: others, own: ["merge": "auto"]), [])
        XCTAssertEqual(TaskLabelEditing.keySuggestions(for: "po", others: others), ["repo"])
    }

    func testValueSuggestionsAreTheValuesUsedForThatKey() {
        let others = [["merge": "auto", "repo": "app"], ["merge": "manual"]]
        XCTAssertEqual(TaskLabelEditing.valueSuggestions(for: "", key: "merge", others: others), ["auto", "manual"])
        XCTAssertEqual(TaskLabelEditing.valueSuggestions(for: "ma", key: "merge", others: others), ["manual"])
        XCTAssertEqual(TaskLabelEditing.valueSuggestions(for: "", key: "none", others: others), [])
    }

    func testAddingAndRemovingALabel() throws {
        _ = try make("Other", labels: ["merge": "auto"])
        let id = try make()
        XCTAssertNil(TaskLabelEditing.add(key: " merge ", value: "manual", to: id, in: api))
        XCTAssertEqual(store.task(id)?.labels, ["merge": "manual"])
        XCTAssertNil(TaskLabelEditing.add(key: "merge", value: "auto", to: id, in: api))
        XCTAssertEqual(store.task(id)?.labels, ["merge": "auto"])
        _ = try store.update(id, removeLabels: ["merge"], by: "user")
        XCTAssertEqual(store.task(id)?.labels, [:])
    }

    func testInvalidKeyShowsAMessageAndAddsNothing() throws {
        let id = try make()
        for key in ["two words", "a=b", "a,b", ""] {
            XCTAssertNotNil(TaskLabelEditing.add(key: key, value: "x", to: id, in: api), key)
        }
        XCTAssertNotNil(TaskLabelEditing.add(key: "ok", value: "", to: id, in: api))
        XCTAssertEqual(store.task(id)?.labels, [:])
    }

    // S5: link rows

    func testLinkRowsHaveSymbolTitleAndAction() {
        let url = TaskLinkRow(link: TaskLink(kind: .url, ref: "https://example.com/x", label: "Docs"))
        XCTAssertEqual(url.title, "Docs")
        XCTAssertEqual(url.symbol, "safari")
        XCTAssertEqual(url.action, .openURL(URL(string: "https://example.com/x")!))
        let bare = TaskLinkRow(link: TaskLink(kind: .url, ref: "https://example.com/x", label: nil))
        XCTAssertEqual(bare.title, "example.com")
        let file = TaskLinkRow(link: TaskLink(kind: .file, ref: "/tmp/report/summary.md", label: nil))
        XCTAssertEqual(file.title, "summary.md")
        XCTAssertEqual(file.action, .revealFile(URL(fileURLWithPath: "/tmp/report/summary.md")))
        XCTAssertEqual(TaskLinkRow(link: TaskLink(kind: .thread, ref: "thread-1", label: nil)).action, .openThread("thread-1"))
        XCTAssertEqual(TaskLinkRow(link: TaskLink(kind: .session, ref: "sess-1", label: nil)).action, .openSession("sess-1"))
        XCTAssertEqual(TaskLinkRow(link: TaskLink(kind: .thread, ref: "abcdefghijklmnop", label: nil)).title, "abcdefghijkl")
    }

    func testNonWebURLDoesNothing() {
        XCTAssertEqual(TaskLinkRow(link: TaskLink(kind: .url, ref: "file:///etc/passwd", label: nil)).action, .none)
    }

    // S6: status, due, waiting on

    func testStatusChangeRecordsANote() throws {
        let id = try make()
        try TaskEdits.setStatus(.inProgress, of: id, in: api)
        XCTAssertEqual(store.task(id)?.status, .inProgress)
        XCTAssertTrue(store.history(id).contains { $0.kind == .note && $0.detail == "Moved to In progress by the user." })
        try TaskEdits.setStatus(.done, of: id, in: api, note: "  Report sent  ")
        XCTAssertEqual(store.task(id)?.status, .done)
        XCTAssertNotNil(store.task(id)?.closed)
        XCTAssertTrue(store.history(id).contains { $0.kind == .note && $0.detail == "Report sent" })
    }

    func testDoneWithoutANoteUsesAFixedText() throws {
        let id = try make()
        try TaskEdits.setStatus(.done, of: id, in: api, note: "   ")
        XCTAssertTrue(store.history(id).contains { $0.kind == .note && $0.detail == TaskEdits.closedByUser })
    }

    func testDueAndWaitingOnPersist() throws {
        let id = try make()
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        try TaskEdits.setDue(due, of: id, in: api)
        XCTAssertEqual(store.task(id)?.due, due)
        try TaskEdits.setDue(nil, of: id, in: api)
        XCTAssertNil(store.task(id)?.due)
        try TaskEdits.setWaitingOn(" Ana ", of: id, in: api)
        XCTAssertEqual(store.task(id)?.waitingOn, "Ana")
        try TaskEdits.setWaitingOn("  ", of: id, in: api)
        XCTAssertNil(store.task(id)?.waitingOn)
        try TaskEdits.setTitle("New title", of: id, in: api)
        XCTAssertEqual(store.task(id)?.title, "New title")
    }
}
