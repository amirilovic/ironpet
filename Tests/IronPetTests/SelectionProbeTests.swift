import AppKit
import XCTest
@testable import IronPet

@MainActor
final class SelectionProbeTests: XCTestCase {
    private func view(_ markdown: String) -> ChatTextView {
        let view = ChatTextView.make()
        view.setContent(MarkdownText.attributed(Markdown.parse(markdown), size: 13.5, find: nil))
        view.frame = CGRect(origin: .zero, size: view.fittingSize(forWidth: 300))
        return view
    }

    func testReadsTheSelectionWithoutTouchingThePasteboard() {
        let view = view("Intro\n\n- one\n- two")
        let board = NSPasteboard.general
        board.clearContents()
        board.setString("kept", forType: .string)
        let count = board.changeCount
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        XCTAssertEqual(SelectionProbe.selectedText(in: view), "Intro\n- one\n- two")
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(board.string(forType: .string), "kept")
    }

    func testEmptySelectionIsNil() {
        let view = view("Some text")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertNil(SelectionProbe.selectedText(in: view))
    }

    func testWhitespaceOnlySelectionIsNil() {
        let view = view("a\n\nb")
        view.setSelectedRange(NSRange(location: 1, length: 1))
        XCTAssertNil(SelectionProbe.selectedText(in: view))
    }
}
