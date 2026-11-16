import AppKit
import XCTest
@testable import IronPet

final class ChatBackgroundTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makePNG(_ name: String) throws -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = dir.appendingPathComponent(name)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    func testDefaultIsPlain() {
        XCTAssertEqual(Config().chat.background, "default")
        XCTAssertNil(Config().chat.customImage)
    }

    func testChoiceSurvivesSaveAndLoad() throws {
        var config = Config()
        config.chat.background = "paws"
        let file = dir.appendingPathComponent("config.json")
        try config.save(to: file)
        XCTAssertEqual(Config.load(from: file).config.chat.background, "paws")
        try Config().save(to: file)
        XCTAssertEqual(Config.load(from: file).config.chat.background, "default")
    }

    func testUnknownBackgroundFallsBackToDefault() throws {
        let file = dir.appendingPathComponent("config.json")
        try #"{"chat": {"background": "nope"}}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(Config.load(from: file).config.chat.background, "default")
        try #"{"chat": {"background": "custom"}}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(Config.load(from: file).config.chat.background, "default", "custom without an image")
    }

    func testImportCopiesImageAndOriginalCanMove() throws {
        let original = try makePNG("photo.png")
        let store = dir.appendingPathComponent("backgrounds")
        let name = try ChatBackground.importImage(from: original, into: store)
        try FileManager.default.removeItem(at: original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent(name).path))
        let image = MainActor.assumeIsolated { ChatBackground.customImage(named: name, in: store) }
        XCTAssertNotNil(image)
    }

    func testImportReplacesPreviousImage() throws {
        let store = dir.appendingPathComponent("backgrounds")
        let first = try ChatBackground.importImage(from: try makePNG("a.png"), into: store)
        let second = try ChatBackground.importImage(from: try makePNG("b.png"), into: store, replacing: first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent(first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent(second).path))
    }

    func testImportRejectsNonImage() throws {
        let text = dir.appendingPathComponent("note.png")
        try "not an image".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ChatBackground.importImage(from: text, into: dir.appendingPathComponent("b")))
    }

    func testBuiltInsHaveUniqueIDsAndAPlainGradient() {
        XCTAssertEqual(Set(ChatBackground.builtIns.map(\.id)).count, ChatBackground.builtIns.count)
        XCTAssertTrue(ChatBackground.builtIns.contains { $0.doodles.isEmpty })
        XCTAssertGreaterThanOrEqual(ChatBackground.builtIns.count, 4)
    }
}
