import XCTest
@testable import IronPet

final class MessageCollapseTests: XCTestCase {
    func testShortMessageIsNotCollapsed() {
        XCTAssertNil(MessageCollapse.preview(of: "hello"))
        XCTAssertNil(MessageCollapse.preview(of: String(repeating: "a", count: MessageCollapse.maxCharacters)))
    }

    func testManyLinesCollapse() {
        let text = (0..<(MessageCollapse.maxLines + 1)).map { "l\($0)" }.joined(separator: "\n")
        let preview = MessageCollapse.preview(of: text)
        XCTAssertEqual(preview?.text.split(separator: "\n").count, MessageCollapse.previewLines)
    }

    func testThirtyLinesStayExpanded() {
        let text = (0..<MessageCollapse.maxLines).map { "l\($0)" }.joined(separator: "\n")
        XCTAssertNil(MessageCollapse.preview(of: text))
    }

    func testLongTextCutsAtWordBoundary() throws {
        let text = String(repeating: "word ", count: 12_000)
        let preview = try XCTUnwrap(MessageCollapse.preview(of: text))
        XCTAssertLessThanOrEqual(preview.text.count, MessageCollapse.previewCharacters)
        XCTAssertTrue(preview.text.hasSuffix("word"))
        XCTAssertEqual(preview.hiddenCharacters, text.count - preview.text.count)
    }

    func testHiddenTextIsNotInPreview() throws {
        let text = String(repeating: "a", count: 2_000) + "SECRET"
        let preview = try XCTUnwrap(MessageCollapse.preview(of: text))
        XCTAssertFalse(preview.text.contains("SECRET"))
        XCTAssertEqual(preview.text.count, MessageCollapse.previewCharacters)
    }

    func testThirtyLinesWithTrailingNewlineStayExpanded() {
        let text = (0..<MessageCollapse.maxLines).map { "l\($0)" }.joined(separator: "\n") + "\n"
        XCTAssertNil(MessageCollapse.preview(of: text))
    }

    func testCRLFLinesCollapse() {
        let text = (0..<(MessageCollapse.maxLines + 1)).map { "l\($0)" }.joined(separator: "\r\n")
        XCTAssertEqual(MessageCollapse.preview(of: text)?.text.split(whereSeparator: \.isNewline).count, MessageCollapse.previewLines)
    }
}
