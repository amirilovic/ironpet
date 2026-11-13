import XCTest
@testable import IronPet

final class FileIntakeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCopyKeepsNameAndContent() throws {
        let source = dir.appendingPathComponent("notes.md")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        let copy = try XCTUnwrap(FileIntake.copy(source, into: dir.appendingPathComponent("out")))
        XCTAssertEqual(copy.lastPathComponent, "notes.md")
        XCTAssertNotEqual(copy, source)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "hello")
    }

    func testFoldersAreNotAttached() {
        XCTAssertNil(FileIntake.copy(dir, into: dir.appendingPathComponent("out")))
    }

    func testPruneKeepsNewestFolders() throws {
        let out = dir.appendingPathComponent("out")
        for name in ["2026-01-01-a", "2026-01-02-b", "2026-01-03-c"] {
            try FileManager.default.createDirectory(at: out.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        FileIntake.prune(out, keep: 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        XCTAssertEqual(left, ["2026-01-02-b", "2026-01-03-c"])
    }
}
