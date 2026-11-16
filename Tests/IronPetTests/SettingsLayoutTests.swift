import SwiftUI
import XCTest
@testable import IronPet

final class SettingsLayoutTests: XCTestCase {
    func testEveryPageHasATitleAndSymbol() {
        XCTAssertFalse(SettingsView.pages.isEmpty)
        for page in SettingsView.pages {
            XCTAssertFalse(page.title.isEmpty)
            XCTAssertFalse(page.symbol.isEmpty)
            XCTAssertEqual(SettingsView.page(page.tag)?.title, page.title)
        }
    }

    @MainActor func testHeaderIsAsTallAsTheTitleBar() {
        let host = NSHostingView(rootView: SettingsHeader(title: "Voice"))
        XCTAssertEqual(host.fittingSize.height, SettingsHeader.height)
    }

    @MainActor func testWindowHidesTitleAndExtendsContentUnderTitleBar() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        SettingsWindow.configure(window)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.styleMask.contains(NSWindow.StyleMask.fullSizeContentView))
        XCTAssertEqual(window.title, "Settings")
    }
}
