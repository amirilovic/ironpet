import XCTest
@testable import IronPet

final class ScreenSectionTests: XCTestCase {
    func testTheSummarySaysHowManyCapturesAreStored() {
        XCTAssertEqual(ScreenSectionText.summary(captures: 0, lastCapture: nil), "Nothing captured yet.")
        XCTAssertEqual(ScreenSectionText.summary(captures: 1, lastCapture: nil), "1 capture stored")
        XCTAssertTrue(ScreenSectionText.summary(captures: 42, lastCapture: Date().addingTimeInterval(-120)).hasPrefix("42 captures stored, the last one"))
    }

    func testThePreviewKeepsTheFirstLines() {
        XCTAssertEqual(ScreenSectionText.preview("a\nb"), "a\nb")
        XCTAssertEqual(ScreenSectionText.preview("a\nb\nc\nd"), "a\nb …")
        XCTAssertEqual(ScreenSectionText.preview("a\nb\nc", lines: 1), "a …")
        XCTAssertEqual(ScreenSectionText.preview(""), "")
    }

    func testTheWindowLabelFallsBackToTheAddress() {
        let base = StoredCapture(id: 1, at: Date(), app: "a", appName: "A", window: "Title", url: "https://example.com", trigger: "idle", text: "")
        XCTAssertEqual(ScreenSectionText.windowLabel(base), "Title")
        var untitled = base
        untitled.window = ""
        XCTAssertEqual(ScreenSectionText.windowLabel(untitled), "https://example.com")
        untitled.url = nil
        XCTAssertEqual(ScreenSectionText.windowLabel(untitled), "Untitled window")
    }
}
