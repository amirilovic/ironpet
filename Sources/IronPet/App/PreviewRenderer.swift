import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `--render-previews <dir> [--sprite <sheet.png>]`: renders the main UI with made-up sample data to PNGs, plus an
/// animated `pet.gif` of Ghost reacting to an agent, for checking the design without clicking through it and for the
/// README (`scripts/screenshots.sh`).
/// Nothing here reads your sessions, alerts or chats.
@MainActor
enum PreviewRenderer {
    static func run(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--render-previews"), arguments.count > index + 1 else { return }
        let dir = URL(fileURLWithPath: arguments[index + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sprite = arguments.firstIndex(of: "--sprite").flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil }
        // Default settings (the pet is called Ghost), whatever is in your config.json.
        var config = Config()
        config.pet.sprite = sprite
        ConfigStore.shared.usePreview(config)
        let atlas = Atlas.loadDefault(sprite: sprite)
        let name = config.pet.name

        for (file, preview) in [("chat", ChatSession.Preview.done), ("chat-approval", .approval), ("chat-markdown", .markdown)] {
            let session = ChatSession(restore: false)
            session.loadPreview(preview)
            render(ChatView(session: session).frame(width: 520, height: 640).panel(), to: dir, file)
        }
        // A ~60 KB crash log pasted into the chat: over the paste limits, so the input shows an attachment chip.
        let pasted = ChatSession(restore: false)
        pasted.loadPreview(.done)
        let log = (0..<1_800).map { "0x\(String($0, radix: 16)) frame \($0) in IronPet.crash()" }.joined(separator: "\n")
        let pasteDir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preview-paste-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pasteDir) }
        pasted.attach(PasteIntake.importPaste(pasteboardHolding(log), imageDirectory: pasteDir, textDirectory: pasteDir))
        render(ChatView(session: pasted).frame(width: 520, height: 640).panel(), to: dir, "chat-pasted-text")
        let settings = ChatSession(restore: false)
        settings.loadPreview(.done)
        render(ChatView(session: settings, settingsOnly: true).panel(), to: dir, "chat-settings")

        let sessions = SessionStore()
        sessions.loadPreview(sampleSessions)
        let signals = SignalStore()
        sampleSignals.forEach { signals.add($0, notify: false) }
        let tasks = sampleTasks()
        let chat = ChatSession(restore: false)
        chat.loadPreview(.done)
        let meetings = MeetingLibrary(root: sampleMeetings())
        meetings.reload()
        func list(_ sessions: SessionStore, tasks: TaskStore, on section: IronPetSection? = nil) -> some View {
            let model = IronPetWindowModel(defaults: UserDefaults(suiteName: "ironpet-previews") ?? .standard)
            model.section = section ?? IronPetSection.needingAttention(store: sessions, signals: signals, tasks: tasks)
            return IronPetWindowView(model: model, store: sessions, signals: signals, tasks: tasks, chat: chat,
                                     meetings: meetings, actions: .none)
                .frame(width: 780, height: 560).panel()
        }
        render(list(sessions, tasks: tasks, on: .chat), to: dir, "window-chat")
        render(list(sessions, tasks: tasks, on: .transcripts), to: dir, "transcripts")
        // The same section mid-run: the row and the header show the stage, and Regenerate is disabled for the other meeting.
        meetings.regenerator.loadPreview(active: "2026-11-16-0930", .transcribing(chunk: 2, of: 5))
        render(list(sessions, tasks: tasks, on: .transcripts), to: dir, "transcripts-regenerating")
        meetings.regenerator.clearPreview()
        render(list(sessions, tasks: tasks), to: dir, "agents")
        // The window opens on Alerts when no agent needs you or is working.
        render(list(SessionStore(), tasks: tasks), to: dir, "alerts")
        render(list(sessions, tasks: tasks, on: .actions), to: dir, "actions")
        render(list(sessions, tasks: tasks, on: .tasks), to: dir, "tasks")
        render(list(sessions, tasks: tasks, on: .tasks), to: dir, "tasks-light", scheme: .light)
        let noTasks = TaskStore(database: Database.open(path: nil, migrations: TaskStore.migrations).database)
        render(list(sessions, tasks: noTasks, on: .tasks), to: dir, "tasks-empty")
        renderTaskRuns(sessions: sessions, signals: signals, chat: chat, atlas: atlas, to: dir)

        // Today, from the same sample stores plus a meeting on the last weekday and a few agent turns from today.
        let briefSource = BriefSource(tasks: tasks, sessions: sessions, signals: signals, meetingsRoot: sampleBriefMeetings(),
                                      activity: FixedBriefActivity(events: sampleActivity))
        let brief = BriefModel(source: briefSource)
        brief.weekdays = { AutomationDefaults.weekdays }
        brief.refresh()
        func today(_ kind: Brief.Kind, _ content: BriefModel) -> some View {
            let model = IronPetWindowModel(defaults: UserDefaults(suiteName: "ironpet-previews") ?? .standard)
            model.todayShown = true
            model.briefKind = kind
            model.section = .today
            return IronPetWindowView(model: model, store: sessions, signals: signals, tasks: tasks, chat: chat,
                                     meetings: meetings, brief: content, actions: .none)
                .frame(width: 780, height: 560).panel()
        }
        render(today(.brief, brief), to: dir, "today-brief")
        render(today(.brief, brief), to: dir, "today-brief-light", scheme: .light)
        render(today(.recap, brief), to: dir, "today-recap")
        render(today(.brief, BriefModel(briefs: [])), to: dir, "today-empty")

        renderUsage(to: dir)

        var patterned = config
        patterned.chat.background = "paws"
        // The same pages in a real window, so the screenshots show the title bar, selection and glass as they are.
        // Automations needs the app's settings model; this one is built from sample automations in a temp folder.
        let settingsModel = sampleSettings(chat: chat, config: patterned)
        ConfigStore.shared.usePreview(patterned)
        for section in IronPetSection.allCases {
            for (suffix, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
                for collapsed in [false, true] {
                    // A throwaway suite, so rendering never changes the user's saved sidebar state.
                    let model = IronPetWindowModel(defaults: UserDefaults(suiteName: "ironpet-previews") ?? .standard)
                    model.sidebarCollapsed = collapsed
                    model.todayShown = true
                    model.section = section
                    let view = IronPetWindowView(model: model, store: sessions, signals: signals, tasks: tasks, chat: chat,
                                                 meetings: meetings, settings: settingsModel, brief: brief, actions: .none)
                    renderWindow(model: model, session: chat, content: view, to: dir,
                                 "real-\(section.rawValue)-\(suffix)\(collapsed ? "-collapsed" : "")", scheme: scheme)
                    if collapsed, section == .agents {
                        // The rail label for Tasks, the fourth icon: 56 pt below the top, then 42 pt per icon.
                        model.hoverRail(RailTip(name: "Tasks", shortcut: "⌘4", frame: CGRect(x: 36, y: 182, width: 40, height: 38)),
                                        hovering: true)
                        renderWindow(model: model, session: chat, content: view, to: dir,
                                     "real-\(section.rawValue)-\(suffix)-collapsed-tip", scheme: scheme)
                        model.clearRailTip()
                    }
                }
            }
        }
        ConfigStore.shared.usePreview(config)

        let done = Bubble(id: "done", symbol: AgentStatus.done.symbol, tint: AgentStatus.done.tint, title: "demo-app: Done",
                          subtitle: "Claude Code", body: "Edited 3 files · Fixed the flaky login test.",
                          actions: [.init(title: "Open in iTerm", style: .primary) {}])
        let approval = Bubble(id: "approval", symbol: "hand.raised.fill", tint: .orange, title: "\(name) wants to: Run this command?",
                              body: "npm test -- login --runInBand",
                              actions: [.init(title: "Allow", style: .primary) {}, .init(title: "Deny", style: .destructive) {},
                                        .init(title: "Open chat") {}])
        let water = AutomationMigration.reminders[0]
        let reminder = Bubble(id: "reminder", symbol: water.symbol, tint: .cyan, title: water.title,
                              subtitle: "Your agent is still working, good moment for it.", body: water.body,
                              actions: [.init(title: "Done", style: .primary) {}, .init(title: "Snooze 10 min") {}])
        render(PetScene(atlas: atlas, row: .drinking, frame: 3, bubbles: [reminder]), to: dir, "reminder")
        let today = Calendar.current.startOfDay(for: Date())
        let due = [("Fix the flaky login test", today.addingTimeInterval(-86_400)), ("Send the deck to Maya", today),
                   ("Renew the domain before it lapses on Friday", Date().addingTimeInterval(-600))].map { title, date in
            TaskItem(id: title, title: title, notes: "", status: .backlog, source: .chat, due: date, links: [],
                     created: Date(), updated: Date(), closed: nil)
        }
        render(PetScene(atlas: atlas, row: .waiting, frame: 0,
                        bubbles: [Announcer.tasksDueBubble(Array(due.prefix(1)), now: Date(), done: {}, snooze: {}, open: {})]),
               to: dir, "task-due")
        render(PetScene(atlas: atlas, row: .waiting, frame: 0,
                        bubbles: [Announcer.tasksDueBubble(due, now: Date(), done: {}, snooze: {}, open: {})]),
               to: dir, "task-due-several")
        for (kind, automation) in [(Brief.Kind.brief, AutomationDefaults.morningBrief()), (.recap, AutomationDefaults.dayRecap())] {
            let bubble = Announcer.briefBubble(briefSource.build(kind, weekdays: AutomationDefaults.weekdays), automation: automation,
                                               now: Date(), open: {})
            render(PetScene(atlas: atlas, row: .waiting, frame: 0, bubbles: [bubble]), to: dir, "bubble-\(kind.rawValue)")
        }

        let left = Date().addingTimeInterval(-62 * 60)
        let window = DateInterval(start: left, end: Date())
        func event(_ kind: ActivityEvent.Kind, _ ref: String, _ title: String, detail: String = "", minutes: Double,
                   extra: [String: String] = [:]) -> ActivityEvent {
            ActivityEvent(at: left.addingTimeInterval(minutes * 60), kind: kind, ref: ref, title: title, detail: detail,
                          url: kind == .alertOpened ? URL(string: "https://github.com") : nil, extra: extra)
        }
        let away = [
            event(.sessionNeedsInput, "claude:1", "demo-app", minutes: 40),
            event(.alertOpened, "automation:gh:84", "Fix the login redirect", detail: "irtaza/ironpet #84", minutes: 22,
                  extra: ["label": "CI failed"]),
            event(.sessionDone, "codex:2", "api", minutes: 10),
            event(.sessionDone, "claude:3", "website", minutes: 30),
            event(.taskDue, "renew", "Renew the domain before it lapses on Friday", minutes: 1),
            event(.meetingSummary, "/m/summary.md", "2026-11-17 10-00 Standup", minutes: 50),
        ]
        func welcome(_ events: [ActivityEvent]) -> Bubble {
            Announcer.digestBubble(ActivityDigest.build(events: events, window: window), id: WelcomeBack.bubbleID,
                                   title: "Welcome back", subtitle: Announcer.awayText(window.duration), petName: "Ghost",
                                   open: { _ in }, showAll: {})
        }
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "" : "-light"
            render(PetScene(atlas: atlas, row: .waving, frame: 2, bubbles: [welcome(away)]), to: dir, "welcome-back\(suffix)", scheme: scheme)
            render(PetScene(atlas: atlas, row: .idle, frame: 0, bubbles: [welcome([away[2], away[3]])]),
                   to: dir, "welcome-back-single\(suffix)", scheme: scheme)
        }

        // Ghost works, finishes, asks before running a command, then takes a water break; then it loops.
        var shots: [(row: AtlasRow, frame: Int, bubbles: [Bubble], delay: Double)] = []
        func play(_ row: AtlasRow, loops: Int = 1, _ bubbles: [Bubble], holdLast: Double = 0) {
            for _ in 0..<loops {
                for (i, d) in row.durations.enumerated() { shots.append((row, i, bubbles, d)) }
            }
            if holdLast > 0, let last = shots.indices.last { shots[last].delay += holdLast }
        }
        play(.running, loops: 2, [])
        play(.jumping, [done])
        play(.review, loops: 2, [done])
        play(.waiting, loops: 4, [done, approval])
        play(.drinking, [reminder], holdLast: 1.2)
        let canvas = PetScene(atlas: atlas, row: .waiting, frame: 0, bubbles: [done, approval]).fittingSize
        let frames = shots.compactMap { shot in
            snapshot(PetScene(atlas: atlas, row: shot.row, frame: shot.frame, bubbles: shot.bubbles, canvas: canvas, solid: true),
                     wait: 0.02).flatMap { downscale($0, width: 640) }.map { ($0, shot.delay) }
        }
        writeGIF(frames, to: dir.appendingPathComponent("pet.gif"))
    }

    private static func pasteboardHolding(_ text: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("ironpet-preview-\(UUID().uuidString)"))
        board.clearContents()
        board.setString(text, forType: .string)
        return board
    }

    private static func render(_ view: some View, to dir: URL, _ name: String, scheme: ColorScheme = .dark) {
        guard let rep = snapshot(view, scheme: scheme) else { return }
        let file = dir.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        print("wrote \(file.path)")
    }

    /// The Usage tab with a week of made-up events: cost mode, requests mode and the hourly Today range.
    private static func renderUsage(to dir: URL) {
        guard let database = try? Database(path: nil, migrations: AppMigrations.all) else { return }
        let store = UsageStore(database: database)
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.startOfDay(for: now)
        let features: [(UsageFeature, String, Double)] = [(.chat, "claude-opus", 0.9), (.automations, "claude-sonnet", 0.2),
                                                            (.meetingSummary, "claude-sonnet", 0.35)]
        for back in 0..<7 {
            for (index, item) in features.enumerated() {
                guard let day = calendar.date(byAdding: .day, value: -back, to: start) else { continue }
                for turn in 0...(index + back % 3) {
                    let at = min(now, day.addingTimeInterval(Double(8 + index * 3 + turn) * 3600))
                    store.record(UsageEvent(at: at, feature: item.0, model: item.1, duration: 20, inputTokens: 4000, outputTokens: 600,
                                            cost: item.2 * Double(1 + (back + turn) % 3), currency: "USD"))
                }
            }
        }
        store.record(UsageEvent(at: now.addingTimeInterval(-60), feature: .voiceTranscription, model: "whisper-1", audioSeconds: 12))
        for (name, days, hourly, cost) in [("usage-cost", 7, false, true), ("usage-requests", 30, false, false), ("usage-today", 1, true, true)] {
            let summary = store.summary(days: days, hourly: hourly, now: now, calendar: calendar)
            render(UsageSettings(range: days, sample: summary, showCost: cost).frame(width: 560, height: 700).panel(),
                   to: dir, name)
        }
    }

    private static func sampleSettings(chat: ChatSession, config: Config) -> SettingsModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paths = AutomationPaths(file: folder.appendingPathComponent("automations.json"),
                                    directory: folder.appendingPathComponent("automations"))
        let store = AutomationStore(paths: paths, defaults: { AutomationMigration.defaults(from: config, sentryConfigured: false) },
                                    builtIns: AutomationDefaults.builtIns, watch: false)
        let telegram = TelegramBridge(
            client: TelegramAPI(token: { nil }), host: chat, tokens: TelegramToken.shared,
            storage: .init(users: { [] }, add: { _ in }, remove: { _ in }, offset: { 0 }, setOffset: { _ in }))
        let model = SettingsModel(actions: .init(suspendHotKeys: { _ in }, buildPet: { _ in }),
                                  announcer: Announcer(notifier: Notifier()), telegram: telegram)
        model.automations = AutomationService(store: store, engine: AutomationEngine(env: .init()))
        return model
    }

    /// Draws the ironpet window in a real `IronPetPanel` (traffic lights, sidebar selection and the blur of its
    /// materials) and captures that window from the window server. The offscreen `snapshot` cannot: a borderless
    /// window has no title bar, draws the sidebar selection black and does not blur materials.
    /// Falls back to nil when the window server gives no image (no display), and the caller skips the file.
    static func renderWindow(model: IronPetWindowModel, session: ChatSession?, content: some View, to dir: URL,
                             _ name: String, scheme: ColorScheme) {
        let panel = IronPetPanel(model: model, session: session, content: content)
        panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        panel.setContentSize(CGSize(width: 780, height: 560))
        panel.setFrameOrigin(CGPoint(x: 60, y: 60))
        // An inactive app draws the traffic lights grey.
        NSApp.setActivationPolicy(.regular)
        panel.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        panel.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        defer { panel.orderOut(nil) }
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else {
            print("no window image for \(name)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        let file = dir.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        print("wrote \(file.path)")
    }

    private static func snapshot(_ view: some View, wait: TimeInterval = 0.5, scheme: ColorScheme = .dark) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Retina snapshots make a GIF several times larger than it needs to be.
    private static func downscale(_ rep: NSBitmapImageRep, width: Int) -> CGImage? {
        guard let image = rep.cgImage else { return nil }
        let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private static func writeGIF(_ frames: [(CGImage, Double)], to file: URL) {
        guard let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (image, delay) in frames {
            CGImageDestinationAddImage(dest, image, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay,
            ]] as CFDictionary)
        }
        if CGImageDestinationFinalize(dest) { print("wrote \(file.path) (\(frames.count) frames)") }
    }

    private static var sampleSessions: [AgentSession] {
        func session(_ id: String, _ source: AgentSource, _ status: AgentStatus, _ project: String, prompt: String,
                     detail: String? = nil, edited: [String] = [], reply: String? = nil, minutes: Double,
                     iTerm: Bool = false) -> AgentSession {
            var s = AgentSession(id: id, source: source, status: status, prompt: prompt, detail: detail)
            s.origin = SessionOrigin(workspace: "/Users/you/code/\(project)", termProgram: iTerm ? "iTerm.app" : nil,
                                     itermSessionID: iTerm ? "w0t0p0" : nil)
            s.turnStartedAt = Date().addingTimeInterval(-minutes * 60)
            s.updatedAt = s.turnStartedAt
            s.editedFiles = edited
            s.lastResponse = reply
            return s
        }
        return [
            session("1", .claude, .needsInput, "api-server", prompt: "Add rate limiting to the public endpoints",
                    detail: "Run `npm install express-rate-limit`?", minutes: 3, iTerm: true),
            session("2", .cursor, .running, "web-app", prompt: "Make the settings page work on mobile",
                    detail: "Editing SettingsPage.tsx", minutes: 2),
            session("3", .claude, .done, "demo-app", prompt: "Why is the login test flaky?",
                    edited: ["a", "b", "c"], reply: "Fixed the flaky login test.", minutes: 6, iTerm: true),
            session("4", .cursor, .failed, "docs-site", prompt: "Upgrade to the new docs theme",
                    reply: "The build fails because the theme needs Node 20.", minutes: 11),
        ]
    }

    /// Agent turns that ended earlier today, as the activity log would list them.
    private static var sampleActivity: [BriefActivity] {
        func turn(_ ref: String, _ kind: BriefActivity.Kind, _ project: String, _ summary: String, minutes: Double) -> BriefActivity {
            BriefActivity(kind: kind, at: Date().addingTimeInterval(-minutes * 60), ref: ref, title: project, detail: summary,
                          agent: "Claude Code", workspace: "/Users/you/code/\(project)", bundleID: nil)
        }
        return [
            turn("claude:a", .sessionDone, "demo-app", "Fixed the flaky login test", minutes: 6),
            turn("claude:b", .sessionDone, "api-server", "Added rate limiting to the public endpoints", minutes: 45),
            turn("cursor:c", .sessionFailed, "docs-site", "The build needs Node 20", minutes: 11),
            BriefActivity(kind: .alertResolved, at: Date().addingTimeInterval(-30 * 60), ref: "5", title: "Fix flaky login test",
                          detail: "CI failed", agent: nil, workspace: nil, bundleID: nil),
        ]
    }

    /// A meeting on the last weekday with open action items, and one from this morning, for the Today previews.
    private static func sampleBriefMeetings() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preview-brief-meetings")
        try? FileManager.default.removeItem(at: root)
        let calendar = Calendar.current
        let since = BriefBuilder.meetingsSince(weekdays: AutomationDefaults.weekdays, now: Date(), calendar: calendar)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let meetings = [
            (since.addingTimeInterval(15 * 3600), """
             # Summary

             Planning for the 2.4 release.

             ## Action items
             - [ ] Send the design review notes to the team (owner: Me, due: Friday)
             - [ ] Book the room for the launch review (owner: Me)
             - [x] Share the load test results (owner: Me)
             - [ ] Update the pricing page (owner: Priya)
             """),
            (min(Date().addingTimeInterval(-90 * 60), calendar.startOfDay(for: Date()).addingTimeInterval(10 * 3600)), """
             # Summary

             Weekly sync with the platform team.

             ## Action items
             None.
             """),
        ]
        for (date, summary) in meetings {
            let url = root.appendingPathComponent(formatter.string(from: date))
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? summary.write(to: url.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        }
        return root
    }

    /// An in-memory list with one task in each state, created at made-up times.
    /// Two made-up meetings in a temporary folder, for the Transcripts section.
    private static func sampleMeetings() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preview-meetings")
        try? FileManager.default.removeItem(at: root)
        let meetings = [
            ("2026-11-16-0930", "# Summary\n\n- **Ship** the one-window layout on Friday; Settings stays its own window.\n",
             "**You:** Shall we keep Settings separate?\n\n**Them:** Yes, it matches what Mac apps do.\n"),
            ("2026-11-13-1400", "# Summary\n\n- Tasks get due dates next; reminders come from Automations.\n",
             "**You:** What is after tasks?\n\n**Them:** Due dates.\n"),
        ]
        for (folder, summary, transcript) in meetings {
            let url = root.appendingPathComponent(folder)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? summary.write(to: url.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
            try? transcript.write(to: url.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        }
        // One second of a made-up tone, so the newest meeting has audio and Regenerate is enabled; the other has none.
        if let first = meetings.first {
            let tone = (0..<WAV.sampleRate).map { Int16($0 / 20 % 2 == 0 ? 6000 : -6000) }
            try? WAV.encode(tone).write(to: root.appendingPathComponent(first.0).appendingPathComponent("mic-001.wav"))
        }
        return root
    }

    /// Tasks handed to agents: a row per run state, the same runs in Agents, the chat's approval strip, Start, and the
    /// bubble a finished run shows.
    private static func renderTaskRuns(sessions: SessionStore, signals: SignalStore, chat: ChatSession, atlas: Atlas?, to dir: URL) {
        let (tasks, runner) = sampleTaskRuns()
        func window(_ section: IronPetSection, store: SessionStore = sessions) -> some View {
            let model = IronPetWindowModel(defaults: UserDefaults(suiteName: "ironpet-previews") ?? .standard)
            model.section = section
            return IronPetWindowView(model: model, store: store, signals: signals, tasks: tasks, chat: chat, runs: runner, actions: .none)
                .frame(width: 780, height: 640).panel()
        }
        render(window(.tasks), to: dir, "tasks-runs")
        render(window(.tasks), to: dir, "tasks-runs-light", scheme: .light)
        render(window(.agents), to: dir, "agents-runs")
        // The offscreen snapshot cannot draw the chat, so the strip is captured in a real window.
        let chatModel = IronPetWindowModel(defaults: UserDefaults(suiteName: "ironpet-previews") ?? .standard)
        chatModel.section = .chat
        renderWindow(model: chatModel, session: chat, content: IronPetWindowView(model: chatModel, store: sessions, signals: signals,
                                                                                 tasks: tasks, chat: chat, runs: runner, actions: .none),
                     to: dir, "chat-task-approval", scheme: .dark)
        if let task = tasks.tasks.first(where: { runner.run(for: $0.id) == nil && $0.status == .backlog }) {
            render(TaskStartPopover(task: task, runner: runner, onDone: {}).panel(), to: dir, "task-run-start")
        }
        if let finished = runner.runs.values.first(where: { $0.state == .finished }) {
            let bubble = Announcer.taskRunEndedBubble(finished, task: tasks.task(finished.task)?.title ?? "", openTasks: {}, openPR: {})
            render(PetScene(atlas: atlas, row: .jumping, frame: 0, bubbles: [bubble]), to: dir, "task-run-finished")
        }
    }

    private static func sampleTaskRuns() -> (TaskStore, TaskRunner) {
        let tasks = TaskStore(database: Database.open(path: nil, migrations: TaskStore.migrations).database)
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preview-projects/web-app")
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        func add(_ title: String, _ status: TaskStatus, notes: String = "", links: [TaskLink] = []) -> String {
            (try? tasks.create(title: title, notes: notes, status: status, source: .chat, links: links, by: "agent:mcp").id) ?? title
        }
        let approval = add("Fix the flaky login test", .needsYou)
        let running = add("Add dark mode to the settings page", .inProgress)
        let finished = add("Bump the API client to v4", .needsYou)
        let failed = add("Speed up the CI cache", .needsYou)
        _ = add("Write the release notes for 2.4", .backlog, notes: "Cover the rate limiter and the new onboarding.",
                links: [TaskLink(kind: .file, ref: project.path, label: "web-app")])
        let started = Date().addingTimeInterval(-640)
        func run(_ task: String, _ state: TaskRun.State, agent: String = "claude") -> TaskRun {
            TaskRun(task: task, repo: URL(fileURLWithPath: "/Users/you/code/web-app"),
                    worktree: URL(fileURLWithPath: "/Users/you/.ironpet/worktrees/web-app-3f2a91c0/\(task)"), branch: "ironpet/\(task)",
                    base: "9c1e2d4", baseBranch: "main", agent: agent, model: nil, session: "s-\(task)", state: state,
                    started: started, ended: nil, summary: nil, error: nil)
        }
        var waiting = run(approval, .needsApproval)
        waiting.approval = .init(id: UUID(), title: "Run this command?", detail: "npm test -- login --runInBand")
        var working = run(running, .running, agent: "cursor")
        working.activity = "Editing src/settings/Theme.tsx"
        var done = run(finished, .finished)
        done.summary = "Updated the client to v4 and fixed the three call sites that used the old pagination."
        done.commits = 2
        var broken = run(failed, .failed, agent: "codex")
        broken.error = "Stopped after 120 minutes, the limit in taskRuns.maxMinutes."
        broken.commits = 1
        broken.dirty = true
        let runner = TaskRunner(tasks: tasks, store: TaskRunStore(database: Database.open(path: nil, migrations: TaskStore.migrations).database))
        runner.ironpetRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preview-root")
        // Room for one more, so the backlog row shows Start enabled.
        runner.config = { var settings = Config.TaskRuns(); settings.maxConcurrent = 3; return settings }
        runner.agents = { AgentCatalog.all.filter { ["claude", "cursor", "codex"].contains($0.id) } }
        runner.chatAgent = { AgentCatalog.agent(id: "claude").map { ($0, nil) } }
        runner.loadPreview([waiting, working, done, broken])
        return (tasks, runner)
    }

    private static func sampleTasks() -> TaskStore {
        var clock = Date()
        let store = TaskStore(database: Database.open(path: nil, migrations: TaskStore.migrations).database, now: { clock })
        let day: TimeInterval = 86_400
        func add(_ title: String, _ status: TaskStatus, _ source: TaskSource, ago: TimeInterval, due: Date? = nil,
                 notes: String = "", links: [TaskLink] = [], waitingOn: String? = nil) {
            clock = Date().addingTimeInterval(-ago)
            _ = try? store.create(title: title, notes: notes, status: status, source: source, due: due, links: links,
                                  waitingOn: waitingOn, by: "agent:mcp")
        }
        let today = Calendar.current.startOfDay(for: Date())
        add("Approve the staging deploy for the rate limiter", .needsYou, .agent, ago: 600,
            notes: "The canary has been green for an hour.",
            links: [TaskLink(kind: .url, ref: "https://github.com/you/api-server/pull/17", label: "PR #17")])
        add("Fix the flaky login test", .inProgress, .chat, ago: 1500, due: today.addingTimeInterval(-day),
            links: [TaskLink(kind: .session, ref: "3", label: nil), TaskLink(kind: .thread, ref: "t1", label: nil)])
        add("Make the settings page work on mobile", .inProgress, .telegram, ago: 3 * 3600,
            due: today.addingTimeInterval(2 * day + 17 * 3600))
        add("Write the release notes for 2.4", .backlog, .meeting, ago: day, due: today.addingTimeInterval(4 * day),
            links: [TaskLink(kind: .file, ref: "/Users/you/.ironpet/meetings/2026-11-15-1000", label: "Meeting")])
        add("Upgrade the docs site to Node 20", .backlog, .cli, ago: 2 * day)
        add("Send the updated pricing deck", .backlog, .meeting, ago: day + 1800, due: today.addingTimeInterval(3 * day),
            links: [TaskLink(kind: .file, ref: "/Users/you/.ironpet/meetings/2026-11-15-1000", label: "Meeting")], waitingOn: "Ana")
        add("Rotate the Sentry token", .done, .user, ago: 2 * 3600)
        add("Answer Maya about the onboarding copy", .done, .meeting, ago: day + 3600)
        add("Remove the old feature flags", .done, .agent, ago: 3 * day)
        clock = Date().addingTimeInterval(-900)
        store.suggest([("Send the design review notes to the team", "Friday", nil), ("Share the load test results", nil, "Priya")],
                      meeting: URL(fileURLWithPath: "/Users/you/.ironpet/meetings/2026-11-16-1500"))
        clock = Date().addingTimeInterval(-300)
        store.suggest([TaskSuggestion.Draft(key: "msg-1", title: "Reply to Sam about the Q4 budget", due: nil,
                                            url: URL(string: "https://mail.google.com/mail/u/0/#inbox/1"))],
                      automation: "gmail-watch", name: "Gmail watcher")
        clock = Date()
        return store
    }

    private static var sampleSignals: [Signal] {
        let url = URL(string: "https://github.com/you/web-app/pull/42")!
        return [
            Signal(id: "1", title: "Make the settings page responsive", subtitle: "you/web-app #42 · build", url: url,
                   date: Date().addingTimeInterval(-119.5), label: "CI failed", symbol: "xmark.octagon.fill", mood: .failed, ask: "Why is CI failing?"),
            Signal(id: "2", title: "Add rate limiting to public endpoints", subtitle: "you/api-server #17", url: url,
                   date: Date().addingTimeInterval(-899.5), label: "Review requested", symbol: "eye.fill", mood: .needsInput, ask: "Summarize this PR."),
            Signal(id: "3", title: "Fix flaky login test", subtitle: "you/demo-app #8", url: url,
                   date: Date().addingTimeInterval(-1799.5), label: "Approved", symbol: "hand.thumbsup.fill", mood: .done),
        ].reversed()
    }
}

private extension View {
    /// Rounded window look, since the real panels' blur and shadow don't render offscreen.
    func panel() -> some View {
        background { ChatBackdrop() }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 1))
            .padding(1)
    }
}

/// The pet with its speech bubbles on a plain backdrop, laid out the way they sit on screen.
private struct PetScene: View {
    let atlas: Atlas?
    let row: AtlasRow
    let frame: Int
    /// A fixed size keeps the pet in place while bubbles come and go (GIF frames).
    var canvas: CGSize?
    /// A flat backdrop; gradients band badly in a GIF's 256 colours.
    var solid = false
    private let store = BubbleStore()

    init(atlas: Atlas?, row: AtlasRow, frame: Int, bubbles: [Bubble], canvas: CGSize? = nil, solid: Bool = false) {
        self.atlas = atlas
        self.row = row
        self.frame = frame
        self.canvas = canvas
        self.solid = solid
        bubbles.forEach(store.show)
    }

    @MainActor var fittingSize: CGSize { NSHostingView(rootView: self.environment(\.colorScheme, .dark)).fittingSize }

    var body: some View {
        let size = CGSize(width: Atlas.cell.width * 0.9, height: Atlas.cell.height * 0.9)
        HStack(alignment: .bottom, spacing: -30) {
            BubbleStackView(store: store)
                .padding(.bottom, size.height * 0.62 - BubbleStackView.tailFromBottom)
            Group {
                if let image = atlas?.frame(row, frame) {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                } else {
                    Image(systemName: "pawprint.fill").resizable().scaledToFit().padding(40)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .padding(28)
        .frame(width: canvas?.width, height: canvas?.height, alignment: .bottomTrailing)
        .background {
            if solid {
                Color(red: 0.12, green: 0.14, blue: 0.21)
            } else {
                LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.3), Color(red: 0.09, green: 0.1, blue: 0.16)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}
