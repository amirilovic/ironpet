import AppKit
import SwiftUI
import XCTest
@testable import IronPet

@MainActor
final class IronPetWindowTests: XCTestCase {
    private func tasks() -> TaskStore {
        TaskStore(database: Database.open(path: nil, migrations: TaskStore.migrations).database)
    }

    private func sessions(_ statuses: AgentStatus...) -> SessionStore {
        let store = SessionStore()
        store.loadPreview(statuses.enumerated().map { AgentSession(id: "\($0.offset)", source: .claude, status: $0.element) })
        return store
    }

    private func signals(_ count: Int) -> SignalStore {
        let store = SignalStore()
        for i in 0..<count {
            store.add(Signal(id: "\(i)", title: "CI failed", subtitle: "", url: nil, date: Date(), label: "CI",
                             symbol: "xmark", mood: .failed), notify: false)
        }
        return store
    }

    func testAnAgentThatNeedsYouWinsOverAlertsAndTasks() throws {
        let list = tasks()
        _ = try list.create(title: "Approve the deploy", status: .needsYou, source: .agent, by: "agent:mcp")
        XCTAssertEqual(IronPetSection.needingAttention(store: sessions(.needsInput), signals: signals(2), tasks: list), .agents)
        XCTAssertEqual(IronPetSection.needingAttention(store: sessions(.failed), signals: signals(2), tasks: list), .agents)
    }

    func testAlertsOpenWhenNoAgentIsWorking() {
        XCTAssertEqual(IronPetSection.needingAttention(store: sessions(.done), signals: signals(1), tasks: tasks()), .alerts)
        XCTAssertEqual(IronPetSection.needingAttention(store: sessions(.running), signals: signals(1), tasks: tasks()), .agents)
    }

    func testTasksOpenWhenOneNeedsYouAndNothingElseDoes() throws {
        let list = tasks()
        _ = try list.create(title: "Approve the deploy", status: .needsYou, source: .agent, by: "agent:mcp")
        XCTAssertEqual(IronPetSection.needingAttention(store: sessions(), signals: signals(0), tasks: list), .tasks)
        XCTAssertEqual(IronPetSection.needingAttention(store: sessions(), signals: signals(0), tasks: tasks()), .agents)
    }

    func testTheSettingsSectionsKeepTheTagsTheTestEndpointTakes() {
        XCTAssertEqual(IronPetSection.settings.map(\.rawValue), ["general", "integrations", "voice", "meetings", "usage"])
        XCTAssertEqual(IronPetSection(rawValue: "automations"), .automations)
    }

    func testOwnSheetsAndOtherWindowsKeepTheWindowOpen() {
        let panel = IronPetPanel(content: EmptyView())
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        panel.beginSheet(sheet)
        defer { panel.endSheet(sheet) }
        let child = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.addChildWindow(child, ordered: .above)
        defer { panel.removeChildWindow(child) }
        let log = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)

        XCTAssertFalse(IronPetPanel.shouldClose(panel, appActive: true, newKey: sheet))
        XCTAssertFalse(IronPetPanel.shouldClose(panel, appActive: true, newKey: child))
        XCTAssertFalse(IronPetPanel.shouldClose(panel, appActive: true, newKey: log))
        XCTAssertFalse(IronPetPanel.shouldClose(panel, appActive: true, newKey: panel))
        XCTAssertFalse(IronPetPanel.shouldClose(panel, appActive: true, newKey: nil))
    }

    func testTheChatPanelOrAnotherAppClosesIt() {
        let panel = IronPetPanel(content: EmptyView())
        let chat = ChatPanel(session: ChatSession(restore: false))
        XCTAssertTrue(IronPetPanel.shouldClose(panel, appActive: true, newKey: chat))
        XCTAssertTrue(IronPetPanel.shouldClose(panel, appActive: false, newKey: nil))
        XCTAssertTrue(IronPetPanel.shouldClose(panel, appActive: false, newKey: panel))
    }
}
