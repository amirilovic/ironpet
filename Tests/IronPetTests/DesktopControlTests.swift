import XCTest
@testable import IronPet

/// A synthetic app: elements with settable fields and a log of what the service did to them.
final class FakeEl {
    var node: AXNode
    var children: [FakeEl]
    var actions: [String]
    var settable: Set<String>
    var gone = false
    /// Boolean attributes such as AXSelected and AXDisclosing.
    var bools: [String: Bool] = [:]
    /// Runs when an action succeeds, so a checkbox can flip its value.
    var onPerform: ((String) -> Void)?
    init(_ node: AXNode, actions: [String] = [], settable: Set<String> = [], _ children: [FakeEl] = []) {
        self.node = node
        self.actions = actions
        self.settable = settable
        self.children = children
    }

    func tree() -> AXNode {
        var out = node
        out.children = children.map { $0.tree() }
        return out
    }

    func preorder() -> [FakeEl] { [self] + children.flatMap { $0.preorder() } }
}

final class FakeAX: DesktopAX {
    var trusted = true
    var recording = true
    var app = CaptureApp(bundleId: "com.example.notes", name: "Notes", pid: 4242)
    var windowTitle = "Draft"
    var window: FakeEl
    var performed: [(String, String)] = []
    var sets: [(String, String)] = []
    var focused: [String] = []
    var picture: Data? = Data([0x89, 0x50, 0x4E, 0x47])
    var reads = 0

    init(window: FakeEl) { self.window = window }

    var isTrusted: Bool { trusted }
    var screenRecordingGranted: Bool { recording }
    func runningApp(matching query: String) -> CaptureApp? {
        [app.bundleId.lowercased(), app.name.lowercased()].contains(query.lowercased()) ? app : nil
    }

    /// When set, another window holds the keyboard focus and the one titled `windowTitle` does not.
    var keyWindowTitle: String?

    func windows(of app: CaptureApp) -> [DesktopWindowInfo] {
        var list = [DesktopWindowInfo(title: windowTitle, windowID: 77, focused: keyWindowTitle == nil, element: window)]
        if let keyWindowTitle { list.append(DesktopWindowInfo(title: keyWindowTitle, windowID: 78, focused: true, element: FakeEl(AXNode(role: "Window")))) }
        return list
    }

    func read(app: CaptureApp, window info: DesktopWindowInfo, budget: CaptureReadBudget) -> DesktopRead? {
        reads += 1
        return DesktopRead(app: app, window: info, root: window.tree(), elements: window.preorder())
    }

    private func el(_ element: DesktopElement) -> FakeEl? { (element as? FakeEl).flatMap { $0.gone ? nil : $0 } }
    func attributes(of element: DesktopElement) -> AXNode? {
        guard let e = el(element) else { return nil }
        var node = e.node
        node.children = []
        return node
    }

    func actions(of element: DesktopElement) -> [String] { el(element)?.actions ?? [] }
    func perform(_ action: String, on element: DesktopElement) -> Bool {
        guard let e = el(element), e.actions.contains(action) else { return false }
        performed.append((action, e.node.title ?? e.node.role))
        e.onPerform?(action)
        return true
    }

    func isSettable(_ attribute: String, on element: DesktopElement) -> Bool { el(element)?.settable.contains(attribute) ?? false }
    func set(_ attribute: String, to text: String, on element: DesktopElement) -> Bool {
        guard let e = el(element), e.settable.contains(attribute) else { return false }
        sets.append((attribute, text))
        if attribute == "AXValue" { e.node.value = text }
        return true
    }

    func focus(_ element: DesktopElement) -> Bool {
        guard let e = el(element) else { return false }
        focused.append(e.node.title ?? e.node.role)
        return true
    }

    func screenshot(of window: DesktopWindowInfo, app: CaptureApp) -> Data? { picture }

    var frontmost = true
    var activated: [String] = []
    var posted: [(DesktopKeyStroke, Int32)] = []
    var postWorks = true
    var focusedEl: FakeEl?
    /// Focus answers handed out one per call before `focusedEl` takes over, to move the focus between two reads.
    var focusQueue: [FakeEl] = []
    var boolSets: [(String, Bool)] = []

    func children(of element: DesktopElement) -> [DesktopElement] { el(element)?.children ?? [] }
    func boolean(_ attribute: String, of element: DesktopElement) -> Bool? { el(element)?.bools[attribute] }
    func setBoolean(_ attribute: String, to value: Bool, on element: DesktopElement) -> Bool {
        guard let e = el(element), e.settable.contains(attribute) else { return false }
        e.bools[attribute] = value
        boolSets.append((attribute, value))
        return true
    }

    func isFrontmost(_ app: CaptureApp) -> Bool { frontmost }
    func activate(_ app: CaptureApp) { activated.append(app.name); frontmost = true }
    func focusedElement(of app: CaptureApp) -> DesktopElement? { focusQueue.isEmpty ? focusedEl : focusQueue.removeFirst() }
    func post(_ stroke: DesktopKeyStroke, to app: CaptureApp) -> Bool {
        guard postWorks else { return false }
        posted.append((stroke, app.pid))
        return true
    }
}

final class FakeOpener: DesktopOpener {
    var front: String?
    var installed: [(bundleId: String, name: String)] = [("com.google.Chrome", "Google Chrome"), ("com.apple.Safari", "Safari")]
    var opened: [(URL, String?)] = []
    var works = true

    func frontmostBrowser() -> String? { front }
    func browser(matching query: String) -> (bundleId: String, name: String)? {
        installed.first { $0.bundleId.lowercased() == query.lowercased() || $0.name.lowercased() == query.lowercased() }
    }

    func open(_ url: URL, inBrowser bundleId: String?) -> Bool {
        guard works else { return false }
        opened.append((url, bundleId))
        return true
    }
}

final class DesktopControlTests: XCTestCase {
    var ax: FakeAX!
    var privacy: CapturePrivacy!
    var service: DesktopService!
    var enabled = true
    var approvals: [DesktopApproval] = []
    var answer = true
    var records: [DesktopActionRecord] = []

    let save = FakeEl(AXNode(role: "Button", title: "Save"), actions: ["AXPress"])
    let send = FakeEl(AXNode(role: "Button", title: "Send"), actions: ["AXPress"])
    let field = FakeEl(AXNode(role: "TextField", title: "Subject", value: "hi"), settable: ["AXValue", "AXSelectedText"])
    let area = FakeEl(AXNode(role: "TextArea", value: "line", description: "Body"), settable: ["AXValue"])
    let secret = FakeEl(AXNode(role: "TextField", subrole: "SecureTextField", value: "hunter2"), settable: ["AXValue"])
    let label = FakeEl(AXNode(role: "StaticText", value: "Welcome back"))

    override func setUp() {
        super.setUp()
        let group = FakeEl(AXNode(role: "Group", description: "Form"), [save, send, field, area, secret])
        ax = FakeAX(window: FakeEl(AXNode(role: "Window", title: "Draft"), [group, label]))
        privacy = CapturePrivacy()
        enabled = true
        answer = true
        approvals = []
        records = []
        service = makeService()
    }

    func makeService() -> DesktopService {
        var deps = DesktopService.Dependencies(privacy: privacy)
        deps.ax = ax
        deps.enabled = { [unowned self] in enabled }
        deps.approve = { [unowned self] request in approvals.append(request); return answer }
        deps.record = { [unowned self] record in records.append(record) }
        return DesktopService(deps)
    }

    private func call(_ name: String, _ args: [String: Any]) async -> Result<DesktopOutput, ScreenMCP.Failure> { await service.call(name, args) }

    private func value(_ name: String, _ args: [String: Any], file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        switch await call(name, args) {
        case .success(.value(let value)): return try XCTUnwrap(value as? [String: Any], file: file, line: line)
        case .success: XCTFail("expected a value", file: file, line: line); return [:]
        case .failure(let failure): XCTFail(failure.message, file: file, line: line); return [:]
        }
    }

    private func failure(_ name: String, _ args: [String: Any]) async -> String {
        switch await call(name, args) {
        case .failure(let failure): return failure.message
        case .success: XCTFail("expected a failure"); return ""
        }
    }

    /// The ref of the line that starts with `prefix` in a snapshot outline.
    private func refFor(_ prefix: String, in out: [String: Any]) throws -> String {
        let outline = try XCTUnwrap(out["outline"] as? String ?? out["elements"] as? String ?? out["elements_found"] as? String)
        let line = try XCTUnwrap(outline.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }, outline)
        return String(try XCTUnwrap(line.split(separator: " ").last))
    }

    // MARK: S1

    func testSnapshotListsElementsWithRefsAndTheirWindows() async throws {
        let out = try await value("desktop_snapshot", ["app": "com.example.notes"])
        let outline = try XCTUnwrap(out["outline"] as? String)
        XCTAssertTrue(outline.contains("button \"Save\" #"), outline)
        XCTAssertTrue(outline.contains("statictext \"Welcome back\" #"), outline)
        XCTAssertEqual(out["app"] as? String, "Notes")
        XCTAssertEqual((out["windows"] as? [[String: Any]])?.first?["title"] as? String, "Draft")
    }

    func testSecureFieldReturnsRoleOnly() async throws {
        let out = try await value("desktop_snapshot", ["app": "Notes"])
        let outline = try XCTUnwrap(out["outline"] as? String)
        XCTAssertTrue(outline.contains("textfield.securetextfield #"), outline)
        XCTAssertFalse(outline.contains("hunter2"))
        let found = try await value("desktop_find", ["app": "Notes", "role": "textfield"])
        XCTAssertFalse((found["elements"] as? String ?? "").contains("hunter2"))
    }

    func testRootReturnsASubtreeAndRoleFiltersByRole() async throws {
        let first = try await value("desktop_snapshot", ["app": "Notes", "depth": 2])
        let group = try refFor("group", in: first)
        let sub = try await value("desktop_snapshot", ["root": group])
        let outline = try XCTUnwrap(sub["outline"] as? String)
        XCTAssertTrue(outline.hasPrefix("group"), outline)
        XCTAssertTrue(outline.contains("button \"Send\""))
        XCTAssertFalse(outline.contains("Welcome back"))
        let buttons = try await value("desktop_snapshot", ["app": "Notes", "role": "button"])
        let lines = try XCTUnwrap(buttons["elements_found"] as? String).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let filtered = try await value("desktop_snapshot", ["app": "Notes", "role": "button", "text": "sav"])
        XCTAssertEqual((filtered["elements_found"] as? String)?.split(separator: "\n").count, 1)
    }

    func testIdenticalElementsGetDistinctRefs() async throws {
        ax.window.children.append(FakeEl(AXNode(role: "Button", title: "Save"), actions: ["AXPress"]))
        let out = try await value("desktop_find", ["app": "Notes", "name": "save"])
        let found = (out["elements"] as? String ?? "").split(separator: "\n").map { String($0.split(separator: " ").last ?? "") }
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found).count, 2)
        XCTAssertTrue(found[1].contains("~2"), "\(found)")
        let second = found[1]
        _ = try await value("desktop_press", ["ref": second])
        XCTAssertEqual(ax.performed.count, 1)
    }

    // MARK: S2

    func testFindMatchesRoleNameAndValue() async throws {
        let byName = try await value("desktop_find", ["app": "Notes", "name": "subj"])
        XCTAssertEqual(byName["count"] as? Int, 1)
        XCTAssertTrue((byName["elements"] as? String ?? "").contains("textfield \"Subject\" value=\"hi\""))
        let byValue = try await value("desktop_find", ["app": "Notes", "value": "line"])
        XCTAssertTrue((byValue["elements"] as? String ?? "").hasPrefix("textarea"))
        let byRole = try await value("desktop_find", ["app": "Notes", "role": "AXButton"])
        XCTAssertEqual(byRole["count"] as? Int, 2)
        let none = try await value("desktop_find", ["app": "Notes", "role": "button", "name": "nothing"])
        XCTAssertEqual(none["count"] as? Int, 0)
        let message = await failure("desktop_find", ["app": "Notes"])
        XCTAssertTrue(message.contains("at least one"))
    }

    // MARK: S3

    func testPressPerformsAXPress() async throws {
        let out = try await value("desktop_find", ["app": "Notes", "name": "Save"])
        let ref = try refFor("button", in: out)
        let done = try await value("desktop_press", ["ref": ref])
        XCTAssertEqual(done["action"] as? String, "AXPress")
        XCTAssertEqual(ax.performed.map(\.0), ["AXPress"])
        XCTAssertTrue(approvals.isEmpty)
        XCTAssertEqual(records.map(\.outcome), [.done])
        XCTAssertEqual(records.first?.app, "Notes")
        XCTAssertEqual(records.first?.window, "Draft")
        XCTAssertEqual(records.first?.role, "Button")
        XCTAssertEqual(records.first?.name, "Save")
        XCTAssertEqual(records.first?.action, "press")
    }

    func testPressFallsBackToTheDefaultAction() async throws {
        let row = FakeEl(AXNode(role: "Row", title: "Inbox"), actions: ["AXOpen"])
        ax.window.children.append(row)
        let out = try await value("desktop_find", ["app": "Notes", "role": "row"])
        _ = try await value("desktop_press", ["ref": try refFor("row", in: out)])
        XCTAssertEqual(ax.performed.map(\.0), ["AXOpen"])
        let bare = FakeEl(AXNode(role: "Image", description: "Logo"))
        ax.window.children.append(bare)
        let image = try await value("desktop_find", ["app": "Notes", "role": "image"])
        let message = await failure("desktop_press", ["ref": try refFor("image", in: image)])
        XCTAssertTrue(message.contains("no press action"), message)
    }

    func testSetValueSetsAXValueAndRefusesWhatIsNotSettable() async throws {
        let out = try await value("desktop_find", ["app": "Notes", "name": "Subject"])
        let ref = try refFor("textfield", in: out)
        _ = try await value("desktop_set_value", ["ref": ref, "text": "Hello"])
        XCTAssertEqual(ax.sets.map(\.1), ["Hello"])
        XCTAssertEqual(field.node.value, "Hello")
        // Typing into an input does not stale its ref.
        _ = try await value("desktop_set_value", ["ref": ref, "text": "Hello again"])
        let labelOut = try await value("desktop_find", ["app": "Notes", "role": "statictext"])
        let message = await failure("desktop_set_value", ["ref": try refFor("statictext", in: labelOut), "text": "x"])
        XCTAssertTrue(message.contains("cannot be set"), message)
    }

    func testTypeInsertsAtTheCaretAndFallsBackToAppending() async throws {
        let subject = try await value("desktop_find", ["app": "Notes", "name": "Subject"])
        _ = try await value("desktop_type", ["ref": try refFor("textfield", in: subject), "text": "abc"])
        XCTAssertEqual(ax.sets.last?.0, "AXSelectedText")
        XCTAssertEqual(ax.focused, ["Subject"])
        let body = try await value("desktop_find", ["app": "Notes", "role": "textarea"])
        let done = try await value("desktop_type", ["ref": try refFor("textarea", in: body), "text": " more"])
        XCTAssertEqual(done["action"] as? String, "append AXValue")
        XCTAssertEqual(area.node.value, "line more")
    }

    func testFocusFocuses() async throws {
        let out = try await value("desktop_find", ["app": "Notes", "name": "Save"])
        _ = try await value("desktop_focus", ["ref": try refFor("button", in: out)])
        XCTAssertEqual(ax.focused, ["Save"])
    }

    func testAStaleRefAsksForANewSnapshot() async throws {
        let out = try await value("desktop_find", ["app": "Notes", "name": "Save"])
        let ref = try refFor("button", in: out)
        save.node.title = "Saved"
        let changed = await failure("desktop_press", ["ref": ref])
        XCTAssertTrue(changed.contains("new desktop_snapshot"), changed)
        let unknown = await failure("desktop_press", ["ref": "#doesnotexist"])
        XCTAssertTrue(unknown.contains("new desktop_snapshot"), unknown)
        save.node.title = "Save"
        save.gone = true
        let gone = await failure("desktop_press", ["ref": ref])
        XCTAssertTrue(gone.contains("new desktop_snapshot"), gone)
        XCTAssertTrue(ax.performed.isEmpty)
    }

    // MARK: S4

    func testScreenshotNeedsScreenRecording() async throws {
        ax.recording = false
        let message = await failure("desktop_screenshot", ["app": "Notes"])
        XCTAssertTrue(message.contains("Screen Recording"), message)
        ax.recording = true
        guard case .success(.image(let data, let caption)) = await call("desktop_screenshot", ["app": "Notes"]) else { return XCTFail("expected an image") }
        XCTAssertEqual(data, ax.picture)
        XCTAssertEqual(caption, "Notes: Draft")
    }

    func testScreenshotFollowsThePrivacyRules() async throws {
        privacy.setExcluded(["com.example.notes"])
        let message = await failure("desktop_screenshot", ["app": "Notes"])
        XCTAssertTrue(message.contains("does not read"), message)
    }

    // MARK: S5

    func testRiskyVerbsAreGenericWords() {
        for text in ["Send", "Send message", "Pay now", "Delete account", "Submit", "Buy", "Checkout", "Check out", "Transfer funds", "sending…"] {
            XCTAssertNotNil(DesktopSafety.riskyVerb(in: text), text)
        }
        for text in ["Save", "Payload", "Sender", "Suspend", "Subject", "Buyer notes", "Open"] {
            XCTAssertNil(DesktopSafety.riskyVerb(in: text), text)
        }
        XCTAssertNotNil(DesktopSafety.approvalReason(element: ["Cancel"], window: "Delete account"))
        XCTAssertNil(DesktopSafety.approvalReason(element: ["Cancel"], window: "Notes"))
    }

    func testARiskyElementWaitsForApprovalAndRunsOnlyWhenApproved() async throws {
        let out = try await value("desktop_find", ["app": "Notes", "name": "Send"])
        let ref = try refFor("button", in: out)
        answer = false
        let declined = await failure("desktop_press", ["ref": ref])
        XCTAssertTrue(declined.contains("declined"), declined)
        XCTAssertEqual(approvals.count, 1)
        XCTAssertTrue(approvals[0].title.contains("Send"))
        XCTAssertTrue(ax.performed.isEmpty)
        XCTAssertEqual(records.map(\.outcome), [.declined])
        answer = true
        _ = try await value("desktop_press", ["ref": ref])
        XCTAssertEqual(approvals.count, 2)
        XCTAssertEqual(ax.performed.map(\.1), ["Send"])
        XCTAssertEqual(records.map(\.outcome), [.declined, .done])
    }

    func testARiskyWindowTitleAlsoAsks() async throws {
        ax.windowTitle = "Delete account"
        let out = try await value("desktop_find", ["app": "Notes", "name": "Save"])
        _ = try await value("desktop_press", ["ref": try refFor("button", in: out)])
        XCTAssertEqual(approvals.count, 1)
        XCTAssertTrue(approvals[0].detail.contains("window title"), approvals[0].detail)
    }

    func testAnElementThatChangesWhileTheUserDecidesDoesNotRun() async throws {
        let out = try await value("desktop_find", ["app": "Notes", "name": "Send"])
        let ref = try refFor("button", in: out)
        service = {
            var deps = DesktopService.Dependencies(privacy: privacy)
            deps.ax = ax
            deps.enabled = { true }
            deps.approve = { [unowned self] _ in send.node.title = "Send all"; return true }
            deps.record = { [unowned self] in records.append($0) }
            return DesktopService(deps)
        }()
        let out2 = try await value("desktop_find", ["app": "Notes", "name": "Send"])
        let ref2 = try refFor("button", in: out2)
        _ = ref
        let message = await failure("desktop_press", ["ref": ref2])
        XCTAssertTrue(message.contains("new desktop_snapshot"), message)
        XCTAssertTrue(ax.performed.isEmpty)
        XCTAssertEqual(records.map(\.outcome), [.refused])
    }

    func testNeverActsOnASecureField() async throws {
        let out = try await value("desktop_find", ["app": "Notes", "role": "securetextfield"])
        let ref = try refFor("textfield", in: out)
        for (tool, extra) in [("desktop_press", [:]), ("desktop_set_value", ["text": "x"]), ("desktop_type", ["text": "x"]), ("desktop_focus", [:])] as [(String, [String: Any])] {
            let message = await failure(tool, ["ref": ref].merging(extra) { a, _ in a })
            XCTAssertTrue(message.contains("password"), "\(tool): \(message)")
        }
        XCTAssertTrue(ax.sets.isEmpty && ax.performed.isEmpty && ax.focused.isEmpty)
    }

    func testNeverReadsOrActsInAppsOnTheDenyList() async throws {
        let out = try await value("desktop_find", ["app": "Notes", "name": "Save"])
        let ref = try refFor("button", in: out)
        privacy.setExcluded(["Notes"])
        var message = await failure("desktop_press", ["ref": ref])
        XCTAssertTrue(message.contains("does not read or act on Notes"), message)
        message = await failure("desktop_snapshot", ["app": "Notes"])
        XCTAssertTrue(message.contains("does not read or act on Notes"), message)
        privacy.setExcluded([])
        ax.app = CaptureApp(bundleId: "com.example.1password", name: "Vault", pid: 9)
        message = await failure("desktop_snapshot", ["app": "Vault"])
        XCTAssertTrue(message.contains("deny list"), message)
        ax.app = CaptureApp(bundleId: "com.example.notes", name: "Notes", pid: 4242)
        privacy.pause(for: 60)
        message = await failure("desktop_snapshot", ["app": "Notes"])
        XCTAssertTrue(message.contains("paused"), message)
        XCTAssertTrue(ax.performed.isEmpty)
    }

    func testNeverReadsAPrivateBrowserWindow() async throws {
        ax.app = CaptureApp(bundleId: "com.apple.Safari", name: "Browser", pid: 5)
        ax.windowTitle = "Reading — Private Browsing"
        let message = await failure("desktop_snapshot", ["app": "Browser"])
        XCTAssertTrue(message.contains("private browser window"), message)
    }

    func testOffByDefaultAndWithoutAccessibility() async throws {
        enabled = false
        let off = await failure("desktop_snapshot", ["app": "Notes"])
        XCTAssertTrue(off.contains("off"), off)
        enabled = true
        ax.trusted = false
        let untrusted = await failure("desktop_snapshot", ["app": "Notes"])
        XCTAssertTrue(untrusted.contains("Accessibility"), untrusted)
    }

    func testActionRecordBecomesAnActivityEvent() {
        let record = DesktopActionRecord(at: Date(timeIntervalSince1970: 100), app: "Notes", window: "Draft", role: "Button", name: "Save",
                                         action: "press", outcome: .done, note: "AXPress")
        let event = ActivityEvent.desktopAction(record)
        XCTAssertEqual(event.kind, .desktopAction)
        XCTAssertEqual(event.title, "press Button \"Save\" in Notes")
        XCTAssertEqual(event.extra[ActivityEvent.DesktopKey.window], "Draft")
        XCTAssertEqual(event.extra[ActivityEvent.DesktopKey.outcome], "done")
        XCTAssertEqual(DesktopLogText.line(event), "done, window: Draft, AXPress")
    }

    func testTheLogGoesToTheActivityLog() throws {
        let log = ActivityLog(database: Database.open(path: nil, migrations: AppMigrations.all).database)
        let record = DesktopActionRecord(at: Date(), app: "Notes", window: "Draft", role: "Button", name: "Send", action: "press", outcome: .declined, note: "the element says \"send\"")
        log.record(.desktopAction(record))
        let events = log.events(in: DateInterval(start: Date().addingTimeInterval(-60), end: Date().addingTimeInterval(60)), kinds: [.desktopAction])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.extra[ActivityEvent.DesktopKey.name], "Send")
        XCTAssertEqual(events.first?.extra[ActivityEvent.DesktopKey.app], "Notes")
        XCTAssertEqual(events.first?.extra[ActivityEvent.DesktopKey.action], "press")
    }

    @MainActor
    func testApprovalBubbleAnswersAndTimesOut() async {
        var shown: [DesktopApproval] = [], dismissed: [DesktopApproval] = []
        var decide: ((Bool) -> Void)?
        let approvals = DesktopApprovals(timeout: 0.05, present: { request, answer in shown.append(request); decide = answer }, dismiss: { dismissed.append($0) })
        let request = DesktopApproval(title: "press button \"Send\"", detail: "x")
        async let yes = approvals.ask(request)
        try? await Task.sleep(nanoseconds: 10_000_000)
        decide?(true)
        let approved = await yes
        XCTAssertTrue(approved)
        XCTAssertTrue(dismissed.isEmpty)
        let timedOut = await approvals.ask(request)
        XCTAssertFalse(timedOut)
        XCTAssertEqual(dismissed, [request], "a timed out question leaves no bubble behind")
    }

    // MARK: Tools

    func testToolsAreListedAndDescribed() async throws {
        XCTAssertEqual(DesktopMCP.names, ["desktop_snapshot", "desktop_find", "desktop_press", "desktop_set_value", "desktop_type", "desktop_focus", "desktop_screenshot",
                                          "desktop_key", "desktop_open_url", "desktop_select", "desktop_check", "desktop_expand"])
        for tool in DesktopMCP.tools {
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
        }
    }

    @MainActor
    func testTheEndpointListsTheDesktopTools() {
        XCTAssertTrue(DesktopMCP.names.isSubset(of: Set(MCPEndpoint.tools.compactMap { $0["name"] as? String })))
    }

    @MainActor
    func testTheEndpointReturnsAnImageAndErrors() async throws {
        func rpc(_ name: String, _ args: [String: Any], desktop: DesktopService?) async throws -> [String: Any] {
            let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]])
            let (_, data) = await MCPEndpoint.handle(body, automations: nil, tasks: nil, desktop: desktop.map { DesktopAPI(service: $0, settings: .live) })
            return try XCTUnwrap(try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])["result"] as? [String: Any])
        }
        let picture = try await rpc("desktop_screenshot", ["app": "Notes"], desktop: service)
        let content = try XCTUnwrap(picture["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "image")
        XCTAssertEqual(content.first?["mimeType"] as? String, "image/png")
        XCTAssertEqual(content.first?["data"] as? String, ax.picture?.base64EncodedString())
        let missing = try await rpc("desktop_press", ["ref": "#x"], desktop: nil)
        XCTAssertEqual(missing["isError"] as? Bool, true)
    }

    func testDesktopToolsAskInTheChatUnlessAutoIsOn() {
        let call = ACPToolCall(id: "1", title: "mcp__ironpet__desktop_press", kind: "other", rawInput: ["ref": "#abc"])
        if case .allow = ApprovalRules.policy(for: call, auto: false) { XCTFail("a desktop action must ask in the chat") }
        let find = ACPToolCall(id: "1", title: "mcp__ironpet__desktop_find", kind: "other", rawInput: ["app": "Notes"])
        if case .allow = ApprovalRules.policy(for: find, auto: false) { XCTFail("reading another app must ask in the chat") }
    }

    // MARK: S6

    func testDesktopCodeNamesNoApp() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/IronPet/Desktop")
        let names = try NSRegularExpression(pattern: #"\b(slack|discord|gmail|whatsapp|telegram|safari|chrome|firefox|zoom|outlook|notion|github|cursor|xcode|iterm|vscode|mail\.app)\b"#, options: .caseInsensitive)
        let bundle = try NSRegularExpression(pattern: #"\b(com|org|net|io)\.[a-z0-9_-]+\.[a-z0-9_.-]+"#)
        var found: [String] = []
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThanOrEqual(files.count, 4)
        for file in files {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if names.firstMatch(in: String(line), range: range) != nil
                    || (bundle.firstMatch(in: String(line), range: range) != nil && !line.contains("com.ironpet")) {
                    found.append("\(file):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(found, [], "desktop code must not name an app; the deny lists live in CapturePrivacy")
    }
}
