import ApplicationServices
import XCTest
@testable import IronPet

final class CaptureAXNotificationTests: XCTestCase {
    func testNotificationNamesAreTheSameInstancesOnEveryRead() {
        let first = AXCaptureSource.notifications.map { Unmanaged.passUnretained($0.name).toOpaque() }
        let second = AXCaptureSource.notifications.map { Unmanaged.passUnretained($0.name).toOpaque() }
        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(first).count, first.count)
    }

    func testNotificationNamesKeepTheirText() {
        let names = AXCaptureSource.notifications.map { $0.name as String }
        XCTAssertEqual(names.first, "AXFocusedUIElementChanged")
        XCTAssertTrue(names.contains("AXLiveRegionChanged"))
        XCTAssertEqual(Set(names).count, names.count)
    }
}
