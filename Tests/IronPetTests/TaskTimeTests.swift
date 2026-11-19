import XCTest
@testable import IronPet

final class TaskTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNearFutureAndNowReadJustNow() {
        for offset in [0, 0.4, 30, 59.9, -0.4] as [TimeInterval] {
            XCTAssertEqual(TaskTime.relative(now.addingTimeInterval(offset), now: now), "just now", "offset \(offset)")
        }
    }

    func testPastKeepsRelativeWording() {
        let now = Date()
        let date = now.addingTimeInterval(-120)
        XCTAssertEqual(TaskTime.relative(date, now: now), date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
        XCTAssertNotEqual(TaskTime.relative(date, now: now), "just now")
    }

    func testFarFutureIsNotJustNow() {
        let now = Date()
        XCTAssertNotEqual(TaskTime.relative(now.addingTimeInterval(120), now: now), "just now")
    }
}
