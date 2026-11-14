import AppKit
import XCTest
@testable import IronPet

@MainActor
final class PetLibraryTests: XCTestCase {
    private var root: URL!
    private var bundled: URL!
    private var library: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        bundled = root.appendingPathComponent("bundled")
        library = root.appendingPathComponent("library")
        for dir in [bundled!, library!] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func png(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    @discardableResult
    private func writeSheet(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try png(width: 1536, height: 2704).write(to: url)
        return url
    }

    private func writeBundledSix() throws {
        for name in PetLibrary.builtInNames { try writeSheet("\(name).png", in: bundled) }
    }

    func testGalleryListsBundledPetsThenLibrarySheets() throws {
        try writeBundledSix()
        try writeSheet("red-fox.png", in: library)
        let entries = PetLibrary.entries(bundled: bundled, library: library, current: nil)
        XCTAssertEqual(entries.map(\.name), ["Ghost", "Mochi", "Hamster", "Panda", "Bunny", "Cat", "Red fox"])
    }

    func testLibrarySheetReplacesBundledPetOfTheSameName() throws {
        try writeBundledSix()
        let own = try writeSheet("panda.png", in: library)
        let entries = PetLibrary.entries(bundled: bundled, library: library, current: nil)
        XCTAssertEqual(entries.count, 6)
        XCTAssertEqual(entries.first { $0.name == "Panda" }?.id, PetLibrary.standardized(own.path))
    }

    func testInvalidSheetsAreSkipped() throws {
        try writeBundledSix()
        try png(width: 100, height: 100).write(to: library.appendingPathComponent("tiny.png"))
        try Data("not an image".utf8).write(to: library.appendingPathComponent("broken.png"))
        try Data("x".utf8).write(to: library.appendingPathComponent("notes.txt"))
        try writeSheet("good.png", in: library)
        let entries = PetLibrary.entries(bundled: bundled, library: library, current: nil)
        XCTAssertEqual(entries.map(\.name), ["Ghost", "Mochi", "Hamster", "Panda", "Bunny", "Cat", "Good"])
    }

    func testCurrentSpriteOutsideTheFoldersIsAdded() throws {
        try writeBundledSix()
        let elsewhere = try writeSheet("custom.png", in: root)
        let entries = PetLibrary.entries(bundled: bundled, library: library, current: elsewhere.path)
        XCTAssertEqual(entries.last?.name, "Custom")
        XCTAssertEqual(PetLibrary.selectedID(in: entries, sprite: elsewhere.path), entries.last?.id)
    }

    func testMissingFoldersGiveAnEmptyGallery() {
        XCTAssertTrue(PetLibrary.entries(bundled: nil, library: library.appendingPathComponent("none"), current: nil).isEmpty)
    }

    func testSelectionSetsSpriteAndFollowsADefaultName() throws {
        try writeBundledSix()
        let entries = PetLibrary.entries(bundled: bundled, library: library, current: nil)
        let panda = try XCTUnwrap(entries.first { $0.name == "Panda" })
        var config = Config()
        PetLibrary.select(panda, in: &config)
        XCTAssertEqual(config.pet.sprite, PetLibrary.tildePath(panda.url))
        XCTAssertEqual(config.pet.name, "Panda")
        XCTAssertEqual(PetLibrary.selectedID(in: entries, sprite: config.pet.sprite), panda.id)
        // The name still matches the previous pet, so it follows again.
        PetLibrary.select(try XCTUnwrap(entries.first { $0.name == "Cat" }), in: &config)
        XCTAssertEqual(config.pet.name, "Cat")
    }

    func testSelectionKeepsACustomName() throws {
        try writeBundledSix()
        let entries = PetLibrary.entries(bundled: bundled, library: library, current: nil)
        var config = Config()
        config.pet.name = "Biscuit"
        PetLibrary.select(try XCTUnwrap(entries.first { $0.name == "Panda" }), in: &config)
        XCTAssertEqual(config.pet.name, "Biscuit")
        XCTAssertNotNil(config.pet.sprite)
    }

    func testNoSpriteSelectsTheBundledGhost() throws {
        try writeBundledSix()
        let entries = PetLibrary.entries(bundled: bundled, library: library, current: nil)
        XCTAssertEqual(PetLibrary.selectedID(in: entries, sprite: nil), entries.first?.id)
    }

    func testFolderSignatureChangesWhenASheetAppears() throws {
        let before = PetFolderSignature(folder: library)
        XCTAssertEqual(before, PetFolderSignature(folder: library))
        try writeSheet("new.png", in: library)
        XCTAssertNotEqual(before, PetFolderSignature(folder: library))
    }

    func testGalleryReloadsWhenANewSheetIsWritten() async throws {
        try writeBundledSix()
        let gallery = PetGalleryModel(library: library, bundled: bundled, sprite: { nil })
        gallery.reload()
        try await waitFor { gallery.entries.count == 6 }
        try writeSheet("fox.png", in: library)
        gallery.reloadIfChanged()
        try await waitFor { gallery.entries.map(\.name).contains("Fox") }
    }

    func testAnimationRunsOnlyWhileTheViewAndWindowAreShown() throws {
        let gallery = PetGalleryModel(library: library, bundled: bundled, sprite: { nil })
        gallery.reduceMotionOverride = false
        gallery.setViewShown(true)
        XCTAssertFalse(gallery.isActive)
        gallery.setWindowShown(true)
        XCTAssertTrue(gallery.isActive)
        gallery.setWindowShown(false)
        XCTAssertFalse(gallery.isActive)
    }

    func testImportCopiesTheSheetUnderAFreshName() throws {
        let source = try writeSheet("mine.png", in: root)
        let first = try PetLibrary.importSheet(source, into: library)
        let second = try PetLibrary.importSheet(source, into: library)
        XCTAssertEqual(first.lastPathComponent, "mine.png")
        XCTAssertEqual(second.lastPathComponent, "mine-2.png")
        let bad = root.appendingPathComponent("bad.png")
        try png(width: 10, height: 10).write(to: bad)
        XCTAssertThrowsError(try PetLibrary.importSheet(bad, into: library))
    }

    // MARK: Preview

    private func atlas() throws -> Atlas {
        let data = try png(width: 1536, height: 2704)
        let image = try XCTUnwrap(NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return try XCTUnwrap(Atlas(image: image))
    }

    func testReduceMotionShowsOneStillFrame() throws {
        let atlas = try atlas()
        for time in [0.0, 0.5, 3.3, 10] {
            let position = PetPreview.position(in: atlas, at: time, reduceMotion: true)
            XCTAssertEqual(position.row, .idle)
            XCTAssertEqual(position.frame, 0)
        }
    }

    func testPreviewUsesThePetsFrameDurationsAndCyclesRows() throws {
        let atlas = try atlas()
        func at(_ t: Double) -> (Int, Int) {
            let p = PetPreview.position(in: atlas, at: t, reduceMotion: false)
            return (p.row.index, p.frame)
        }
        XCTAssertEqual(at(0.0).0, 0); XCTAssertEqual(at(0.0).1, 0)
        XCTAssertEqual(at(0.30).1, 1) // idle frame 0 lasts 0.28 s
        let idlePass = AtlasRow.idle.durations.reduce(0, +)
        XCTAssertEqual(at(2 * idlePass + 0.01).0, AtlasRow.waving.index)
        let waving = AtlasRow.waving.durations.reduce(0, +)
        XCTAssertEqual(at(2 * idlePass + waving + 0.01).0, AtlasRow.jumping.index)
        let jumping = AtlasRow.jumping.durations.reduce(0, +)
        XCTAssertEqual(at(2 * idlePass + waving + jumping + 0.01).0, AtlasRow.running.index)
        let total = 2 * idlePass + waving + jumping + 2 * AtlasRow.running.durations.reduce(0, +)
        XCTAssertEqual(at(total + 0.01).0, AtlasRow.idle.index) // wraps
        XCTAssertNotNil(PetPreview.frame(in: atlas, at: 0.4, reduceMotion: false))
    }

    // MARK: Prompt

    func testPromptCallsTheSkillByName() {
        XCTAssertEqual(PetPrompt.build(description: "  red fox with a scarf "), "/ironpet-pets red fox with a scarf")
    }

    func testTheBundledSkillIsNamedLikeThePrompt() {
        XCTAssertNotNil(BundledSkills.named(PetPrompt.skillName))
    }

    /// The skill text states the layout, so it must match the rows the app plays.
    func testSkillStatesTheAtlasLayout() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("skills/ironpet-pets/SKILL.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\nname: ironpet-pets\n"))
        XCTAssertTrue(text.contains("1536 x 2704"))
        XCTAssertTrue(text.contains("192 x 208"))
        let rows: [(String, AtlasRow)] = [("idle", .idle), ("run right", .runRight), ("run left", .runLeft), ("waving", .waving),
                                          ("jumping", .jumping), ("failed", .failed), ("waiting", .waiting), ("running", .running),
                                          ("review", .review), ("drinking", .drinking), ("stretching", .stretching)]
        for (name, row) in rows {
            XCTAssertTrue(text.contains("| \(row.index) | \(name)"), "row \(row.index) \(name)")
            XCTAssertTrue(text.range(of: "\\| \(row.index) \\| \(name)[^|]*\\| \(row.durations.count) \\|", options: .regularExpression) != nil,
                          "frames of \(name)")
        }
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out")
    }
}
