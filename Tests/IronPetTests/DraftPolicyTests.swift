import XCTest
@testable import IronPet

final class DraftPolicyTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testShortTextStaysInInput() {
        let result = DraftPolicy.apply("hello", into: dir)
        XCTAssertEqual(result.input, "hello")
        XCTAssertNil(result.attachment)
    }

    func testTextAtLimitStaysInInput() {
        let text = String(repeating: "a", count: DraftPolicy.limit)
        XCTAssertNil(DraftPolicy.apply(text, into: dir).attachment)
    }

    func testLongTextBecomesAttachmentWithFullContent() throws {
        let text = String(repeating: "x", count: 5 * 1024 * 1024)
        let result = DraftPolicy.apply(text, into: dir)
        XCTAssertEqual(result.input, "")
        let file = try XCTUnwrap(result.attachment)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
        XCTAssertTrue(file.path.hasPrefix(dir.path))
    }

    func testUnwritableDirectoryTruncatesToLimit() {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: blocker) }
        let result = DraftPolicy.apply(String(repeating: "é", count: DraftPolicy.limit), into: blocker)
        XCTAssertNil(result.attachment)
        XCTAssertLessThanOrEqual(result.input.utf8.count, DraftPolicy.limit)
    }

    /// The input is always at or under the limit once its didSet has run, and that value is what gets persisted.
    @MainActor
    func testTheDraftMovesLongInputToAnAttachment() throws {
        let h = ChatHarness(draftDirectory: dir)
        let text = String(repeating: "y", count: 200 * 1024)
        h.model.input = text
        XCTAssertEqual(h.model.input, "")
        XCTAssertLessThanOrEqual(h.model.input.utf8.count, DraftPolicy.limit)
        let file = try XCTUnwrap(h.model.attachments.first)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
    }
}
