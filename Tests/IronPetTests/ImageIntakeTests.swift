import AppKit
import XCTest
@testable import IronPet

final class ImageIntakeTests: XCTestCase {
    private var dir: URL!
    private var board: NSPasteboard!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    }

    override func tearDownWithError() throws {
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: dir)
    }

    private func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testPlainTextPastesAsText() {
        board.clearContents()
        board.setString("hello", forType: .string)
        XCTAssertEqual(ImageIntake.decide(board), .text)
    }

    func testTextPlusImageStaysText() {
        board.clearContents()
        board.setString("hello", forType: .string)
        board.setData(png(width: 4, height: 4), forType: .png)
        XCTAssertEqual(ImageIntake.decide(board), .text)
    }

    func testImageDataOnly() {
        board.clearContents()
        board.setData(png(width: 4, height: 4), forType: .png)
        XCTAssertEqual(ImageIntake.decide(board), .data)
        let saved = ImageIntake.importPaste(board, into: dir)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].pathExtension, "png")
    }

    func testFinderImageFileBeatsItsName() throws {
        let file = dir.appendingPathComponent("a.png")
        try png(width: 4, height: 4).write(to: file)
        board.clearContents()
        board.writeObjects([file as NSURL])
        board.setString("a.png", forType: .string)
        XCTAssertEqual(ImageIntake.decide(board), .files([file]))
    }

    func testNonImageFileIsText() throws {
        let file = dir.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        board.clearContents()
        board.writeObjects([file as NSURL])
        XCTAssertEqual(ImageIntake.decide(board), .text)
    }

    func testFileCopyLeavesOriginalAndSavesPNG() throws {
        let file = dir.appendingPathComponent("a.png")
        let data = png(width: 4, height: 4)
        try data.write(to: file)
        let out = dir.appendingPathComponent("out")
        let saved = ImageIntake.save([file], into: out)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testLargeImageIsDownscaled() throws {
        let file = dir.appendingPathComponent("big.png")
        try png(width: 5000, height: 100).write(to: file)
        let saved = try XCTUnwrap(ImageIntake.save([file], into: dir.appendingPathComponent("out")).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: saved)))
        XCTAssertEqual(rep.pixelsWide, ImageIntake.maxSide)
    }

    func testPruneCoversPastedImages() throws {
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for i in 0..<35 {
            try Data().write(to: out.appendingPathComponent(String(format: "screen-2020-01-01T00-00-%02d.png", i)))
        }
        let file = dir.appendingPathComponent("a.png")
        try png(width: 4, height: 4).write(to: file)
        _ = ImageIntake.save([file], into: out)
        let count = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil).count
        XCTAssertEqual(count, ScreenCapture.keep)
    }
}
