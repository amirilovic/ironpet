import AppKit
import XCTest
@testable import IronPet

final class PasteIntakeTests: XCTestCase {
    private var dir: URL!
    private var board: NSPasteboard!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        board.clearContents()
    }

    override func tearDownWithError() throws {
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: dir)
    }

    func testLargeTextBecomesAttachment() throws {
        let text = String(repeating: "log line\n", count: 25_000)
        XCTAssertGreaterThan(text.utf8.count, 200_000)
        board.setString(text, forType: .string)
        XCTAssertEqual(PasteIntake.decide(board), .largeText(text))
        let saved = PasteIntake.importPaste(board, imageDirectory: dir, textDirectory: dir)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].lastPathComponent, "pasted-text.txt")
        XCTAssertEqual(try String(contentsOf: saved[0], encoding: .utf8), text)
    }

    func testSmallTextStaysInField() {
        board.setString("hello", forType: .string)
        XCTAssertEqual(PasteIntake.decide(board), .field)
        XCTAssertTrue(PasteIntake.importPaste(board, imageDirectory: dir, textDirectory: dir).isEmpty)
    }

    func testTextAtLimitStaysInField() {
        board.setString(String(repeating: "a", count: DraftPolicy.limit), forType: .string)
        XCTAssertEqual(PasteIntake.decide(board), .field)
    }

    func testImageDataAttachesAsPNG() {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        board.setData(rep.representation(using: .png, properties: [:])!, forType: .png)
        XCTAssertEqual(PasteIntake.decide(board), .image)
        let saved = PasteIntake.importPaste(board, imageDirectory: dir, textDirectory: dir)
        XCTAssertEqual(saved.map(\.pathExtension), ["png"])
    }

    func testEmptyPasteboardGoesToField() {
        XCTAssertEqual(PasteIntake.decide(board), .field)
    }
}
