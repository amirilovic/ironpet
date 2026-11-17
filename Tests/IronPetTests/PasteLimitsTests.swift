import XCTest
@testable import IronPet

final class PasteLimitsTests: XCTestCase {
    private let limits = PasteLimits(chars: 4_000, lines: 60)

    private func lines(_ n: Int) -> String { (1...n).map { _ in "x" }.joined(separator: "\n") }

    func testCharacterBoundary() {
        XCTAssertFalse(limits.exceeds(String(repeating: "a", count: 3_999)))
        XCTAssertFalse(limits.exceeds(String(repeating: "a", count: 4_000)))
        XCTAssertTrue(limits.exceeds(String(repeating: "a", count: 4_001)))
    }

    func testLineBoundary() {
        XCTAssertFalse(limits.exceeds(lines(59)))
        XCTAssertFalse(limits.exceeds(lines(60)))
        XCTAssertTrue(limits.exceeds(lines(61)))
    }

    func testEitherLimitIsEnough() {
        XCTAssertTrue(limits.exceeds(lines(61)), "short lines, too many of them")
        XCTAssertTrue(limits.exceeds(String(repeating: "a", count: 4_001)), "one long line")
    }

    func testCountsCharactersNotBytes() {
        XCTAssertFalse(limits.exceeds(String(repeating: "é", count: 4_000)))
        XCTAssertFalse(limits.exceeds(String(repeating: "😀", count: 4_000)))
        XCTAssertTrue(limits.exceeds(String(repeating: "😀", count: 4_001)))
    }

    func testTrailingNewlineDoesNotAddALine() {
        XCTAssertEqual(PasteLimits.lineCount(lines(60) + "\n"), 60)
        XCTAssertFalse(limits.exceeds(lines(60) + "\n"))
        XCTAssertTrue(limits.exceeds(lines(61) + "\n"))
    }

    func testLineCountHandlesWindowsAndEmptyText() {
        XCTAssertEqual(PasteLimits.lineCount(""), 1)
        XCTAssertEqual(PasteLimits.lineCount("a\r\nb\r\nc"), 3)
    }

    func testOtherLimitValues() {
        let strict = PasteLimits(chars: 500, lines: 10)
        XCTAssertFalse(strict.exceeds(String(repeating: "a", count: 500)))
        XCTAssertTrue(strict.exceeds(String(repeating: "a", count: 501)))
        XCTAssertFalse(strict.exceeds(lines(10)))
        XCTAssertTrue(strict.exceeds(lines(11)))
    }
}
