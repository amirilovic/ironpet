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

    func testTasksWaitingOnSomeoneElseDoNotOpenTasks() throws {
        let list = tasks()
        _ = try list.create(title: "Send the deck", source: .meeting, waitingOn: "Ana", by: "user")
        _ = try list.create(title: "Approve the budget", status: .needsYou, source: .agent, waitingOn: "Them", by: "agent:mcp")
        XCTAssertEqual(IronPetSection.needingAttention(store: sessions(), signals: signals(0), tasks: list), .agents)
        XCTAssertEqual(list.activeCount, 0)

        list.suggest([("Share the results", nil, "Priya")], meeting: URL(fileURLWithPath: "/tmp/meeting"))
        XCTAssertEqual(IronPetSection.needingAttention(store: sessions(), signals: signals(0), tasks: list), .tasks,
                       "a suggestion still waits on the user's Add or Skip")
    }

    func testBubblesWaitOnTheSectionsThatShowWhatTheyWouldAnnounce() {
        XCTAssertEqual(IronPetSection.allCases.filter(\.hidesBubbles), [.chat, .agents, .alerts, .tasks, .actions, .today])
    }

    func testCommandDigitsPickTheSidebarRowsInOrder() {
        let all = IronPetSection.shown(chat: true, transcripts: true, automations: true)
        XCTAssertEqual((1...7).map { IronPetSection.forShortcut("\($0)", in: all) },
                       [.chat, .agents, .alerts, .tasks, .transcripts, .actions, .automations])
        XCTAssertNil(IronPetSection.forShortcut("8", in: all))
        XCTAssertNil(IronPetSection.forShortcut("0", in: all))
        XCTAssertNil(IronPetSection.forShortcut("f", in: all))
        XCTAssertNil(IronPetSection.forShortcut(nil, in: all))
    }

    func testHiddenRowsDoNotTakeANumber() {
        let noChat = IronPetSection.shown(chat: false, transcripts: true, automations: true)
        XCTAssertEqual(IronPetSection.forShortcut("1", in: noChat), .agents)
        XCTAssertNil(IronPetSection.forShortcut("7", in: noChat))
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
        let session = ChatSession(restore: false)
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
        let view = IronPetWindowView(model: model, store: store, signals: SignalStore(), tasks: tasks(), chat: nil,
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
            // Right of the 190 pt sidebar, the page; pixels are at backing scale.
            let scale = CGFloat(rep.pixelsWide) / IronPetPanel.minimumSize.width
            return CGRect(x: 200 * scale, y: 0, width: CGFloat(rep.pixelsWide) - 200 * scale, height: CGFloat(rep.pixelsHigh))
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
        let view = IronPetWindowView(model: model, store: SessionStore(), signals: SignalStore(), tasks: tasks(), chat: nil,
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
                       ["Chat (⌘1)", "Agents (⌘2)", "Alerts (⌘3)", "Tasks (⌘4)", "Transcripts (⌘5)", "Actions (⌘6)", "Automations (⌘7)"])
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
        let view = IronPetWindowView(model: model, store: sessions(.done), signals: signals(alerts), tasks: tasks(), chat: nil,
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
            let rail = CGRect(x: 4 * scale, y: 340 * scale, width: 64 * scale, height: 100 * scale)
            XCTAssertGreaterThan(differing(plain, patterned, in: rail), Int(rail.width * rail.height) / 2,
                                 "the rail does not show the chosen background in \(scheme)")
            // Right of the 72 pt rail the page already shows the pattern, where the 190 pt sidebar would have covered it.
            let page = CGRect(x: 80 * scale, y: 340 * scale, width: 100 * scale, height: 100 * scale)
            XCTAssertGreaterThan(differing(plain, patterned, in: page), 1000)
        }
    }

    func testTheRailDrawsABadgeOnlyForSectionsWithACount() throws {
        let none = try XCTUnwrap(renderCollapsed(true, alerts: 0))
        let some = try XCTUnwrap(renderCollapsed(true, alerts: 3))
        let scale = CGFloat(none.pixelsWide) / IronPetPanel.minimumSize.width
        // Alerts is the third icon; the badge sits on its top right corner, inside the 72 pt rail.
        let corner = CGRect(x: 40 * scale, y: 0, width: 32 * scale, height: IronPetPanel.minimumSize.height * scale)
        XCTAssertGreaterThan(differing(none, some, in: corner), 20)
    }

    func testCollapsedAndExpandedSidebarsDrawDifferently() throws {
        let expanded = try XCTUnwrap(renderCollapsed(false))
        let rail = try XCTUnwrap(renderCollapsed(true))
        let scale = CGFloat(rail.pixelsWide) / IronPetPanel.minimumSize.width
        // Where the labels were: x 72 to 190 pt, now page.
        let labels = CGRect(x: 80 * scale, y: 40 * scale, width: 100 * scale, height: 200 * scale)
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
        let view = IronPetWindowView(model: model, store: sessions(.done), signals: signals(1), tasks: tasks(), chat: chat,
                                     meetings: meetings, settings: nil, actions: .none)
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
                // The traffic lights are centered about 15 pt below the top of the window.
                XCTAssertEqual(title.midY, 15, accuracy: 2, "\(section) title is not level with the traffic lights")
            }
        }
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
