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
        XCTAssertEqual(IronPetSection.needingAttention(agents: AgentsAPI(store: sessions(.needsInput)), alerts: AlertsAPI(store: signals(2)), tasks: TasksAPI(store: list)), .agents)
        XCTAssertEqual(IronPetSection.needingAttention(agents: AgentsAPI(store: sessions(.failed)), alerts: AlertsAPI(store: signals(2)), tasks: TasksAPI(store: list)), .agents)
    }

    func testAlertsOpenWhenNoAgentIsWorking() {
        XCTAssertEqual(IronPetSection.needingAttention(agents: AgentsAPI(store: sessions(.done)), alerts: AlertsAPI(store: signals(1)), tasks: TasksAPI(store: tasks())), .alerts)
        XCTAssertEqual(IronPetSection.needingAttention(agents: AgentsAPI(store: sessions(.running)), alerts: AlertsAPI(store: signals(1)), tasks: TasksAPI(store: tasks())), .agents)
    }

    func testTasksOpenWhenOneNeedsYouAndNothingElseDoes() throws {
        let list = tasks()
        _ = try list.create(title: "Approve the deploy", status: .needsYou, source: .agent, by: "agent:mcp")
        XCTAssertEqual(IronPetSection.needingAttention(agents: AgentsAPI(store: sessions()), alerts: AlertsAPI(store: signals(0)), tasks: TasksAPI(store: list)), .tasks)
        XCTAssertEqual(IronPetSection.needingAttention(agents: AgentsAPI(store: sessions()), alerts: AlertsAPI(store: signals(0)), tasks: TasksAPI(store: tasks())), .agents)
    }

    func testTasksWaitingOnSomeoneElseDoNotOpenTasks() throws {
        let list = tasks()
        _ = try list.create(title: "Send the deck", source: .meeting, waitingOn: "Ana", by: "user")
        _ = try list.create(title: "Approve the budget", status: .needsYou, source: .agent, waitingOn: "Them", by: "agent:mcp")
        XCTAssertEqual(IronPetSection.needingAttention(agents: AgentsAPI(store: sessions()), alerts: AlertsAPI(store: signals(0)), tasks: TasksAPI(store: list)), .agents)
        XCTAssertEqual(list.activeCount, 0)

        list.suggest([("Share the results", nil, "Priya")], meeting: URL(fileURLWithPath: "/tmp/meeting"))
        XCTAssertEqual(IronPetSection.needingAttention(agents: AgentsAPI(store: sessions()), alerts: AlertsAPI(store: signals(0)), tasks: TasksAPI(store: list)), .tasks,
                       "a suggestion still waits on the user's Add or Skip")
    }

    func testBubblesWaitOnTheSectionsThatShowWhatTheyWouldAnnounce() {
        XCTAssertEqual(IronPetSection.allCases.filter(\.hidesBubbles), [.chat, .agents, .alerts, .tasks, .actions, .today])
    }

    func testCommandDigitsPickTheSidebarRowsInOrder() {
        let all = IronPetSection.shown(chat: true, transcripts: true, automations: true)
        XCTAssertEqual((1...8).map { IronPetSection.forShortcut("\($0)", in: all) },
                       [.chat, .agents, .alerts, .tasks, .transcripts, .screen, .actions, .automations])
        XCTAssertNil(IronPetSection.forShortcut("9", in: all))
        XCTAssertNil(IronPetSection.forShortcut("0", in: all))
        XCTAssertNil(IronPetSection.forShortcut("f", in: all))
        XCTAssertNil(IronPetSection.forShortcut(nil, in: all))
    }

    func testHiddenRowsDoNotTakeANumber() {
        let noChat = IronPetSection.shown(chat: false, transcripts: true, automations: true)
        XCTAssertEqual(IronPetSection.forShortcut("1", in: noChat), .agents)
        XCTAssertNil(IronPetSection.forShortcut("8", in: noChat))
    }

    private func keyEvent(_ characters: String, flags: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
    }

    func testCommandDigitsDoNothingWhileTheWindowIsNotKey() {
        let model = IronPetWindowModel()
        let panel = IronPetPanel(model: model, session: nil, content: EmptyView())
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.performKeyEquivalent(with: keyEvent("4")))
        XCTAssertEqual(model.section, .chat)
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

    // MARK: Background and title bar

    /// The preview renderer cannot show an active title bar, so the window chrome is checked here: the standard
    /// buttons exist, are visible and enabled, and the title bar is transparent with no title.
    func testTheWindowKeepsItsStandardButtonsOverTheSidebar() throws {
        let panel = panel()
        for style: NSWindow.StyleMask in [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] {
            XCTAssertTrue(panel.styleMask.contains(style), "missing \(style)")
        }
        XCTAssertTrue(panel.titlebarAppearsTransparent)
        XCTAssertEqual(panel.titleVisibility, .hidden)
        // AppKit re-lays the title bar on update; the buttons must survive that.
        panel.update()
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(panel.standardWindowButton(type), "no \(type) button")
            XCTAssertFalse(button.isHidden, "\(type) is hidden")
            XCTAssertTrue(button.isEnabled, "\(type) is disabled")
        }
    }

    func testMinimizingTellsTheWindowOwnerItIsHidden() {
        let panel = panel()
        var visibility: [Bool] = []
        panel.onVisibilityChange = { visibility.append($0) }
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: panel)
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: panel)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(visibility, [false, true])
    }

    func testTheCloseButtonHidesTheWindowLikeTheOldXDid() {
        let panel = panel()
        var closed = 0
        var visibility: [Bool] = []
        panel.onClose = { closed += 1 }
        panel.onVisibilityChange = { visibility.append($0) }
        panel.orderFront(nil)
        panel.performClose(nil)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(visibility, [false])
    }

    func testEscClosesAnIdleChat() {
        let h = ChatHarness(); let session = h.session
        let panel = IronPetPanel.chat(session)
        var closed = 0
        panel.onClose = { closed += 1 }
        panel.orderFront(nil)
        panel.cancelOperation(nil)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(closed, 1)
    }

    private func render(section: IronPetSection, background: String, scheme: ColorScheme) -> NSBitmapImageRep? {
        var config = ConfigStore.shared.config
        config.chat.background = background
        ConfigStore.shared.usePreview(config)
        let model = IronPetWindowModel(defaults: freshDefaults())
        model.section = section
        let store = SessionStore()
        let view = IronPetWindowView(model: model, agents: AgentsAPI(store: store), alerts: AlertsAPI(store: SignalStore()), tasks: TasksAPI(store: tasks()), chat: nil,
                                     meetings: nil, actions: .none)
        return bitmap(of: view, scheme: scheme)
    }

    /// Draws `view` at the window's minimum size under the given appearance, the way the preview renderer does.
    private func bitmap(of view: some View, scheme: ColorScheme) -> NSBitmapImageRep? {
        let sized = view
            .frame(width: IronPetPanel.minimumSize.width, height: IronPetPanel.minimumSize.height)
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: sized)
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Counts pixels in `region` (top-left origin) that differ between two renders.
    private func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in region: CGRect) -> Int {
        var count = 0
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent) > 0.004 {
                    count += 1
                }
            }
        }
        return count
    }

    func testEverySectionShowsTheChosenBackgroundInBothAppearances() throws {
        let saved = ConfigStore.shared.config
        defer { ConfigStore.shared.usePreview(saved) }
        let pagePixels = { (rep: NSBitmapImageRep) in
            // Right of the 156 pt sidebar, the page; pixels are at backing scale.
            let scale = CGFloat(rep.pixelsWide) / IronPetPanel.minimumSize.width
            return CGRect(x: 170 * scale, y: 0, width: CGFloat(rep.pixelsWide) - 170 * scale, height: CGFloat(rep.pixelsHigh))
        }
        for section in [IronPetSection.agents, .alerts, .tasks, .actions] {
            for scheme in [ColorScheme.light, .dark] {
                let plain = try XCTUnwrap(render(section: section, background: ChatBackground.defaultID, scheme: scheme))
                let patterned = try XCTUnwrap(render(section: section, background: "paws", scheme: scheme))
                XCTAssertGreaterThan(differing(plain, patterned, in: pagePixels(plain)), 1000,
                                     "\(section) \(scheme) does not show the chosen background")
            }
        }
    }

    func testNoBackgroundLeavesThePageOnTheWindowColor() throws {
        let saved = ConfigStore.shared.config
        defer { ConfigStore.shared.usePreview(saved) }
        let page = try XCTUnwrap(render(section: .alerts, background: ChatBackground.defaultID, scheme: .light))
        // What the window color draws in the same host. Comparing with a reference render, not a constant, keeps the
        // test independent of how the machine resolves windowBackgroundColor.
        let reference = try XCTUnwrap(bitmap(of: Color(nsColor: .windowBackgroundColor), scheme: .light))
        // The empty-state page has nothing in its lower right corner.
        let scale = CGFloat(page.pixelsWide) / IronPetPanel.minimumSize.width
        let (x, y) = (Int(700 * scale), Int(460 * scale))
        let corner = try XCTUnwrap(page.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        let expected = try XCTUnwrap(reference.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        XCTAssertEqual(corner.redComponent, expected.redComponent, accuracy: 0.01)
        XCTAssertEqual(corner.greenComponent, expected.greenComponent, accuracy: 0.01)
        XCTAssertEqual(corner.blueComponent, expected.blueComponent, accuracy: 0.01)
    }

    /// Captures a real window from the window server, which draws the sidebar's material over what is behind it.
    private func capture(background: String, scheme: NSAppearance.Name) throws -> NSBitmapImageRep {
        var config = ConfigStore.shared.config
        config.chat.background = background
        ConfigStore.shared.usePreview(config)
        let model = IronPetWindowModel(defaults: freshDefaults())
        model.section = .alerts
        let view = IronPetWindowView(model: model, agents: AgentsAPI(store: SessionStore()), alerts: AlertsAPI(store: SignalStore()), tasks: TasksAPI(store: tasks()), chat: nil,
                                     meetings: nil, actions: .none)
        let panel = IronPetPanel(model: model, session: nil, content: view)
        panel.appearance = NSAppearance(named: scheme)
        panel.setContentSize(CGSize(width: 780, height: 560))
        panel.setFrameOrigin(CGPoint(x: 60, y: 60))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else {
            throw XCTSkip("The window server gave no image of the window (no display).")
        }
        return NSBitmapImageRep(cgImage: image)
    }

    func testTheBackgroundShowsThroughTheGlassSidebar() throws {
        let saved = ConfigStore.shared.config
        defer { ConfigStore.shared.usePreview(saved) }
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            let plain = try capture(background: ChatBackground.defaultID, scheme: scheme)
            let patterned = try capture(background: "paws", scheme: scheme)
            // The blank lower part of the sidebar: x 10 to 180 pt, y 260 to 500 pt.
            let scale = CGFloat(plain.pixelsWide) / 780
            let region = CGRect(x: 10 * scale, y: 260 * scale, width: 170 * scale, height: 240 * scale)
            XCTAssertGreaterThan(differing(plain, patterned, in: region), Int(region.width * region.height) / 2,
                                 "the sidebar does not show the chosen background in \(scheme.rawValue)")
        }
    }

    func testTheBackgroundShowsThroughTheGlassHeader() throws {
        let saved = ConfigStore.shared.config
        defer { ConfigStore.shared.usePreview(saved) }
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            let plain = try capture(background: ChatBackground.defaultID, scheme: scheme)
            let patterned = try capture(background: "paws", scheme: scheme)
            // The blank middle of the Alerts header, between its title and "Clear all": x 300 to 650 pt, y 8 to 36 pt.
            let scale = CGFloat(plain.pixelsWide) / 780
            let region = CGRect(x: 300 * scale, y: 8 * scale, width: 350 * scale, height: 28 * scale)
            XCTAssertGreaterThan(differing(plain, patterned, in: region), Int(region.width * region.height) / 2,
                                 "the header does not show the chosen background in \(scheme.rawValue)")
        }
    }

    // MARK: Collapsible sidebar

    private func freshDefaults() -> UserDefaults {
        let name = "ironpet-sidebar-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testTheSidebarStartsExpandedAndRemembersCollapsing() {
        let defaults = freshDefaults()
        let model = IronPetWindowModel(defaults: defaults)
        XCTAssertFalse(model.sidebarCollapsed)
        model.toggleSidebar()
        XCTAssertTrue(model.sidebarCollapsed)
        // A new model, as after closing the app and starting it again, reads the saved state.
        XCTAssertTrue(IronPetWindowModel(defaults: defaults).sidebarCollapsed)
        model.toggleSidebar()
        XCTAssertFalse(IronPetWindowModel(defaults: defaults).sidebarCollapsed)
    }

    func testCollapsingSurvivesClosingAndReopeningTheWindow() {
        let defaults = freshDefaults()
        let model = IronPetWindowModel(defaults: defaults)
        let panel = IronPetPanel(model: model, session: nil, content: EmptyView())
        XCTAssertTrue(panel.runSidebarShortcut(flags: [.command, .control], characters: "s"))
        panel.orderFront(nil)
        panel.close()
        XCTAssertTrue(model.sidebarCollapsed)
    }

    func testControlCommandSTogglesAndCommandDigitsWorkInBothStates() {
        let model = IronPetWindowModel(defaults: freshDefaults())
        let panel = IronPetPanel(model: model, session: nil, content: EmptyView())
        for collapsed in [false, true] {
            XCTAssertEqual(model.sidebarCollapsed, collapsed)
            XCTAssertTrue(panel.runSidebarShortcut(flags: .command, characters: "3"))
            XCTAssertEqual(model.section, .tasks, "⌘3 does not pick the third row when collapsed == \(collapsed)")
            XCTAssertTrue(panel.runSidebarShortcut(flags: [.command, .control], characters: "s"))
        }
        XCTAssertFalse(model.sidebarCollapsed)
        XCTAssertFalse(panel.runSidebarShortcut(flags: .control, characters: "s"))
        XCTAssertFalse(panel.runSidebarShortcut(flags: .command, characters: "s"))
        XCTAssertFalse(model.sidebarCollapsed)
    }

    func testControlCommandSDoesNothingWhileTheWindowIsNotKey() {
        let model = IronPetWindowModel(defaults: freshDefaults())
        let panel = IronPetPanel(model: model, session: nil, content: EmptyView())
        XCTAssertFalse(panel.performKeyEquivalent(with: keyEvent("s", flags: [.command, .control])))
        XCTAssertFalse(model.sidebarCollapsed)
    }

    func testRailTooltipsNameTheSectionAndItsShortcut() {
        let all = IronPetSection.shown(chat: true, transcripts: true, automations: true)
        XCTAssertEqual(all.map { $0.hint(in: all) },
                       ["Chat (⌘1)", "Agents (⌘2)", "Alerts (⌘3)", "Tasks (⌘4)", "Transcripts (⌘5)", "Screen (⌘6)", "Actions (⌘7)", "Automations (⌘8)"])
        let noChat = IronPetSection.shown(chat: false, transcripts: true, automations: true)
        XCTAssertEqual(IronPetSection.agents.hint(in: noChat), "Agents (⌘1)")
    }

    private func renderCollapsed(_ collapsed: Bool, alerts: Int = 0, background: String = ChatBackground.defaultID,
                                 scheme: ColorScheme = .light) -> NSBitmapImageRep? {
        var config = ConfigStore.shared.config
        config.chat.background = background
        ConfigStore.shared.usePreview(config)
        let model = IronPetWindowModel(defaults: freshDefaults())
        model.sidebarCollapsed = collapsed
        model.section = .agents
        let view = IronPetWindowView(model: model, agents: AgentsAPI(store: sessions(.done)), alerts: AlertsAPI(store: signals(alerts)), tasks: TasksAPI(store: tasks()), chat: nil,
                                     meetings: nil, actions: .none)
        return bitmap(of: view, scheme: scheme)
    }

    func testTheRailIsNarrowAndTheBackgroundShowsThroughIt() throws {
        let saved = ConfigStore.shared.config
        defer { ConfigStore.shared.usePreview(saved) }
        for scheme in [ColorScheme.light, .dark] {
            let plain = try XCTUnwrap(renderCollapsed(true, background: ChatBackground.defaultID, scheme: scheme))
            let patterned = try XCTUnwrap(renderCollapsed(true, background: "paws", scheme: scheme))
            let scale = CGFloat(plain.pixelsWide) / IronPetPanel.minimumSize.width
            // The blank lower part of the rail, below the icons and above Settings.
            let rail = CGRect(x: 4 * scale, y: 340 * scale, width: 70 * scale, height: 100 * scale)
            XCTAssertGreaterThan(differing(plain, patterned, in: rail), Int(rail.width * rail.height) / 2,
                                 "the rail does not show the chosen background in \(scheme)")
            // Right of the 78 pt rail the page already shows the pattern, where the 156 pt sidebar would have covered it.
            let page = CGRect(x: 90 * scale, y: 340 * scale, width: 100 * scale, height: 100 * scale)
            XCTAssertGreaterThan(differing(plain, patterned, in: page), 1000)
        }
    }

    func testTheRailDrawsABadgeOnlyForSectionsWithACount() throws {
        let none = try XCTUnwrap(renderCollapsed(true, alerts: 0))
        let some = try XCTUnwrap(renderCollapsed(true, alerts: 3))
        let scale = CGFloat(none.pixelsWide) / IronPetPanel.minimumSize.width
        // Alerts is the third icon; the badge sits on its top right corner, inside the 78 pt rail.
        let corner = CGRect(x: 56 * scale, y: 0, width: 32 * scale, height: IronPetPanel.minimumSize.height * scale)
        XCTAssertGreaterThan(differing(none, some, in: corner), 20)
    }

    func testCollapsedAndExpandedSidebarsDrawDifferently() throws {
        let expanded = try XCTUnwrap(renderCollapsed(false))
        let rail = try XCTUnwrap(renderCollapsed(true))
        let scale = CGFloat(rail.pixelsWide) / IronPetPanel.minimumSize.width
        // Where the labels were: x 78 to 156 pt, now page.
        let labels = CGRect(x: 90 * scale, y: 60 * scale, width: 60 * scale, height: 200 * scale)
        XCTAssertGreaterThan(differing(expanded, rail, in: labels), 100)
    }

    // MARK: Section headers

    /// The frames of the header and of its title, in the host view's top-left coordinates, found from the frames the header reports.
    private func headerFrames(section: IronPetSection, collapsed: Bool) throws -> (header: CGRect, title: CGRect) {
        let model = IronPetWindowModel(defaults: freshDefaults())
        model.section = section
        model.sidebarCollapsed = collapsed
        let chat = ChatSession(restore: false)
        chat.loadPreview(.done)
        let meetings = MeetingLibrary(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var seen = PageHeaderFrames()
        let view = IronPetWindowView(model: model, agents: AgentsAPI(store: sessions(.done)), alerts: AlertsAPI(store: signals(1)), tasks: TasksAPI(store: tasks()), chat: ChatHarness(session: chat).model,
                                     meetings: MeetingsAPI(controller: MeetingController(), library: meetings), settings: nil, actions: .none)
            .onPreferenceChange(PageHeaderFrames.self) { seen = $0 }
            .frame(width: IronPetPanel.minimumSize.width, height: IronPetPanel.minimumSize.height)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return (try XCTUnwrap(seen.header, "\(section) has no header"), try XCTUnwrap(seen.title, "\(section) has no title"))
    }

    /// Automations is not listed: it needs the app's settings model, and it uses the same `pageHeader` as Tasks.
    func testEverySectionHasOneHeaderHeightWithTheTitleCenteredInIt() throws {
        for collapsed in [false, true] {
            for section in [IronPetSection.agents, .chat, .alerts, .tasks, .transcripts, .actions] {
                let (header, title) = try headerFrames(section: section, collapsed: collapsed)
                XCTAssertEqual(header.height, PageHeaderMetrics.height, accuracy: 0.5, "\(section) header height")
                XCTAssertEqual(header.minY, 0, accuracy: 0.5, "\(section) header starts at the window top")
                XCTAssertEqual(title.midY, PageHeaderMetrics.height / 2, accuracy: 1.5, "\(section) title is not centered")
                XCTAssertEqual(PageHeaderMetrics.height, 52)
            }
        }
    }

    /// The traffic lights sit in the middle of the header band, and the sidebar is wide enough to hold them.
    func testTheTrafficLightsAreCenteredInTheHeaderBandAndFitTheSidebar() throws {
        for collapsed in [false, true] {
            let model = IronPetWindowModel(defaults: freshDefaults())
            model.sidebarCollapsed = collapsed
            let panel = IronPetPanel(model: model, session: nil, content: Color.clear)
            panel.setContentSize(IronPetPanel.minimumSize)
            panel.centerWindowButtons()
            var rightmost: CGFloat = 0
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try XCTUnwrap(panel.standardWindowButton(kind))
                let frame = button.convert(button.bounds, to: nil)
                // Window coordinates run up from the bottom; the header runs down from the top.
                XCTAssertEqual(panel.frame.height - frame.midY, PageHeaderMetrics.height / 2, accuracy: 1, "\(kind) is not centered in the header")
                rightmost = max(rightmost, frame.maxX)
            }
            XCTAssertGreaterThan(IronPetWindowModel.minSidebarWidth, rightmost, "the traffic lights do not fit the sidebar")
            // The rail is the traffic lights' row plus a small margin on the right. The buttons end at x 69 on macOS 27
            // (a 9 pt margin) and at x 61 on the macOS version CI runs (17 pt), so the margin is a range, not one number.
            let margin = IronPetWindowModel.railWidth - rightmost
            XCTAssertGreaterThanOrEqual(margin, 6, "the rail clips the window buttons")
            XCTAssertLessThanOrEqual(margin, 20, "the rail is much wider than the window buttons")
        }
    }

    // MARK: Rail labels

    func testARailIconShowsItsLabelAfterTheDelayAndHidesOnExit() async throws {
        let saved = IronPetWindowModel.railTipDelay
        IronPetWindowModel.railTipDelay = .milliseconds(60)
        defer { IronPetWindowModel.railTipDelay = saved }
        let model = IronPetWindowModel(defaults: freshDefaults())
        let tip = RailTip(name: "Tasks", shortcut: "⌘4", frame: CGRect(x: 36, y: 182, width: 40, height: 38))
        model.hoverRail(tip, hovering: true)
        XCTAssertNil(model.railTip, "the label shows before the pointer has rested")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.railTip, tip)
        model.hoverRail(tip, hovering: false)
        XCTAssertNil(model.railTip)
    }

    func testLeavingBeforeTheDelayNeverShowsTheLabel() async throws {
        let saved = IronPetWindowModel.railTipDelay
        IronPetWindowModel.railTipDelay = .milliseconds(60)
        defer { IronPetWindowModel.railTipDelay = saved }
        let model = IronPetWindowModel(defaults: freshDefaults())
        let tip = RailTip(name: "Alerts", shortcut: "⌘3", frame: .zero)
        model.hoverRail(tip, hovering: true)
        model.hoverRail(tip, hovering: false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(model.railTip)
    }

    func testAClickOrExpandingTheSidebarHidesTheLabel() async throws {
        let saved = IronPetWindowModel.railTipDelay
        IronPetWindowModel.railTipDelay = .milliseconds(20)
        defer { IronPetWindowModel.railTipDelay = saved }
        let model = IronPetWindowModel(defaults: freshDefaults())
        model.sidebarCollapsed = true
        let tip = RailTip(name: "Tasks", shortcut: "⌘4", frame: .zero)
        model.hoverRail(tip, hovering: true)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNotNil(model.railTip)
        model.clearRailTip()
        XCTAssertNil(model.railTip)
        model.hoverRail(tip, hovering: true)
        try await Task.sleep(for: .milliseconds(120))
        model.toggleSidebar()
        XCTAssertNil(model.railTip)
    }

    func testTheRailLabelNamesTheSectionAndItsShortcut() {
        let sections = IronPetSection.shown(chat: true, transcripts: true, automations: true)
        XCTAssertEqual(IronPetSection.tasks.shortcutLabel(in: sections), "⌘4")
        XCTAssertEqual(IronPetSection.tasks.hint(in: sections), "Tasks (⌘4)")
    }

    // MARK: Dragging the sidebar edge

    func testDraggingTheEdgeFollowsThePointerBetweenTheRailAndTheMaximum() {
        XCTAssertEqual(IronPetWindowModel.dragWidth(start: 156, delta: 40), 196)
        XCTAssertEqual(IronPetWindowModel.dragWidth(start: 156, delta: -500), IronPetWindowModel.railWidth)
        XCTAssertEqual(IronPetWindowModel.dragWidth(start: 156, delta: 500), IronPetWindowModel.maxSidebarWidth)
    }

    func testTheSidebarSnapsToTheRailWhenDraggedNarrowAndBackWhenDraggedWide() {
        let model = IronPetWindowModel(defaults: freshDefaults())
        XCTAssertFalse(model.sidebarCollapsed)
        // Narrowed below the snap width, it collapses.
        model.endDrag(atWidth: IronPetWindowModel.snapWidth - 1)
        XCTAssertTrue(model.sidebarCollapsed)
        XCTAssertEqual(model.columnWidth, IronPetWindowModel.railWidth)
        // Dragged back past it, it expands, to the width it was let go at but never below the minimum.
        model.endDrag(atWidth: 200)
        XCTAssertFalse(model.sidebarCollapsed)
        XCTAssertEqual(model.sidebarWidth, 200)
        model.endDrag(atWidth: IronPetWindowModel.snapWidth + 1)
        XCTAssertFalse(model.sidebarCollapsed)
        XCTAssertEqual(model.sidebarWidth, IronPetWindowModel.minSidebarWidth)
        XCTAssertTrue(IronPetWindowModel.showsRail(atWidth: IronPetWindowModel.railWidth))
        XCTAssertFalse(IronPetWindowModel.showsRail(atWidth: IronPetWindowModel.minSidebarWidth))
    }

    func testTheDraggedWidthAndTheCollapsedStateSurviveARestart() {
        let defaults = freshDefaults()
        let first = IronPetWindowModel(defaults: defaults)
        first.endDrag(atWidth: 220)
        XCTAssertEqual(IronPetWindowModel(defaults: defaults).sidebarWidth, 220)
        first.endDrag(atWidth: 90)
        let second = IronPetWindowModel(defaults: defaults)
        XCTAssertTrue(second.sidebarCollapsed)
        XCTAssertEqual(second.sidebarWidth, 220, "collapsing forgot the expanded width")
    }

    func testThePressOnTheSidebarEdgeDoesNotMoveTheWindowAndReportsTheDrag() {
        let handle = SidebarResizeHandle.HandleView()
        XCTAssertFalse(handle.mouseDownCanMoveWindow)
        XCTAssertTrue(handle.acceptsFirstMouse(for: nil))
    }

    private func findHandle(in view: NSView) -> SidebarResizeHandle.HandleView? {
        if let handle = view as? SidebarResizeHandle.HandleView { return handle }
        for sub in view.subviews { if let found = findHandle(in: sub) { return found } }
        return nil
    }

    /// A drag that starts on the edge reaches the handle, in the real window, and collapses or expands the sidebar.
    func testDraggingTheEdgeInTheRealWindowCollapsesAndExpandsTheSidebar() throws {
        let model = IronPetWindowModel(defaults: freshDefaults())
        let view = IronPetWindowView(model: model, agents: AgentsAPI(store: sessions(.done)), alerts: AlertsAPI(store: signals(0)), tasks: TasksAPI(store: tasks()), chat: nil,
                                     meetings: nil, actions: .none)
        let panel = IronPetPanel(model: model, session: nil, content: view)
        panel.setContentSize(IronPetPanel.minimumSize)
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let content = try XCTUnwrap(panel.contentView)
        let handle = try XCTUnwrap(findHandle(in: content), "the sidebar edge has no drag handle")
        let center = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        XCTAssertEqual(center.x, model.columnWidth, accuracy: 3)
        // A press on the edge lands on the handle, not on the page or the sidebar.
        let hit = content.hitTest(content.convert(center, from: nil))
        XCTAssertTrue(hit === handle, "the edge is covered by \(String(describing: hit))")

        func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: center.y), modifierFlags: [], timestamp: 0,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Drag the edge left past the snap width: the sidebar collapses.
        handle.mouseDown(with: event(.leftMouseDown, x: center.x))
        handle.mouseDragged(with: event(.leftMouseDragged, x: 80))
        handle.mouseUp(with: event(.leftMouseUp, x: 80))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(model.sidebarCollapsed)
        // Then right past it: the sidebar expands again.
        let rail = IronPetWindowModel.railWidth
        handle.mouseDown(with: event(.leftMouseDown, x: rail))
        handle.mouseDragged(with: event(.leftMouseDragged, x: 200))
        handle.mouseUp(with: event(.leftMouseUp, x: 200))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(model.sidebarCollapsed)
        XCTAssertEqual(model.sidebarWidth, 200, accuracy: 1)
    }

    func testTheChatTitleHasNoCapsuleAndStartsWhereOtherTitlesStart() throws {
        let chat = try headerFrames(section: .chat, collapsed: false)
        let agents = try headerFrames(section: .agents, collapsed: false)
        // The avatar comes first at the 16 pt page margin, then the name; no padded pill pushes either inward.
        XCTAssertEqual(agents.title.minX - agents.header.minX, 16, accuracy: 0.5)
        XCTAssertGreaterThan(chat.title.minX - chat.header.minX, 16)
        XCTAssertLessThan(chat.title.minX - chat.header.minX, 16 + 22 + 8 + 1)
    }
}

@MainActor
final class WindowAutoHideTests: XCTestCase {
    private var enabled = false
    private var capturing = false

    private func open() -> (ChatHarness, IronPetPanel) {
        let h = ChatHarness()
        let panel = IronPetPanel.chat(h)
        panel.autoHideEnabled = { self.enabled }
        panel.isCapturing = { self.capturing }
        panel.setFrame(CGRect(x: 100, y: 100, width: 800, height: 600), display: false)
        panel.orderFront(nil)
        return (h, panel)
    }

    private func resign() { NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp) }
    private func activate() { NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp) }

    func testOffKeepsTheChatWindowOpenWhenAnotherAppTakesOver() {
        let (_, panel) = open()
        defer { panel.close() }
        resign()
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.autoHidden)
    }

    func testOnHidesAndBringsBackTheSameFrameAndDraft() {
        enabled = true
        let (h, panel) = open()
        defer { panel.close() }
        h.model.input = "half a thought"
        let frame = panel.frame
        resign()
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(panel.autoHidden)
        activate()
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.autoHidden)
        XCTAssertEqual(panel.frame, frame)
        XCTAssertEqual(h.model.input, "half a thought")
    }

    func testAWindowClosedByEscStaysClosed() {
        enabled = true
        let (_, panel) = open()
        panel.cancelOperation(nil)
        XCTAssertFalse(panel.isVisible)
        activate()
        XCTAssertFalse(panel.isVisible)
    }

    func testOwnSheetsDragsAndCapturesKeepItOpen() {
        enabled = true
        let (h, panel) = open()
        defer { panel.close() }
        h.model.fileDragActive = true
        resign()
        XCTAssertTrue(panel.isVisible)
        h.model.fileDragActive = false
        capturing = true
        resign()
        XCTAssertTrue(panel.isVisible)
        capturing = false
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        panel.beginSheet(sheet)
        defer { panel.endSheet(sheet) }
        resign()
        XCTAssertTrue(panel.isVisible)
    }

    func testDoesNotComeBackWhileCapturing() {
        enabled = true
        let (_, panel) = open()
        defer { panel.close() }
        resign()
        capturing = true
        activate()
        XCTAssertFalse(panel.isVisible)
        capturing = false
        activate()
        XCTAssertTrue(panel.isVisible)
    }

    /// Hiding only orders the window out. The session is not touched, so a turn keeps streaming into it and the
    /// reply is there on return.
    func testReplyArrivingWhileHiddenIsThereOnReturn() {
        enabled = true
        let (h, panel) = open()
        defer { panel.close() }
        resign()
        XCTAssertFalse(panel.isVisible)
        h.session.items.append(.init(kind: .assistant("done")))
        activate()
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(h.session.items.count, 1)
    }
}

extension WindowAutoHideTests {
    func testShortcutShowsAHiddenWindowAndABusyVoiceControllerBlocksTheHide() async throws {
        enabled = true
        let (h, panel) = open()
        defer { panel.close() }
        resign()
        XCTAssertFalse(panel.isVisible)
        // What the voice shortcut does: show the window (the app activates), then start.
        panel.show(near: CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertTrue(panel.isVisible)

        h.model.voice.isEnabled = { true }
        h.model.voice.start(.file(URL(fileURLWithPath: "/nonexistent.m4a")))
        XCTAssertTrue(h.model.voice.isBusy)
        resign()
        XCTAssertTrue(panel.isVisible, "recording or transcribing keeps the window")
        XCTAssertFalse(panel.autoHidden)
    }

    func testIdleVoiceDoesNotBlockTheHide() {
        enabled = true
        let (h, panel) = open()
        defer { panel.close() }
        XCTAssertFalse(h.model.voice.isBusy)
        resign()
        XCTAssertFalse(panel.isVisible)
    }
}
