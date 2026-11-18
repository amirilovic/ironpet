import XCTest
@testable import IronPet

final class CaptureTextTests: XCTestCase {
    func testControlLabelsAreDroppedAndMessagesAndTheDraftAreKept() {
        let lines = CaptureText.lines(in: CaptureFixtures.slack(messages: ["Can you review PR 4649?", "The deploy waits for it."], draft: "On it, give me ten minutes"))
        XCTAssertEqual(lines, ["Ana", "Can you review PR 4649?", "Ana", "The deploy waits for it.", "On it, give me ten minutes"])
        for label in ["Bold: off", "Italic: off", "Send now", "Back", "Link", "Attach", "Message to Ana"] {
            XCTAssertFalse(lines.contains { $0.contains(label) }, label)
        }
    }

    func testChromeRolesAreSkippedWithTheirChildren() {
        let tree = AXNode(role: "Window", children: [
            AXNode(role: "MenuBar", children: [AXNode(role: "MenuBarItem", title: "File")]),
            AXNode(role: "TabGroup", children: [AXNode(role: "Tab", title: "Inbox (3)")]),
            AXNode(role: "CheckBox", title: "Remember me", value: "1"),
            AXNode(role: "PopUpButton", title: "Sort by", value: "Date"),
            AXNode(role: "Group", subrole: "Toolbar", children: [AXNode(role: "StaticText", value: "toolbar text")]),
            AXNode(role: "Group", children: [AXNode(role: "Heading", title: "Release notes"), AXNode(role: "StaticText", value: "Version 2 is out")]),
        ])
        XCTAssertEqual(CaptureText.lines(in: tree), ["Release notes", "Version 2 is out"])
    }

    func testASecureFieldIsNeverRead() {
        // The source does not read a secure field's value, and the walk drops it even if a value were there.
        let tree = AXNode(role: "Window", children: [
            AXNode(role: "TextField", value: "ana@example.com"),
            AXNode(role: "TextField", subrole: "SecureTextField", value: "correct horse battery staple"),
            AXNode(role: "SecureTextField", value: "hunter2hunter2"),
        ])
        let lines = CaptureText.lines(in: tree)
        XCTAssertEqual(lines, ["ana@example.com"])
    }

    func testHiddenNodesMultilineValuesAndRepeatsAreHandled() {
        let tree = AXNode(role: "Window", children: [
            AXNode(role: "StaticText", value: "off screen", hidden: true),
            AXNode(role: "TextArea", value: "  first line \n\n second line\n"),
            AXNode(role: "StaticText", value: "second line"),
            AXNode(role: "Link", title: "Open the report"),
            AXNode(role: "Link", title: "ignored title", children: [AXNode(role: "StaticText", value: "Docs")]),
        ])
        XCTAssertEqual(CaptureText.lines(in: tree), ["first line", "second line", "Open the report", "Docs"])
    }

    func testThePageURLComesFromTheWebArea() {
        XCTAssertEqual(CaptureText.pageURL(in: CaptureFixtures.slack(messages: [])), "https://app.slack.com/client/T1/C1")
        XCTAssertNil(CaptureText.pageURL(in: AXNode(role: "Window", children: [AXNode(role: "StaticText", value: "x")])))
    }

    func testTextIsCapped() {
        let big = AXNode(role: "Window", children: (0..<5_000).map { AXNode(role: "StaticText", value: "line number \($0) " + String(repeating: "x", count: 60)) })
        XCTAssertLessThanOrEqual(CaptureText.lines(in: big).joined(separator: "\n").count, CaptureText.maxCharacters + 200)
    }
}

final class CaptureDiffTests: XCTestCase {
    private let base = ["a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8"]

    func testNothingNewStoresNothing() {
        XCTAssertNil(CaptureDiff.fresh(previous: base, current: base))
        XCTAssertNil(CaptureDiff.fresh(previous: base, current: Array(base.reversed())), "moved lines are not new")
        XCTAssertNil(CaptureDiff.fresh(previous: base, current: Array(base.prefix(3))), "removed lines are not new")
    }

    func testTwoAddedLinesComeBackWithContextAndNotTheWholeWindow() {
        var current = base
        current.insert(contentsOf: ["new one", "new two"], at: 4)
        XCTAssertEqual(CaptureDiff.fresh(previous: base, current: current), "a3\na4\nnew one\nnew two\na5\na6")
    }

    func testSeparateChunksAreMarked() {
        let previous = (1...20).map { "line \($0)" }
        var current = previous
        current.insert("first new", at: 2)
        current.append("last new")
        XCTAssertEqual(CaptureDiff.fresh(previous: previous, current: current), "line 1\nline 2\nfirst new\nline 3\nline 4\n…\nline 19\nline 20\nlast new")
    }

    func testAFirstCaptureStoresTheWholeWindow() {
        XCTAssertEqual(CaptureDiff.fresh(previous: [], current: ["x", "y"]), "x\ny")
    }
}

final class CaptureInputTests: XCTestCase {
    func testAnEmptyInputAddsNoPlaceholderOrFieldName() {
        let tree = AXNode(role: "Window", children: [AXNode(role: "TextArea", value: "", description: "Message to Ana"),
                                                     AXNode(role: "TextField", title: "Search", value: nil)])
        XCTAssertEqual(CaptureText.lines(in: tree), [])
    }
}
