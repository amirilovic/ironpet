import AppKit
import SwiftUI
import XCTest
@testable import IronPet

/// Cmd-F must move keyboard focus into the find field wherever focus was before.
@MainActor
final class ChatFindFocusTests: XCTestCase {
    private func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    private func open() -> (ChatSession, ChatPanel) {
        let session = ChatSession(restore: false)
        let panel = ChatPanel(session: session)
        panel.setContentSize(CGSize(width: 520, height: 640))
        panel.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in panel.close() }
        spin(1)
        return (session, panel)
    }

    /// Stands in for Cmd-F. `performKeyEquivalent` calls `revealFind` but needs the key window, and a test
    /// process cannot become the key window.
    private func press(_ chars: String, in panel: ChatPanel) { panel.revealFind() }

    private func findField(_ view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let f = view as? NSTextField, f.placeholderString == FindBar.placeholder { return f }
        for sub in view.subviews { if let f = findField(sub) { return f } }
        return nil
    }

    /// True when the window's first responder is the find field's editor.
    private func findHasFocus(_ panel: ChatPanel) -> Bool {
        guard let field = findField(panel.contentView), let editor = field.currentEditor() else { return false }
        return panel.firstResponder === editor
    }

    func testCmdFFromTheInputFocusesTheFindField() {
        let (session, panel) = open()
        panel.focusInput()
        spin(0.3)
        XCTAssertFalse(findHasFocus(panel))
        press("f", in: panel)
        spin(1)
        XCTAssertTrue(session.findOpen)
        XCTAssertTrue(findHasFocus(panel), "first responder: \(String(describing: panel.firstResponder))")
    }

    func testCmdFFromTheInputWithTextFocusesTheFindField() {
        let (session, panel) = open()
        session.input = "hello"
        panel.focusInput()
        spin(0.3)
        press("f", in: panel)
        spin(1)
        XCTAssertTrue(findHasFocus(panel), "first responder: \(String(describing: panel.firstResponder))")
    }

    func testSecondCmdFReturnsFromTheInputAndSelectsTheQuery() {
        let (_, panel) = open()
        press("f", in: panel)
        spin(1)
        findField(panel.contentView)?.stringValue = "abc"
        panel.focusInput()
        spin(0.3)
        XCTAssertFalse(findHasFocus(panel))
        press("f", in: panel)
        spin(1)
        XCTAssertTrue(findHasFocus(panel), "first responder: \(String(describing: panel.firstResponder))")
        XCTAssertEqual(findField(panel.contentView)?.currentEditor()?.selectedRange.length, 3)
    }

    func testEscClosesTheFindBarAndFocusesTheInput() {
        let (session, panel) = open()
        press("f", in: panel)
        spin(1)
        XCTAssertTrue(findHasFocus(panel))
        panel.cancelOperation(nil)
        spin(1)
        XCTAssertFalse(session.findOpen)
        let editor = panel.firstResponder as? NSTextView
        let owner = (editor?.delegate as? NSTextField)?.placeholderString ?? ""
        XCTAssertTrue(owner.hasPrefix("Ask"), "first responder: \(String(describing: panel.firstResponder))")
    }
}
