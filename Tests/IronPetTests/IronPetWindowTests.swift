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

    func testBubblesWaitOnTheSectionsThatShowWhatTheyWouldAnnounce() {
        XCTAssertEqual(IronPetSection.allCases.filter(\.hidesBubbles), [.chat, .agents, .alerts, .tasks, .actions])
    }

    func testASizeSavedOnABiggerDisplayShrinksToTheScreen() {
        let small = CGRect(x: 0, y: 0, width: 1024, height: 640)
        XCTAssertEqual(IronPetPanel.fitted(CGSize(width: 1800, height: 1000), in: small), CGSize(width: 1008, height: 624))
        XCTAssertEqual(IronPetPanel.fitted(CGSize(width: 780, height: 560), in: small), CGSize(width: 780, height: 560))
        XCTAssertEqual(IronPetPanel.fitted(CGSize(width: 780, height: 560), in: CGRect(x: 0, y: 0, width: 600, height: 400)),
                       IronPetPanel.minimumSize)
    }

    private func panel() -> IronPetPanel {
        IronPetPanel(model: IronPetWindowModel(), session: nil, content: EmptyView())
    }

    func testOwnSheetsAndOtherWindowsKeepTheWindowOpen() {
        let panel = panel()
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        panel.beginSheet(sheet)
        defer { panel.endSheet(sheet) }
        let child = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.addChildWindow(child, ordered: .above)
        defer { panel.removeChildWindow(child) }
        let log = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)

        for newKey in [sheet, child, log, panel, nil] as [NSWindow?] {
            XCTAssertFalse(IronPetPanel.shouldClose(panel, onChat: false, appActive: true, newKey: newKey))
        }
    }

    func testAnotherAppClosesItExceptOnChat() {
        let panel = panel()
        XCTAssertTrue(IronPetPanel.shouldClose(panel, onChat: false, appActive: false, newKey: nil))
        XCTAssertTrue(IronPetPanel.shouldClose(panel, onChat: false, appActive: false, newKey: panel))
        XCTAssertFalse(IronPetPanel.shouldClose(panel, onChat: true, appActive: false, newKey: nil))
    }

    func testMeetingFoldersParseTheirDateAndSameMinuteSuffix() throws {
        let date = try XCTUnwrap(MeetingLibrary.date(folderName: "2026-11-16-0930"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 11, 16, 9, 30])
        XCTAssertEqual(MeetingLibrary.date(folderName: "2026-11-16-0930-2"), date)
        XCTAssertNil(MeetingLibrary.date(folderName: "2026-11-16-0930-copy"))
        XCTAssertNil(MeetingLibrary.date(folderName: "notes"))
    }

    func testTheMeetingPreviewSkipsHeadingsAndMarkdown() {
        XCTAssertEqual(MeetingLibrary.firstLine("# Summary\n\n---\n- **Ship** the window on Friday\n"), "Ship the window on Friday")
        XCTAssertNil(MeetingLibrary.firstLine("# Summary\n\n"))
    }

    func testTheLibraryListsMeetingFoldersNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["2026-11-15-1000", "2026-11-16-0930", "2026-11-16-0930-2", "not-a-meeting"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try "# Transcript\nHello there".write(to: root.appendingPathComponent("2026-11-15-1000/transcript.md"), atomically: true, encoding: .utf8)
        let library = MeetingLibrary(root: root)
        library.reload()
        XCTAssertEqual(library.meetings.map(\.id), ["2026-11-16-0930-2", "2026-11-16-0930", "2026-11-15-1000"])
        XCTAssertEqual(library.meetings.last?.preview, "Hello there")
        XCTAssertEqual(library.meetings.last?.hasTranscript, true)
        XCTAssertEqual(library.meetings.last?.hasSummary, false)
    }
}
