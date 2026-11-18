import AppKit
import XCTest
@testable import IronPet

@MainActor
final class DockIconTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A 1536x2704 sheet that is opaque red inside the given cells (row, column) and transparent elsewhere.
    private func sheet(filledCells: [(Int, Int)]) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1536, pixelsHigh: 2704, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        for (row, column) in filledCells {
            for y in (row * 208 + 20)..<(row * 208 + 188) {
                for x in (column * 192 + 20)..<(column * 192 + 172) {
                    rep.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y)
                }
            }
        }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func write(_ cells: [(Int, Int)], as name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try sheet(filledCells: cells).write(to: url)
        return url.path
    }

    private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return NSBitmapImageRep(cgImage: cg)
    }

    func testRendersTheIdleFrameOnASquareCanvasWithPadding() throws {
        let path = try write([(0, 0), (1, 0), (0, 1)], as: "pet.png")
        let image = try XCTUnwrap(DockIcon.image(forSprite: path))
        let rep = try bitmap(image)
        XCTAssertEqual(rep.pixelsWide, 1024)
        XCTAssertEqual(rep.pixelsHigh, 1024)
        var minX = 1024, maxX = 0, minY = 1024, maxY = 0
        for y in 0..<1024 {
            for x in 0..<1024 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThan(maxX, minX)
        XCTAssertGreaterThanOrEqual(minX, 102 - 2)
        XCTAssertLessThanOrEqual(maxX, 922 + 2)
        XCTAssertGreaterThanOrEqual(minY, 102 - 2)
        XCTAssertLessThanOrEqual(maxY, 922 + 2)
    }

    func testOnlyTheIdleFrameContributesPixels() throws {
        let other = try write([(1, 0), (0, 1), (3, 3)], as: "other.png")
        XCTAssertNil(DockIcon.image(forSprite: other), "a sheet with a blank idle frame has no icon")
        let idle = try write([(0, 0)], as: "idle.png")
        XCTAssertNotNil(DockIcon.image(forSprite: idle))
    }

    func testMissingOrInvalidSheetGivesNoIcon() throws {
        XCTAssertNil(DockIcon.image(forSprite: root.appendingPathComponent("missing.png").path))
        let bad = root.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: bad)
        XCTAssertNil(DockIcon.image(forSprite: bad.path))
    }

    func testControllerSetsTheIconOncePerChange() throws {
        let a = try write([(0, 0)], as: "a.png")
        let b = try write([(0, 0)], as: "b.png")
        var loads: [String?] = []
        var sets = 0
        var last: NSImage?
        let controller = DockIconController(load: { loads.append($0); return DockIcon.image(forSprite: $0) },
                                            set: { sets += 1; last = $0 })
        controller.update(sprite: a)
        controller.update(sprite: a)
        XCTAssertEqual(sets, 1)
        XCTAssertNotNil(last)
        controller.update(sprite: b)
        XCTAssertEqual(sets, 2)
        XCTAssertEqual(loads, [a, b])
        controller.update(sprite: root.appendingPathComponent("missing.png").path)
        XCTAssertEqual(sets, 3)
        XCTAssertNil(last, "an unreadable sheet restores the default icon")
    }

    func testEmptyAndNilSpriteShareOneKey() {
        var sets = 0
        let controller = DockIconController(load: { _ in nil }, set: { _ in sets += 1 })
        controller.update(sprite: nil)
        controller.update(sprite: "")
        XCTAssertEqual(sets, 1)
    }
}
