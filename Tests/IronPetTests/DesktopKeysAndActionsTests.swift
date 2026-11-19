import ApplicationServices
import XCTest
@testable import IronPet

/// desktop_key, desktop_open_url, desktop_select, desktop_check and desktop_expand, driven with the synthetic app from
/// `DesktopControlTests`.
final class DesktopKeysAndActionsTests: XCTestCase {
    var ax: FakeAX!
    var opener: FakeOpener!
    var privacy: CapturePrivacy!
    var service: DesktopService!
    var approvals: [DesktopApproval] = []
    var answer = true
    var records: [DesktopActionRecord] = []

    let subject = FakeEl(AXNode(role: "TextField", title: "Subject", value: "hi"), settable: ["AXValue"])
    let sendButton = FakeEl(AXNode(role: "Button", title: "Send"), actions: ["AXPress"])
    let password = FakeEl(AXNode(role: "TextField", subrole: "SecureTextField", value: "hunter2"), settable: ["AXValue"])
    let remember = FakeEl(AXNode(role: "CheckBox", title: "Remember me", value: "0"), actions: ["AXPress"])
    let radio = FakeEl(AXNode(role: "RadioButton", title: "Small", value: "1"), actions: ["AXPress"])
    let triangle = FakeEl(AXNode(role: "DisclosureTriangle", title: "Details", value: "0"), actions: ["AXPress"])
    let folder = FakeEl(AXNode(role: "Row", title: "Folder"), settable: ["AXDisclosing"])
    let helvetica = FakeEl(AXNode(role: "MenuItem", title: "Helvetica"), actions: ["AXPress"])
    let times = FakeEl(AXNode(role: "MenuItem", title: "Times"), actions: ["AXPress"])
    let timesNew = FakeEl(AXNode(role: "MenuItem", title: "Times New Roman"), actions: ["AXPress"])
    let deleteAll = FakeEl(AXNode(role: "MenuItem", title: "Delete all fonts"), actions: ["AXPress"])
    let font = FakeEl(AXNode(role: "PopUpButton", title: "Font"), actions: ["AXPress", "AXCancel"])
    let inbox = FakeEl(AXNode(role: "Row"), settable: ["AXSelected"])
    let sent = FakeEl(AXNode(role: "Row"), settable: ["AXSelected"])
    let mailboxes = FakeEl(AXNode(role: "List", title: "Mailboxes"))

    override func setUp() {
        super.setUp()
        remember.onPerform = { [unowned self] _ in remember.node.value = remember.node.value == "1" ? "0" : "1" }
        triangle.onPerform = { [unowned self] _ in triangle.node.value = triangle.node.value == "1" ? "0" : "1" }
        font.children = [FakeEl(AXNode(role: "Menu"), [helvetica, times, timesNew, deleteAll])]
        inbox.children = [FakeEl(AXNode(role: "StaticText", value: "Inbox"))]
        sent.children = [FakeEl(AXNode(role: "StaticText", value: "Sent items"))]
        mailboxes.children = [inbox, sent]
        let form = FakeEl(AXNode(role: "Group", description: "Form"),
                          [subject, sendButton, password, remember, radio, triangle, folder, font, mailboxes])
        ax = FakeAX(window: FakeEl(AXNode(role: "Window", title: "Draft"), [form]))
        ax.focusedEl = subject
        folder.bools["AXDisclosing"] = false
        inbox.bools["AXSelected"] = false
        sent.bools["AXSelected"] = false
        opener = FakeOpener()
        privacy = CapturePrivacy()
        answer = true
        approvals = []
        records = []
        var deps = DesktopService.Dependencies(privacy: privacy)
        deps.ax = ax
        deps.opener = opener
        deps.enabled = { true }
        deps.approve = { [unowned self] request in approvals.append(request); return answer }
        deps.record = { [unowned self] record in records.append(record) }
        service = DesktopService(deps)
    }

    private func call(_ name: String, _ args: [String: Any]) async -> Result<DesktopOutput, ScreenMCP.Failure> { await service.call(name, args) }

    @discardableResult
    private func value(_ name: String, _ args: [String: Any], file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        switch await call(name, args) {
        case .success(.value(let value)): return try XCTUnwrap(value as? [String: Any], file: file, line: line)
        case .success: XCTFail("expected a value", file: file, line: line); return [:]
        case .failure(let failure): XCTFail(failure.message, file: file, line: line); return [:]
        }
    }

    private func failure(_ name: String, _ args: [String: Any], file: StaticString = #filePath, line: UInt = #line) async -> String {
        switch await call(name, args) {
        case .failure(let failure): return failure.message
        case .success: XCTFail("expected a failure", file: file, line: line); return ""
        }
    }

    private func ref(_ role: String, _ name: String? = nil, file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        var args: [String: Any] = ["app": "Notes", "role": role]
        if let name { args["name"] = name }
        let out = try await value("desktop_find", args, file: file, line: line)
        let text = try XCTUnwrap(out["elements"] as? String, file: file, line: line)
        let first = try XCTUnwrap(text.split(separator: "\n").first, text, file: file, line: line)
        return String(try XCTUnwrap(first.split(separator: " ").last, file: file, line: line))
    }

    // MARK: Key names

    func testKeyNamesMapToKeyCodesAndFlags() throws {
        let cases: [(String, CGKeyCode, CGEventFlags, String)] = [
            ("return", 36, [], "return"), ("Enter", 36, [], "return"), ("tab", 48, [], "tab"), ("escape", 53, [], "escape"), ("esc", 53, [], "escape"),
            ("space", 49, [], "space"), ("delete", 51, [], "delete"), ("backspace", 51, [], "delete"), ("forwarddelete", 117, [], "forwarddelete"),
            ("left", 123, [], "left"), ("right", 124, [], "right"), ("down", 125, [], "down"), ("up", 126, [], "up"),
            ("home", 115, [], "home"), ("end", 119, [], "end"), ("pageup", 116, [], "pageup"), ("pagedown", 121, [], "pagedown"),
            ("f1", 122, [], "f1"), ("f5", 96, [], "f5"), ("f12", 111, [], "f12"),
            ("a", 0, [], "a"), ("t", 17, [], "t"), ("l", 37, [], "l"), ("1", 18, [], "1"), ("0", 29, [], "0"), ("/", 44, [], "/"), (",", 43, [], ","),
            ("cmd+l", 37, .maskCommand, "cmd+l"), ("Command+L", 37, .maskCommand, "cmd+l"),
            ("shift+tab", 48, .maskShift, "shift+tab"), ("cmd+shift+t", 17, [.maskCommand, .maskShift], "cmd+shift+t"),
            ("shift+cmd+t", 17, [.maskCommand, .maskShift], "cmd+shift+t"),
            ("ctrl+opt+left", 123, [.maskControl, .maskAlternate], "opt+ctrl+left"), ("alt+f4", 118, .maskAlternate, "opt+f4"),
            ("cmd+return", 36, .maskCommand, "cmd+return"), ("cmd+,", 43, .maskCommand, "cmd+,"),
        ]
        for (input, code, flags, label) in cases {
            let stroke = try XCTUnwrap(try? DesktopKeys.parse(input).get(), input)
            XCTAssertEqual(stroke.keyCode, code, input)
            XCTAssertEqual(stroke.flags, flags, input)
            XCTAssertEqual(stroke.label, label, input)
        }
    }

    func testUnknownKeysAreRejectedWithAnExplanation() {
        for input in ["", "  ", "hyper+a", "cmd+", "+a", "cmd+cmd+a", "cmd+launch", "ab", "cmd+shift", "capslock"] {
            guard case .failure(let error) = DesktopKeys.parse(input) else { XCTFail("\(input) should not parse"); continue }
            XCTAssertFalse(error.message.isEmpty, input)
        }
        guard case .failure(let error) = DesktopKeys.parse("launch") else { return XCTFail() }
        XCTAssertTrue(error.message.contains("Known keys"), error.message)
    }

    // MARK: S1 posting

    func testAKeyIsPostedToTheAppsProcessAndLogged() async throws {
        let out = try await value("desktop_key", ["app": "Notes", "key": "cmd+l"])
        XCTAssertEqual(out["action"] as? String, "key cmd+l")
        XCTAssertEqual(ax.posted.count, 1)
        XCTAssertEqual(ax.posted[0].0.keyCode, 37)
        XCTAssertEqual(ax.posted[0].0.flags, .maskCommand)
        XCTAssertEqual(ax.posted[0].1, 4242)
        XCTAssertTrue(ax.activated.isEmpty)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].action, "key cmd+l")
        XCTAssertEqual(records[0].outcome, .done)
        XCTAssertEqual(records[0].app, "Notes")
        XCTAssertEqual(records[0].window, "Draft")
        XCTAssertEqual(records[0].name, "Subject")
        XCTAssertTrue(approvals.isEmpty)
    }

    func testEachNamedKeyReachesTheEventPoster() async throws {
        for key in ["return", "tab", "escape", "up", "down", "left", "right", "shift+tab"] {
            try await value("desktop_key", ["app": "Notes", "key": key])
        }
        XCTAssertEqual(ax.posted.map(\.0.keyCode), [36, 48, 53, 126, 125, 123, 124, 48])
        XCTAssertEqual(ax.posted.last?.0.flags, .maskShift)
        XCTAssertEqual(records.map(\.outcome), Array(repeating: .done, count: 8))
    }

    func testAWindowThatIsNotInFrontIsRaisedFirst() async throws {
        ax.frontmost = false
        try await value("desktop_key", ["app": "Notes", "key": "tab"])
        XCTAssertEqual(ax.activated, ["Notes"])
        XCTAssertEqual(ax.focused, ["Draft"])
        XCTAssertEqual(ax.posted.count, 1)
    }

    func testAKeyNeedsAnAppAndAKey() async {
        let noKey = await failure("desktop_key", ["app": "Notes"])
        XCTAssertTrue(noKey.contains("key is required"), noKey)
        let noApp = await failure("desktop_key", ["key": "tab"])
        XCTAssertTrue(noApp.contains("app is required"), noApp)
        let missing = await failure("desktop_key", ["app": "Nonexistent", "key": "tab"])
        XCTAssertTrue(missing.contains("no running app"), missing)
        XCTAssertTrue(ax.posted.isEmpty)
    }

    func testAFailedPostIsLoggedAsFailed() async {
        ax.postWorks = false
        let message = await failure("desktop_key", ["app": "Notes", "key": "tab"])
        XCTAssertTrue(message.contains("could not be posted"), message)
        XCTAssertEqual(records.map(\.outcome), [.failed])
    }

    // MARK: S2 approval by context

    func testReturnAsksWhenTheFocusedElementOrWindowSaysSend() async throws {
        ax.focusedEl = sendButton
        answer = false
        let declined = await failure("desktop_key", ["app": "Notes", "key": "return"])
        XCTAssertTrue(declined.contains("declined"), declined)
        XCTAssertEqual(approvals.count, 1)
        XCTAssertTrue(approvals[0].title.contains("return"), approvals[0].title)
        XCTAssertTrue(ax.posted.isEmpty)
        XCTAssertEqual(records.map(\.outcome), [.declined])
        XCTAssertEqual(records[0].action, "key return")
        answer = true
        try await value("desktop_key", ["app": "Notes", "key": "return"])
        XCTAssertEqual(approvals.count, 2)
        XCTAssertEqual(ax.posted.count, 1)
        XCTAssertEqual(records.map(\.outcome), [.declined, .done])
    }

    func testARiskyWindowTitleMakesReturnAndCommandCombosAsk() async throws {
        ax.windowTitle = "Delete account"
        for key in ["return", "cmd+l", "shift+return"] {
            try await value("desktop_key", ["app": "Notes", "key": key])
        }
        XCTAssertEqual(approvals.count, 3)
        XCTAssertTrue(approvals[0].detail.contains("window title"), approvals[0].detail)
        XCTAssertEqual(ax.posted.count, 3)
        answer = false
        let declined = await failure("desktop_key", ["app": "Notes", "key": "cmd+k"])
        XCTAssertTrue(declined.contains("declined"), declined)
        XCTAssertEqual(ax.posted.count, 3)
    }

    func testPlainKeysNeverAskEvenInARiskyContext() async throws {
        ax.windowTitle = "Delete account"
        ax.focusedEl = sendButton
        for key in ["a", "tab", "shift+tab", "escape", "down", "space", "shift+a"] {
            try await value("desktop_key", ["app": "Notes", "key": key])
        }
        XCTAssertTrue(approvals.isEmpty)
        XCTAssertEqual(ax.posted.count, 7)
    }

    func testReturnInASafeContextDoesNotAsk() async throws {
        try await value("desktop_key", ["app": "Notes", "key": "return"])
        try await value("desktop_key", ["app": "Notes", "key": "cmd+shift+t"])
        XCTAssertTrue(approvals.isEmpty)
    }

    func testNoAnswerToTheApprovalPostsNothing() async throws {
        let approvals = await MainActor.run { DesktopApprovals(timeout: 0.05, present: { _, _ in }, dismiss: { _ in }) }
        var deps = DesktopService.Dependencies(privacy: privacy)
        deps.ax = ax
        deps.opener = opener
        deps.enabled = { true }
        deps.approve = { await approvals.ask($0) }
        deps.record = { [unowned self] in records.append($0) }
        service = DesktopService(deps)
        let message = await failure("desktop_key", ["app": "Notes", "key": "cmd+w"])
        XCTAssertTrue(message.contains("declined"), message)
        XCTAssertTrue(ax.posted.isEmpty)
        XCTAssertEqual(records.map(\.outcome), [.declined])
    }

    func testAFocusThatBecomesRiskyBeforeThePostIsNotTrustedWithoutAnApproval() async {
        // The first read finds a safe focus. By the time the key goes out the focus is on Send, and nobody was asked.
        ax.focusQueue = [subject, sendButton]
        let message = await failure("desktop_key", ["app": "Notes", "key": "return"])
        XCTAssertTrue(message.contains("focus changed"), message)
        XCTAssertTrue(ax.posted.isEmpty)
        XCTAssertTrue(approvals.isEmpty)
        XCTAssertEqual(records.map(\.outcome), [.refused])
    }

    // MARK: S3 always asks

    func testCommandReturnQuitAndCloseAlwaysAsk() async throws {
        for key in ["cmd+return", "cmd+q", "cmd+w", "cmd+shift+q", "cmd+shift+w", "cmd+opt+q"] {
            answer = false
            let declined = await failure("desktop_key", ["app": "Notes", "key": key])
            XCTAssertTrue(declined.contains("declined"), "\(key): \(declined)")
        }
        XCTAssertEqual(approvals.count, 6)
        XCTAssertTrue(ax.posted.isEmpty)
        XCTAssertEqual(records.map(\.outcome), Array(repeating: .declined, count: 6))
        answer = true
        for key in ["cmd+return", "cmd+q", "cmd+w"] { try await value("desktop_key", ["app": "Notes", "key": key]) }
        XCTAssertEqual(approvals.count, 9)
        XCTAssertEqual(ax.posted.map(\.0.keyCode), [36, 12, 13])
    }

    func testThePlainLettersAndOtherCommandCombosDoNotAlwaysAsk() {
        let safe = ["q", "w", "return", "cmd+t", "cmd+l", "cmd+shift+t", "ctrl+w", "opt+return", "tab"]
        for input in safe {
            let stroke = try! DesktopKeys.parse(input).get()
            XCTAssertNil(DesktopSafety.keyApprovalReason(stroke, element: ["Subject"], window: "Draft"), input)
        }
        for input in ["cmd+return", "cmd+q", "cmd+w", "cmd+shift+return", "cmd+shift+w"] {
            let stroke = try! DesktopKeys.parse(input).get()
            XCTAssertNotNil(DesktopSafety.keyApprovalReason(stroke, element: [], window: nil), input)
        }
    }

    func testTheContextRuleOnlyAppliesToReturnAndCommand() {
        let risky = ["Send"]
        func reason(_ key: String, element: [String] = risky, window: String? = nil) -> String? {
            DesktopSafety.keyApprovalReason(try! DesktopKeys.parse(key).get(), element: element, window: window)
        }
        XCTAssertNotNil(reason("return"))
        XCTAssertNotNil(reason("shift+return"))
        XCTAssertNotNil(reason("cmd+l"))
        XCTAssertNotNil(reason("return", element: [], window: "Pay now"))
        XCTAssertNil(reason("tab"))
        XCTAssertNil(reason("a"))
        XCTAssertNil(reason("opt+left"))
        XCTAssertNil(reason("return", element: ["Save"], window: "Notes"))
    }

    // MARK: S4 refusals

    func testKeysAreRefusedInExcludedAppsPasswordManagersPausedCaptureAndPrivateWindows() async throws {
        privacy.setExcluded(["Notes"])
        var message = await failure("desktop_key", ["app": "Notes", "key": "tab"])
        XCTAssertTrue(message.contains("does not read or act on Notes"), message)
        privacy.setExcluded([])
        ax.app = CaptureApp(bundleId: "com.example.1password", name: "Vault", pid: 9)
        message = await failure("desktop_key", ["app": "Vault", "key": "tab"])
        XCTAssertTrue(message.contains("deny list"), message)
        ax.app = CaptureApp(bundleId: "com.example.notes", name: "Notes", pid: 4242)
        privacy.pause(for: 60)
        message = await failure("desktop_key", ["app": "Notes", "key": "tab"])
        XCTAssertTrue(message.contains("paused"), message)
        privacy.resume()
        ax.app = CaptureApp(bundleId: "com.apple.Safari", name: "Browser", pid: 5)
        ax.windowTitle = "Reading — Private Browsing"
        message = await failure("desktop_key", ["app": "Browser", "key": "tab"])
        XCTAssertTrue(message.contains("private browser window"), message)
        XCTAssertTrue(ax.posted.isEmpty)
        XCTAssertEqual(records.map(\.outcome), Array(repeating: .refused, count: 4))
    }

    func testAKeyIsRefusedWhenThePrivateWindowHoldsTheKeyboardFocus() async {
        ax.app = CaptureApp(bundleId: "com.apple.Safari", name: "Browser", pid: 5)
        ax.windowTitle = "Docs"
        ax.keyWindowTitle = "Reading — Private Browsing"
        let message = await failure("desktop_key", ["app": "Browser", "key": "tab"])
        XCTAssertTrue(message.contains("private browser window"), message)
        XCTAssertTrue(ax.posted.isEmpty)
    }

    func testKeysAreRefusedInIronpetsOwnWindowWithoutAccessibilityAndWhenOff() async {
        var deps = DesktopService.Dependencies(privacy: privacy)
        deps.ax = ax
        deps.opener = opener
        deps.enabled = { true }
        var own = deps
        own.ownBundleId = "com.example.notes"
        var message = await DesktopService(own).call("desktop_key", ["app": "Notes", "key": "tab"]).failureMessage
        XCTAssertTrue(message.contains("own windows"), message)
        ax.trusted = false
        message = await DesktopService(deps).call("desktop_key", ["app": "Notes", "key": "tab"]).failureMessage
        XCTAssertTrue(message.contains("Accessibility"), message)
        ax.trusted = true
        var off = deps
        off.enabled = { false }
        message = await DesktopService(off).call("desktop_key", ["app": "Notes", "key": "tab"]).failureMessage
        XCTAssertTrue(message.contains("off"), message)
        XCTAssertTrue(ax.posted.isEmpty)
    }

    func testAKeyIsNeverTypedIntoAPasswordField() async {
        ax.focusedEl = password
        let message = await failure("desktop_key", ["app": "Notes", "key": "a"])
        XCTAssertTrue(message.contains("password"), message)
        XCTAssertTrue(ax.posted.isEmpty)
        XCTAssertEqual(records.map(\.outcome), [.refused])
    }

    func testAnUnknownKeyPostsNothingAndNeedsNoApp() async {
        let message = await failure("desktop_key", ["app": "Notes", "key": "hyper+x"])
        XCTAssertTrue(message.contains("not a modifier"), message)
        XCTAssertTrue(ax.posted.isEmpty)
    }

    // MARK: S5 open URL

    func testAnHttpsAddressOpensInTheNamedBrowser() async throws {
        let out = try await value("desktop_open_url", ["url": "https://example.com/path?q=1", "browser": "Google Chrome"])
        XCTAssertEqual(opener.opened.count, 1)
        XCTAssertEqual(opener.opened[0].0.absoluteString, "https://example.com/path?q=1")
        XCTAssertEqual(opener.opened[0].1, "com.google.Chrome")
        XCTAssertEqual(out["browser"] as? String, "Google Chrome")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].action, "open_url")
        XCTAssertEqual(records[0].outcome, .done)
        XCTAssertEqual(records[0].app, "Google Chrome")
        XCTAssertEqual(records[0].name, "https://example.com/path?q=1")
    }

    func testWithoutABrowserTheFrontmostBrowserIsUsedThenTheDefault() async throws {
        opener.front = "com.apple.Safari"
        try await value("desktop_open_url", ["url": "http://example.com"])
        XCTAssertEqual(opener.opened.last?.1, "com.apple.Safari")
        XCTAssertEqual(records.last?.app, "Safari")
        opener.front = nil
        let out = try await value("desktop_open_url", ["url": "https://example.com"])
        XCTAssertNil(opener.opened.last?.1)
        XCTAssertEqual(out["browser"] as? String, "default browser")
        XCTAssertEqual(records.last?.app, "default browser")
    }

    func testOtherSchemesAreRefused() async {
        let addresses = ["file:///etc/passwd", "javascript:alert(1)", "chrome://settings", "x-apple.systempreferences:com.apple.Passwords",
                         "mailto:a@example.com", "data:text/html,hi", "ftp://example.com/a", "about:blank", "view-source:https://example.com",
                         "FILE:///Users/me", "example.com", "//example.com", "https://", "not a url", "https://exa mple.com"]
        for address in addresses {
            let message = await failure("desktop_open_url", ["url": address])
            XCTAssertFalse(message.isEmpty, address)
        }
        let scheme = await failure("desktop_open_url", ["url": "javascript:alert(1)"])
        XCTAssertTrue(scheme.contains("http and https"), scheme)
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testAddressesWithCredentialsAndDeniedHostsAreRefused() async {
        var message = await failure("desktop_open_url", ["url": "https://good.example.com@evil.example.net/"])
        XCTAssertTrue(message.contains("user name"), message)
        message = await failure("desktop_open_url", ["url": "https://my.1password.com/vaults"])
        XCTAssertTrue(message.contains("deny list"), message)
        message = await failure("desktop_open_url", ["url": "https://pass.proton.me"])
        XCTAssertTrue(message.contains("deny list"), message)
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testTheLogKeepsNoSecretsFromTheAddress() async throws {
        try await value("desktop_open_url", ["url": "https://example.com/cb?code=abc123secret&page=2#access_token=zzz999"])
        XCTAssertEqual(opener.opened.count, 1)
        XCTAssertFalse(records[0].name.contains("abc123secret"), records[0].name)
        XCTAssertFalse(records[0].name.contains("zzz999"), records[0].name)
        XCTAssertTrue(records[0].name.contains("page=2"), records[0].name)
    }

    func testBrowserRefusals() async {
        var message = await failure("desktop_open_url", ["url": "https://example.com", "browser": "Notepad"])
        XCTAssertTrue(message.contains("no browser matches"), message)
        privacy.setExcluded(["com.google.Chrome"])
        message = await failure("desktop_open_url", ["url": "https://example.com", "browser": "Google Chrome"])
        XCTAssertTrue(message.contains("does not open pages in Google Chrome"), message)
        privacy.setExcluded([])
        privacy.pause(for: 60)
        message = await failure("desktop_open_url", ["url": "https://example.com"])
        XCTAssertTrue(message.contains("paused"), message)
        privacy.resume()
        opener.works = false
        message = await failure("desktop_open_url", ["url": "https://example.com"])
        XCTAssertTrue(message.contains("did not open"), message)
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertEqual(records.map(\.outcome), [.refused, .refused, .failed])
        let none = await failure("desktop_open_url", [:])
        XCTAssertTrue(none.contains("url is required"), none)
    }

    // MARK: S6 select, check, expand

    func testCheckSetsTheStateAndIsIdempotent() async throws {
        var checkbox = try await ref("checkbox")
        var out = try await value("desktop_check", ["ref": checkbox, "checked": true])
        XCTAssertEqual(out["action"] as? String, "check (AXPress)")
        XCTAssertEqual(remember.node.value, "1")
        XCTAssertEqual(ax.performed.count, 1)
        // Already checked: succeeds and presses nothing.
        checkbox = try await ref("checkbox")
        out = try await value("desktop_check", ["ref": checkbox, "checked": true])
        XCTAssertEqual(out["action"] as? String, "already checked")
        XCTAssertEqual(ax.performed.count, 1)
        out = try await value("desktop_check", ["ref": checkbox, "checked": false])
        XCTAssertEqual(out["action"] as? String, "uncheck (AXPress)")
        XCTAssertEqual(remember.node.value, "0")
        XCTAssertEqual(records.map(\.action), ["check", "check", "check"])
        XCTAssertEqual(records.map(\.outcome), [.done, .done, .done])
    }

    func testCheckFailsClearlyWhenThereIsNoStateOrTheStateWillNotChange() async throws {
        let button = try await ref("button", "Send")
        var message = await failure("desktop_check", ["ref": button, "checked": true])
        XCTAssertTrue(message.contains("no checked state"), message)
        let radioRef = try await ref("radiobutton")
        message = await failure("desktop_check", ["ref": radioRef, "checked": false])
        XCTAssertTrue(message.contains("cannot be unchecked"), message)
        remember.onPerform = nil
        let checkbox = try await ref("checkbox")
        message = await failure("desktop_check", ["ref": checkbox, "checked": true])
        XCTAssertTrue(message.contains("still unchecked"), message)
        let missing = await failure("desktop_check", ["ref": checkbox])
        XCTAssertTrue(missing.contains("checked is required"), missing)
    }

    func testCheckOnARadioButtonThatIsOnDoesNothing() async throws {
        let radioRef = try await ref("radiobutton")
        let out = try await value("desktop_check", ["ref": radioRef, "checked": true])
        XCTAssertEqual(out["action"] as? String, "already checked")
        XCTAssertTrue(ax.performed.isEmpty)
    }

    func testExpandUsesTheDisclosureAttributeOrThePressAction() async throws {
        let row = try await ref("row", "Folder")
        var out = try await value("desktop_expand", ["ref": row, "expand": true])
        XCTAssertEqual(out["action"] as? String, "set AXDisclosing")
        XCTAssertEqual(folder.bools["AXDisclosing"], true)
        out = try await value("desktop_expand", ["ref": row, "expand": true])
        XCTAssertEqual(out["action"] as? String, "already expanded")
        out = try await value("desktop_expand", ["ref": row, "expand": false])
        XCTAssertEqual(folder.bools["AXDisclosing"], false)
        XCTAssertEqual(ax.boolSets.map(\.1), [true, false])

        var triangleRef = try await ref("disclosuretriangle")
        out = try await value("desktop_expand", ["ref": triangleRef, "expand": true])
        XCTAssertEqual(out["action"] as? String, "AXPress")
        XCTAssertEqual(triangle.node.value, "1")
        triangleRef = try await ref("disclosuretriangle")
        out = try await value("desktop_expand", ["ref": triangleRef, "expand": true])
        XCTAssertEqual(out["action"] as? String, "already expanded")
        XCTAssertEqual(ax.performed.count, 1)
        let missing = await failure("desktop_expand", ["ref": triangleRef])
        XCTAssertTrue(missing.contains("expand is required"), missing)
    }

    func testExpandOpensAndClosesAPopup() async throws {
        let popup = try await ref("popupbutton")
        var out = try await value("desktop_expand", ["ref": popup, "expand": true])
        XCTAssertEqual(out["action"] as? String, "AXPress")
        out = try await value("desktop_expand", ["ref": popup, "expand": false])
        XCTAssertEqual(out["action"] as? String, "AXCancel")
        XCTAssertEqual(ax.performed.map(\.0), ["AXPress", "AXCancel"])
    }

    func testExpandRefusesAnElementThatCannotExpand() async throws {
        let message = await failure("desktop_expand", ["ref": try await ref("button", "Send"), "expand": true])
        XCTAssertTrue(message.contains("cannot be expanded"), message)
    }

    func testSelectPicksAnOptionOfAPopupByItsText() async throws {
        let popup = try await ref("popupbutton")
        let out = try await value("desktop_select", ["ref": popup, "text": "helvetica"])
        XCTAssertEqual(out["action"] as? String, "AXPress \"Helvetica\"")
        XCTAssertEqual(ax.performed.map(\.0), ["AXPress", "AXPress"])
        XCTAssertEqual(ax.performed.map(\.1), ["Font", "Helvetica"])
        XCTAssertEqual(records.map(\.action), ["select"])
        XCTAssertEqual(records.map(\.outcome), [.done])
    }

    func testSelectPrefersAnExactMatchAndRejectsAmbiguousOrMissingOptions() async throws {
        let popup = try await ref("popupbutton")
        try await value("desktop_select", ["ref": popup, "text": "Times"])
        XCTAssertEqual(ax.performed.last?.1, "Times")
        var message = await failure("desktop_select", ["ref": popup, "text": "Tim"])
        XCTAssertTrue(message.contains("2 options match"), message)
        message = await failure("desktop_select", ["ref": popup, "text": "Courier"])
        XCTAssertTrue(message.contains("no option matches"), message)
        XCTAssertTrue(message.contains("\"Helvetica\""), message)
        // The failed attempts opened the popup, so they closed it again.
        XCTAssertEqual(ax.performed.filter { $0.0 == "AXCancel" }.count, 2)
    }

    func testSelectPicksARowByTheTextInsideIt() async throws {
        let list = try await ref("list")
        let out = try await value("desktop_select", ["ref": list, "text": "sent"])
        XCTAssertEqual(out["action"] as? String, "select \"Sent items\"")
        XCTAssertEqual(ax.boolSets.map(\.0), ["AXSelected"])
        XCTAssertEqual(sent.bools["AXSelected"], true)
        XCTAssertEqual(inbox.bools["AXSelected"], false)
        // Selecting it again does nothing more.
        let again = try await value("desktop_select", ["ref": list, "text": "Sent items"])
        XCTAssertEqual(again["action"] as? String, "already selected")
        XCTAssertEqual(ax.boolSets.count, 1)
    }

    func testSelectWithoutTextSelectsTheElementItself() async throws {
        // The first row is Folder. The unnamed rows of the mailbox list follow it, in outline order.
        let found = try await value("desktop_find", ["app": "Notes", "role": "row"])
        let lines = try XCTUnwrap(found["elements"] as? String).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        let row = String(try XCTUnwrap(lines[1].split(separator: " ").last))
        let out = try await value("desktop_select", ["ref": row])
        XCTAssertEqual(out["action"] as? String, "select \"row\"")
        XCTAssertEqual(inbox.bools["AXSelected"], true)
        XCTAssertEqual(sent.bools["AXSelected"], false)
    }

    func testSelectNeedsAnApprovalWhenTheTextOrTheOptionSaysDelete() async throws {
        let popup = try await ref("popupbutton")
        // The agent names the risky option in full, so the user is asked first.
        answer = false
        var message = await failure("desktop_select", ["ref": popup, "text": "Delete all fonts"])
        XCTAssertTrue(message.contains("declined"), message)
        XCTAssertEqual(approvals.count, 1)
        XCTAssertTrue(ax.performed.isEmpty)
        XCTAssertEqual(records.map(\.outcome), [.declined])
        answer = true
        try await value("desktop_select", ["ref": popup, "text": "Delete all fonts"])
        XCTAssertEqual(ax.performed.last?.1, "Delete all fonts")
        // A short text that happens to match a risky option is not enough: the user was not asked about it.
        ax.performed = []
        approvals = []
        message = await failure("desktop_select", ["ref": popup, "text": "all fonts"])
        XCTAssertTrue(message.contains("says \"delete\""), message)
        XCTAssertTrue(approvals.isEmpty)
        XCTAssertEqual(ax.performed.map(\.0), ["AXPress", "AXCancel"])
    }

    func testTheNewActionsFollowTheStaleRefAndApprovalRulesOfPress() async throws {
        let checkbox = try await ref("checkbox")
        remember.node.title = "Remember"
        var message = await failure("desktop_check", ["ref": checkbox, "checked": true])
        XCTAssertTrue(message.contains("new desktop_snapshot"), message)
        message = await failure("desktop_expand", ["ref": "#nope", "expand": true])
        XCTAssertTrue(message.contains("new desktop_snapshot"), message)
        message = await failure("desktop_select", ["ref": "#nope"])
        XCTAssertTrue(message.contains("new desktop_snapshot"), message)
        remember.node.title = "Send me updates"
        let risky = try await ref("checkbox")
        answer = false
        message = await failure("desktop_check", ["ref": risky, "checked": true])
        XCTAssertTrue(message.contains("declined"), message)
        XCTAssertTrue(ax.performed.isEmpty)
        XCTAssertEqual(approvals.count, 1)
        XCTAssertTrue(approvals[0].title.hasPrefix("check checkbox"), approvals[0].title)
        answer = true
        try await value("desktop_check", ["ref": risky, "checked": true])
        XCTAssertEqual(remember.node.value, "1")
    }

    func testTheNewActionsNeverTouchAPasswordField() async throws {
        let secure = try await ref("securetextfield")
        for (tool, extra) in [("desktop_select", [:]), ("desktop_check", ["checked": true]), ("desktop_expand", ["expand": true])] as [(String, [String: Any])] {
            let message = await failure(tool, ["ref": secure].merging(extra) { a, _ in a })
            XCTAssertTrue(message.contains("password"), "\(tool): \(message)")
        }
        XCTAssertTrue(ax.performed.isEmpty && ax.boolSets.isEmpty)
    }

    // MARK: Log and tool list

    func testKeyAndUrlRecordsBecomeReadableActivityEvents() {
        let key = DesktopActionRecord(at: Date(timeIntervalSince1970: 100), app: "Notes", window: "Draft", role: "", name: "", action: "key cmd+l", outcome: .done)
        XCTAssertEqual(ActivityEvent.desktopAction(key).title, "key cmd+l in Notes")
        let focused = DesktopActionRecord(at: Date(), app: "Notes", window: "Draft", role: "TextField", name: "Subject", action: "key tab", outcome: .done)
        XCTAssertEqual(ActivityEvent.desktopAction(focused).title, "key tab TextField \"Subject\" in Notes")
    }

    func testTheNewToolsAreListed() {
        for name in ["desktop_key", "desktop_open_url", "desktop_select", "desktop_check", "desktop_expand"] {
            XCTAssertTrue(DesktopMCP.names.contains(name), name)
        }
        let key = DesktopMCP.tools.first { $0["name"] as? String == "desktop_key" }
        let schema = key?["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["required"] as? [String], ["app", "key"])
    }
}

private extension Result where Failure == ScreenMCP.Failure {
    var failureMessage: String {
        if case .failure(let failure) = self { return failure.message }
        return ""
    }
}
