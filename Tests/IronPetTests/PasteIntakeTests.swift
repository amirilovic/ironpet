import AppKit
import XCTest
@testable import IronPet

@MainActor
final class PasteIntakeTests: XCTestCase {
    private var dir: URL!
    private var board: NSPasteboard!
    private let limits = PasteLimits(chars: 4_000, lines: 60)

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
        XCTAssertEqual(PasteIntake.decide(board, limits: limits), .largeText(text))
        let saved = PasteIntake.importPaste(board, imageDirectory: dir, textDirectory: dir, limits: limits)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].lastPathComponent, "pasted-text.txt")
        XCTAssertEqual(try String(contentsOf: saved[0], encoding: .utf8), text)
    }

    func testSmallTextStaysInField() {
        board.setString("hello", forType: .string)
        XCTAssertEqual(PasteIntake.decide(board, limits: limits), .field)
        XCTAssertTrue(PasteIntake.importPaste(board, imageDirectory: dir, textDirectory: dir, limits: limits).isEmpty)
    }

    func testTextAtLimitStaysInField() {
        board.setString(String(repeating: "a", count: limits.chars), forType: .string)
        XCTAssertEqual(PasteIntake.decide(board, limits: limits), .field)
    }

    func testImageDataAttachesAsPNG() {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        board.setData(rep.representation(using: .png, properties: [:])!, forType: .png)
        XCTAssertEqual(PasteIntake.decide(board, limits: limits), .image)
        let saved = PasteIntake.importPaste(board, imageDirectory: dir, textDirectory: dir, limits: limits)
        XCTAssertEqual(saved.map(\.pathExtension), ["png"])
    }

    func testEmptyPasteboardGoesToField() {
        XCTAssertEqual(PasteIntake.decide(board, limits: limits), .field)
    }

    /// A 60 KB crash log, the paste the limits exist for. The attachment holds all of it.
    func testCrashLogOf60KBBecomesAttachmentWithFullText() throws {
        let log = (0..<1_800).map { "0x\(String($0, radix: 16)) frame \($0) in IronPet.crash()" }.joined(separator: "\n")
        XCTAssertGreaterThan(log.utf8.count, 58_000)
        board.setString(log, forType: .string)
        let saved = PasteIntake.importPaste(board, imageDirectory: dir, textDirectory: dir, limits: limits)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(saved.first), encoding: .utf8), log)
    }

    /// The limits are read from Settings on each paste, so a change applies to the next paste without a restart.
    func testChangedSettingsApplyToTheNextPaste() {
        let store = ConfigStore.shared
        let original = store.config
        defer { store.usePreview(original) }
        var config = original
        config.chat.pasteAttachmentChars = 500
        config.chat.pasteAttachmentLines = 2_000
        store.usePreview(config)
        let text = String(repeating: "a", count: 600)
        board.setString(text, forType: .string)
        XCTAssertEqual(PasteIntake.decide(board), .largeText(text))
        config.chat.pasteAttachmentChars = 100_000
        store.usePreview(config)
        XCTAssertEqual(PasteIntake.decide(board), .field)
        config.chat.pasteAttachmentLines = 10
        store.usePreview(config)
        let lines = (1...11).map(String.init).joined(separator: "\n")
        board.clearContents()
        board.setString(lines, forType: .string)
        XCTAssertEqual(PasteIntake.decide(board), .largeText(lines))
    }
}
