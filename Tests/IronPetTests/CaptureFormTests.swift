import XCTest
@testable import IronPet

/// Forms: a field being typed in is held back, then emitted once with the whole form around it.
final class CaptureFormTests: XCTestCase {
    private let app = CaptureApp(bundleId: "com.example.browser", name: "Browser", pid: 7)
    private let frame = CaptureRect(x: 0, y: 0, width: 400, height: 300)

    private func field(_ role: String = "TextField", name: String? = nil, value: String, label: String? = nil, focused: Bool = false,
                       placeholder: String? = nil) -> CaptureNode {
        var attrs: [String: String] = [:]
        if let label { attrs["label"] = label }
        if let placeholder { attrs["placeholder"] = placeholder }
        return CaptureNode(role: role, name: name, value: value, attrs: attrs, focused: focused)
    }

    private func text(_ value: String) -> CaptureNode { CaptureNode(role: "StaticText", value: value) }

    /// The shape of a Google Calendar create-event dialog in Chrome: a dialog group in a web area, with a heading and fields whose
    /// labels are descriptions, placeholders or the text before them.
    private func calendar(title: String, focused: Bool = true, closed: Bool = false) -> CaptureSnapshot {
        let dialog = CaptureNode(role: "Group", attrs: ["subrole": "ApplicationDialog"], frame: frame, children: [
            CaptureNode(role: "Heading", value: "New event"),
            field(value: title, focused: focused, placeholder: "Add title"),
            text("Date"), field("DateField", value: "Wednesday, 18 November 2026"),
            text("Time"), field("TimeField", value: "15:00 – 16:00"),
            field("PopUpButton", value: "Aleks", label: "Calendar"),
            CaptureNode(role: "Button", name: "Save"),
        ])
        let web = CaptureNode(role: "WebArea", children: closed ? [text("Calendar week view")] : [text("Calendar week view"), dialog])
        return CaptureSnapshot(app: app, windowTitle: "Calendar", url: "https://calendar.example.com/week",
                               root: CaptureNode(role: "Window", frame: CaptureRect(x: 0, y: 0, width: 1200, height: 800), children: [web]))
    }

    private func tracker(settle: TimeInterval = 4) -> CaptureFormTracker { CaptureFormTracker(settle: settle) }

    // MARK: S1 settle

    func testTypingEmitsNothingPerKeystrokeAndOneFormWhenTheFieldSettles() {
        let tracker = tracker()
        var now = 100.0
        let typed = ["R", "Re", "Reifenw", "Tyre", "Gume zamena", "🛞 Gume zamena"]
        for value in typed {
            XCTAssertTrue(tracker.observe(calendar(title: value), now: now), "the read of a form being edited is held back")
            XCTAssertTrue(tracker.takeReady(now: now).isEmpty, "no item per keystroke")
            now += 0.9
        }
        XCTAssertNotNil(tracker.nextWake)
        XCTAssertTrue(tracker.takeReady(now: now + 2).isEmpty, "not settled yet")
        let out = tracker.takeReady(now: now + 4)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].body.contains("Add title: 🛞 Gume zamena"))
        XCTAssertFalse(out[0].body.contains("Reifenw"))
        XCTAssertTrue(tracker.takeReady(now: now + 30).isEmpty, "unchanged, so not sent again")
    }

    func testLeavingTheFieldEmitsAtOnce() {
        let tracker = tracker()
        tracker.observe(calendar(title: "Tyre"), now: 1)
        XCTAssertFalse(tracker.observe(calendar(title: "Tyre change", focused: false), now: 2), "no field is being edited now")
        let out = tracker.takeReady(now: 2)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].body.contains("Tyre change"))
    }

    // MARK: S2 container

    func testAFieldInADialogUsesTheDialog() throws {
        let chain = try XCTUnwrap(CaptureForm.editedChain(in: calendar(title: "x").root))
        let container = CaptureForm.container(of: chain)
        XCTAssertEqual(container.kind, .dialog)
        XCTAssertEqual(container.node.attrs["subrole"], "ApplicationDialog")
    }

    func testASheetAndAWebFormAreContainers() throws {
        for (role, subrole) in [("Sheet", nil), ("Form", nil), ("Group", "LandmarkForm"), ("Group", "SystemDialog")] {
            var attrs: [String: String] = [:]
            if let subrole { attrs["subrole"] = subrole }
            let tree = CaptureNode(role: "Window", children: [CaptureNode(role: "WebArea", children: [
                CaptureNode(role: role, attrs: attrs, children: [field(value: "a", focused: true)]),
            ])])
            let container = CaptureForm.container(of: try XCTUnwrap(CaptureForm.editedChain(in: tree)))
            XCTAssertEqual(container.kind, .dialog, "\(role) \(subrole ?? "")")
            XCTAssertEqual(container.node.role, role)
        }
    }

    func testADialogWinsOverASmallGroupInsideIt() throws {
        let row = CaptureNode(role: "Group", children: [field(value: "18 Nov", focused: true), field("TimeField", value: "15:00")])
        let tree = CaptureNode(role: "Window", children: [CaptureNode(role: "Group", attrs: ["subrole": "ApplicationDialog"], children: [
            field(value: "Tyre change", placeholder: "Add title"), row,
        ])])
        let container = CaptureForm.container(of: try XCTUnwrap(CaptureForm.editedChain(in: tree)))
        XCTAssertEqual(container.kind, .dialog)
        XCTAssertTrue(CaptureForm.body(of: container.node).contains("Add title: Tyre change"))
    }

    func testABareGroupWithTwoInputsIsAContainerButAHugeOneIsNot() throws {
        let small = CaptureNode(role: "Window", children: [CaptureNode(role: "Group", children: [
            CaptureNode(role: "Group", children: [field(value: "a", focused: true)]),
            CaptureNode(role: "Group", children: [field(value: "b")]),
        ])])
        XCTAssertEqual(CaptureForm.container(of: try XCTUnwrap(CaptureForm.editedChain(in: small))).kind, .group)

        let filler = (0..<CaptureForm.groupBudget).map { _ in text("row") }
        let huge = CaptureNode(role: "Window", children: [CaptureNode(role: "Group", children: [field(value: "a", focused: true), field(value: "b")] + filler)])
        XCTAssertEqual(CaptureForm.container(of: try XCTUnwrap(CaptureForm.editedChain(in: huge))).kind, .field, "never the whole window")
    }

    func testAFieldDirectlyInTheWindowFallsBackToTheFieldAndItsLabel() throws {
        let tree = CaptureNode(role: "Window", children: [text("Unrelated"), text("Subject"), field(value: "Hello", focused: true), text("After")])
        let container = CaptureForm.container(of: try XCTUnwrap(CaptureForm.editedChain(in: tree)))
        XCTAssertEqual(container.kind, .field)
        XCTAssertEqual(CaptureForm.body(of: container.node), "Subject: Hello")
        let tracker = tracker()
        let snapshot = CaptureSnapshot(app: app, root: tree)
        XCTAssertFalse(tracker.observe(snapshot, now: 1), "a field with no form is read as before")
        XCTAssertTrue(tracker.isIdle)
    }

    func testASecureFieldIsNeverTheEditedField() {
        var password = field(value: "hunter2", focused: true)
        password.attrs["subrole"] = "SecureTextField"
        let tree = CaptureNode(role: "Window", children: [CaptureNode(role: "Dialog", children: [password, field(value: "x")])])
        XCTAssertNil(CaptureForm.editedChain(in: tree))
    }

    // MARK: S3 labels

    func testTheCalendarFormGivesOneLabelledBody() throws {
        let tracker = tracker()
        tracker.observe(calendar(title: "🛞 Gume zamena"), now: 1)
        let out = tracker.takeReady(now: 6)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].body, """
            New event
            Add title: 🛞 Gume zamena
            Date: Wednesday, 18 November 2026
            Time: 15:00 – 16:00
            Calendar: Aleks
            """)
        XCTAssertEqual(out[0].title, "New event")
    }

    func testALabelComesFromTitleDescriptionTitleElementPlaceholderThenPrecedingText() {
        var byTitleElement = field(value: "c")
        byTitleElement.attrs["title_ui"] = "Gamma"
        let dialog = CaptureNode(role: "Dialog", children: [
            field(name: "Alpha", value: "a"), field(value: "b", label: "Beta"), byTitleElement,
            field(value: "d", placeholder: "Delta"), text("Epsilon"), field(value: "e"), field(value: "no label at all"),
        ])
        XCTAssertEqual(CaptureForm.body(of: dialog), "Alpha: a\nBeta: b\nGamma: c\nDelta: d\nEpsilon: e\nno label at all")
    }

    // MARK: S4 submit

    func testPressingAButtonThenTheFormClosingIsSubmitted() {
        let tracker = tracker()
        tracker.observe(calendar(title: "Tyre change"), now: 1)
        tracker.notePress(app: app, title: "Save", now: 5)
        tracker.observe(calendar(title: "Tyre change", closed: true), now: 6)
        let out = tracker.takeReady(now: 6)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].body.split(separator: "\n").first, "Submitted: Save")
        XCTAssertTrue(out[0].body.contains("Add title: Tyre change"), "the last snapshot of the form comes with the marker")
    }

    func testClosingWithoutAPressIsMarked() {
        let tracker = tracker()
        tracker.observe(calendar(title: "Tyre change"), now: 1)
        _ = tracker.takeReady(now: 10)
        tracker.observe(calendar(title: "Tyre change", closed: true), now: 11)
        let out = tracker.takeReady(now: 11)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].body.split(separator: "\n").first, "Closed without submit")
    }

    func testAPressLongBeforeTheCloseIsNotASubmit() {
        let tracker = tracker()
        tracker.observe(calendar(title: "Tyre change"), now: 1)
        tracker.notePress(app: app, title: "Save", now: 2)
        tracker.observe(calendar(title: "Tyre change", closed: true), now: 60)
        XCTAssertEqual(tracker.takeReady(now: 60).first?.body.split(separator: "\n").first, "Closed without submit")
    }

    // MARK: S5 dedupe

    func testEditingASecondFieldReplacesThePendingItem() {
        let tracker = tracker()
        tracker.observe(calendar(title: "Tyre"), now: 1)
        var second = calendar(title: "Tyre", focused: false)
        second.root.children[0].children[1].children[6].focused = true
        second.root.children[0].children[1].children[6].value = "Aleks, Peter"
        tracker.observe(second, now: 3)
        let out = tracker.takeReady(now: 7)
        XCTAssertEqual(out.count, 1, "one item for the form")
        XCTAssertTrue(out[0].body.contains("Calendar: Aleks, Peter"))
        XCTAssertTrue(tracker.takeReady(now: 30).isEmpty, "an unchanged form is not sent again")
    }

    // MARK: S6 pipeline

    private func pipeline(_ store: CaptureStore) -> CapturePipeline {
        CapturePipeline(privacy: CapturePrivacy(), rules: CaptureRules(), store: store)
    }

    func testAFormIsStoredAsOneItemWithTheWholeBody() throws {
        let store = CaptureStore.inMemory()
        let tracker = tracker()
        tracker.observe(calendar(title: "🛞 Gume zamena"), now: 1)
        let form = try XCTUnwrap(tracker.takeReady(now: 6).first)
        guard case .stored(_, let result) = pipeline(store).process(form: form) else { return XCTFail("not stored") }
        XCTAssertNotNil(result.itemId)
        let body = try XCTUnwrap(store.recent(limit: 1).first?.body)
        for part in ["Gume zamena", "Wednesday, 18 November 2026", "15:00", "Calendar: Aleks"] { XCTAssertTrue(body.contains(part), part) }
        XCTAssertEqual(store.itemCount, 1)
        // The same form again stores nothing.
        guard case .stored(_, let again) = pipeline(store).process(form: form) else { return XCTFail("not stored") }
        XCTAssertNil(again.itemId)
    }

    func testASecretInAFormFieldIsStillRedacted() throws {
        let secret = "sk-" + "proj-" + String(repeating: "Ab3d", count: 8)
        let store = CaptureStore.inMemory()
        let tracker = tracker()
        var snapshot = calendar(title: "Deploy key \(secret)")
        snapshot.root.children[0].children[1].children[1].value = "Deploy key \(secret)"
        tracker.observe(snapshot, now: 1)
        let form = try XCTUnwrap(tracker.takeReady(now: 6).first)
        _ = pipeline(store).process(form: form)
        let body = try XCTUnwrap(store.recent(limit: 1).first?.body)
        XCTAssertFalse(body.contains(secret))
        XCTAssertTrue(body.contains("[redacted:"))
    }

    func testAPausedPipelineDropsAFinishedForm() throws {
        let privacy = CapturePrivacy()
        privacy.pause(for: 600)
        let store = CaptureStore.inMemory()
        let tracker = tracker()
        tracker.observe(calendar(title: "Tyre"), now: 1)
        let form = try XCTUnwrap(tracker.takeReady(now: 6).first)
        guard case .skipped = CapturePipeline(privacy: privacy, rules: CaptureRules(), store: store).process(form: form) else { return XCTFail("stored while paused") }
        XCTAssertEqual(store.itemCount, 0)
    }

    func testTheReaderHoldsTheReadOfAnEditedFormAndLeavesOtherWindowsAlone() {
        final class Source: CaptureSource {
            var snapshot: CaptureSnapshot
            init(_ snapshot: CaptureSnapshot) { self.snapshot = snapshot }
            func start(onEvent: @escaping (CaptureEvent) -> Void) {}
            func stop() {}
            var isTrusted: Bool { true }
            func frontmostApp() -> CaptureApp? { snapshot.app }
            func readFocusedWindow(of app: CaptureApp, budget: CaptureReadBudget) -> CaptureSnapshot? { snapshot }
            func readText(in rect: CaptureRect) -> [String]? { nil }
            func isWebApp(_ app: CaptureApp) -> Bool { false }
            func enableWebAccessibility(_ app: CaptureApp) {}
        }
        let source = Source(calendar(title: "Ty"))
        let reader = CaptureReader(source: source, settle: 0, mayRead: { _ in true })
        reader.onEvent(CaptureEvent(app: app, kind: .valueChanged), now: 0)
        XCTAssertTrue(reader.readDue(now: 1).isEmpty, "the half-typed form is not stored as page text")
        source.snapshot = CaptureSnapshot(app: app, root: CaptureNode(role: "Window", children: [text("Please send the invoice")]))
        reader.onEvent(CaptureEvent(app: app, kind: .valueChanged), now: 2)
        XCTAssertEqual(reader.readDue(now: 3).count, 1, "a window with no form is read as before")
        XCTAssertEqual(reader.takeForms(now: 3).count, 1, "focus left the form, so the form is emitted")
    }
}
