import AppKit
import SwiftUI
import XCTest
@testable import IronPet

/// The message column and the composer stop growing at a maximum width and stay centered.
@MainActor
final class ChatColumnTests: XCTestCase {
    private struct FrameKey: PreferenceKey {
        static var defaultValue = CGRect.zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
    }

    /// Lays out a probe inside the same modifier the chat uses and returns where the probe ended up.
    private func probe(width: CGFloat, maxWidth: CGFloat, padding: CGFloat, includesPadding: Bool) -> CGRect {
        var result = CGRect.zero
        let view = Color.clear.frame(height: 20)
            .background(GeometryReader { g in Color.clear.preference(key: FrameKey.self, value: g.frame(in: .named("root"))) })
            .chatColumn(maxWidth: maxWidth, padding: padding, includesPadding: includesPadding)
            .frame(width: width, height: 100, alignment: .top)
            .coordinateSpace(name: "root")
            .onPreferenceChange(FrameKey.self) { result = $0 }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: width, height: 100)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return result
    }

    func testTheMessageColumnIsCappedAndCenteredInAWideWindow() {
        let wide = probe(width: 1200, maxWidth: ChatView.columnWidth, padding: 14, includesPadding: false)
        XCTAssertEqual(wide.width, 768, accuracy: 0.5)
        XCTAssertEqual(wide.midX, 600, accuracy: 0.5)
    }

    func testTheComposerIsCappedAndCenteredInAWideWindow() {
        let wide = probe(width: 1200, maxWidth: ChatView.composerWidth, padding: 12, includesPadding: true)
        XCTAssertEqual(wide.width, 840 - 24, accuracy: 0.5)
        XCTAssertEqual(wide.midX, 600, accuracy: 0.5)
    }

    func testBelowTheCapTheColumnFillsTheWidthAsBefore() {
        let narrow = probe(width: 360, maxWidth: ChatView.columnWidth, padding: 14, includesPadding: false)
        XCTAssertEqual(narrow.minX, 14, accuracy: 0.5)
        XCTAssertEqual(narrow.width, 360 - 28, accuracy: 0.5)
        let composer = probe(width: 360, maxWidth: ChatView.composerWidth, padding: 12, includesPadding: true)
        XCTAssertEqual(composer.minX, 12, accuracy: 0.5)
        XCTAssertEqual(composer.width, 360 - 24, accuracy: 0.5)
    }

    /// Where the section's content starts when it has the shared glass header, and how wide that content is.
    func testEverySectionHeaderIsOneGlassStripThatTheContentSitsBelow() {
        var result = CGRect.zero
        let view = Color.clear
            .background(GeometryReader { g in Color.clear.preference(key: FrameKey.self, value: g.frame(in: .named("root"))) })
            .pageHeader("Agents") { Text("1") }
            .frame(width: 600, height: 300)
            .coordinateSpace(name: "root")
            .onPreferenceChange(FrameKey.self) { result = $0 }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        // The content starts below the one shared header height; the strip spans the whole width.
        XCTAssertEqual(result.minY, PageHeaderMetrics.height, accuracy: 0.5)
        XCTAssertEqual(result.width, 600, accuracy: 0.5)
    }
}
