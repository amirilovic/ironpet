import AppKit
import SwiftUI
import Carbon
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let signals = SignalStore()
    private let chat = ChatSession()
    private lazy var recordingKeys = RecordingKeys(voice: chat.voice, heldModifiers: {
        Shortcut(ConfigStore.shared.config.hotkeys.voice)?.modifiers ?? 0
    })
    private let notifier = Notifier()
    private let installer = HookInstaller()
    private var automations: AutomationService!
    private lazy var logWindow = AutomationLogWindow(service: { [weak self] in self?.automations })
    /// Moves the automation clock in test mode (`POST /test/automations/advance`). Zero otherwise.
    private var testClockOffset: TimeInterval = 0
    private lazy var announcer = Announcer(notifier: notifier)
    private var bubblePanel: BubblePanel!
    private var server: EventServer?
    private var pet: PetController!
    private var chatPanel: ChatPanel!
    private let meeting = MeetingController()
    private var meetingPanel: MeetingPanel!
    private var meetingBubbleHidden = false
    private lazy var callPrompt = CallPrompt(
        isEnabled: { ConfigStore.shared.config.meetings.enabled && ConfigStore.shared.config.meetings.offerToRecordCalls },
        isBusy: { [weak self] in self?.meeting.isBusy ?? true })
    private var callMonitor: CallMonitor?
    private var meetingBubbleRemoving = false
    private var hotKeys: [HotKey] = []
    private var previousApp: NSRunningApplication?
    private let wispr = WisprBridge()
    private var testControl: TestControl?
    private var timers: [Timer] = []
    private var cancellables: Set<AnyCancellable> = []
    private let config = ConfigStore.shared
    private var setupWindow: SetupWindow?
    private lazy var telegram = TelegramBridge(
        client: TelegramAPI(token: { TelegramToken.shared.load() }), host: chat, tokens: TelegramToken.shared,
        storage: .init(
            users: { ConfigStore.shared.config.telegram.allowedUsers },
            add: { user in ConfigStore.shared.update { $0.telegram.allowedUsers.append(user) } },
            remove: { id in ConfigStore.shared.update { $0.telegram.allowedUsers.removeAll { $0.id == id } } },
            offset: { UserDefaults.standard.integer(forKey: "telegramOffset") },
            setOffset: { UserDefaults.standard.set($0, forKey: "telegramOffset") }),
        petName: { ConfigStore.shared.config.pet.name })
    private lazy var settingsModel = SettingsModel(actions: .init(
        suspendHotKeys: { [weak self] suspended in suspended ? self?.unregisterHotKeys() : self?.registerHotKeys() },
        buildPet: { [weak self] description in self?.requestPet(description) }
    ), announcer: announcer, telegram: telegram)
    private lazy var settingsWindow = SettingsWindow(model: settingsModel)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        announcer.openSession = { [weak self] id in self?.openSession(id) }
        announcer.openChat = { [weak self] in self?.showChat() }
        announcer.ask = { [weak self] prompt in self?.ask(prompt) }
        announcer.decide = { [weak self] id, allow in self?.chat.decide(id: id, allow: allow) }
        announcer.automationAction = { [weak self] ids, snooze in self?.automations.notificationAction(ids: ids, snooze: snooze) }
        notifier.start()
        // Resolving the login-shell PATH runs the user's shell, so do it before the first chat needs it.
        Task.detached { _ = LoginShell.path }
        store.onAttention = { [weak self] session in
            self?.announcer.session(session)
            self?.testControl?.recordAttention(session)
        }

        signals.onNew = { [weak self] signal in
            self?.announcer.signal(signal)
            self?.testControl?.recordNotified(signal)
        }

        pet = PetController(store: store, signals: signals)
        pet.onAsk = { [weak self] prompt in self?.ask(prompt) }
        pet.onSay = { [weak self] text in self?.announcer.say(text) }
        bubblePanel = BubblePanel(store: announcer.bubbles)
        pet.extraMenuItems = { [weak self] in self?.hookMenuItems() ?? [] }
        pet.chatMood = { [weak self] in self?.chat.mood }
        pet.onChatToggle = { [weak self] in self?.toggleChat() }
        pet.onCapture = { [weak self] region in self?.captureScreen(region: region) }
        pet.show()

        chatPanel = ChatPanel(session: chat)
        wispr.onDictation = { [weak self] text in self?.chat.receiveDictation(text) }
        chatPanel.onClose = { [weak self] in
            self?.wispr.stop()
            self?.chat.isVisible = false
            self?.pet.refreshMood()
            self?.restorePreviousApp()
        }
        meetingPanel = MeetingPanel(controller: meeting)
        meeting.onChange = { [weak self] in self?.syncMeetingPanel() }
        announcer.bubbles.onDismissed = { [weak self] id in self?.meetingBubbleClosed(id) }
        pet.onRecordingClick = { [weak self] in self?.showMeetingBubble() }
        meeting.onSummaryReady = { [weak self] url in
            self?.announcer.meetingSummary(url)
            self?.testControl?.recordMeetingNotified(url)
        }
        meeting.onOpenInChat = { [weak self] files in self?.openMeetingInChat(files) }
        if TestControl.isEnabled {
            // No dialog may block an automated run.
            meeting.confirmConsent = { true }
        }
        startCallMonitor()
        chat.onAttention = { [weak self] title in self?.announcer.chat(title) }
        telegram.onPairingRequest = { [weak self] request in
            self?.announcer.telegramPairing(request, allow: { self?.telegram.allow(request.id) },
                                            deny: { self?.telegram.deny(request.id) })
        }
        telegram.onPairingResolved = { [weak self] id in self?.announcer.clearTelegramPairing(id: id) }
        if config.config.telegram.enabled { telegram.setEnabled(true) }
        chat.onApprovalNeeded = { [weak self] approval in
            self?.announcer.approval(id: approval.id, title: approval.title, detail: approval.detail)
        }
        chat.onApprovalResolved = { [weak self] id in self?.announcer.clearApproval(id: id) }
        chat.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pet.refreshMood() }
            .store(in: &cancellables)
        registerHotKeys()
        _ = recordingKeys // Starts following the recording phase.
        config.$config
            .removeDuplicates()
            .scan((Config(), config.config)) { ($0.1, $1) }
            .dropFirst()
            .sink { [weak self] old, new in self?.apply(config: new, previous: old) }
            .store(in: &cancellables)

        setUpAutomations()
        do {
            try startServer()
        } catch {
            showError("ironpet could not start the agent watcher", error)
        }
        if SetupWindow.isNeeded {
            showSetup()
        } else {
            // Refresh the chosen hooks so they match this version of the app.
            setHooks(installed: hookAgents(in: config.config), quietly: true)
        }

        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pet.tick()
                self.bubblePanel.follow(self.pet.panel.frame)
                self.bubblePanel.isSuppressed = self.chatPanel.isVisible || self.pet.isAgentsVisible
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.sweep() }
        })

    }

    /// Builds the automation service: the file, the clock and the places an automation can show or run something.
    private func setUpAutomations() {
        let store = AutomationStore(defaults: { [config] in
            AutomationMigration.defaults(from: config.config, sentryConfigured: AutomationDefaults.sentryConfigured)
        })
        let engine = AutomationEngine(env: .init(
            now: { [weak self] in Date().addingTimeInterval(self?.testClockOffset ?? 0) },
            isAgentWorking: { [weak self] in
                guard let self else { return false }
                return self.chat.state == .running || self.store.sessions.values.contains { $0.status == .running }
            },
            isBusy: { [weak self] in
                guard let self else { return false }
                return self.chat.isVisible || !self.chat.approvals.isEmpty || self.store.summary.status == .needsInput
            }))
        engine.timing = { [config] in
            let r = config.config.reminders
            return .init(paused: r.paused, idleResetMinutes: r.idleResetMinutes, snoozeMinutes: r.snoozeMinutes)
        }
        // The app's one database. Features add their migrations to this list, in version order.
        let database = Database.open(path: Paths.root.appendingPathComponent("ironpet.db"), migrations: AppMigrations.all).database
        UsageStore.shared = UsageStore(database: database)
        let service = AutomationService(store: store, engine: engine, database: database)
        service.notice = { [weak self] notice in self?.announcer.automation(notice) }
        service.dismissNotice = { [weak self] id in self?.announcer.bubbles.dismiss(id) }
        service.alert = { [weak self] signal, notify in self?.signals.add(signal, notify: notify) }
        service.resolveAlert = { [weak self] id in self?.signals.dismiss(id) }
        // Alerts the user has not dismissed come back after a restart, quietly. Dismissing one clears its stored payload.
        signals.restore(service.engine.state.openAlerts())
        signals.onDismiss = { [state = service.engine.state] id in state.closeAlert(signalID: id) }
        service.nudge = { [weak self] moods in self?.pet.nudge(moods, each: moods == [.done] ? 3 : 4) }
        let workspace = store.paths.workspace
        service.runPrompt = { automation, prompt in await AutomationPrompt.run(automation, prompt: prompt, workspace: workspace) }
        automations = service
        settingsModel.automations = service
        settingsModel.showLogs = { [weak self] id in self?.logWindow.show(automation: id) }
        service.logRetentionDays = { [config] in config.config.automations.logRetentionDays }
        service.autoFixEnabled = { [config] in config.config.automations.autoFix }
        service.autoApproveEnabled = { [config] in config.config.automations.autoApprove }
        service.requestFix = { [weak self] automation, trigger, error in
            self?.sendToChat(AutomationAgentPrompts.fix(automation, trigger: trigger, error: error), show: false,
                             title: "\(automation.name) failed", busyBody: "Ask \(self?.chat.agent.name ?? "the agent") to fix it?")
        }
        settingsModel.createWithAgent = { [weak self] request in
            self?.sendToChat(AutomationAgentPrompts.newAutomation(request), show: true, title: "New automation", busyBody: "Send it to the chat?")
        }
        service.start()
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.automations.engine.tick() }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.automations.engine.tick() }
        // Update installed skills, and offer the others once the first-run window is out of the way.
        if !TestControl.isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkSkills() }
        }
    }

    /// With the switch on, installs and updates the skills for the agents found on this Mac and says so in one bubble. With it off, offers instead.
    private func checkSkills() {
        let manager = SkillManager.standard
        if config.config.skills.autoUpdate { manager.updateInstalled() }
        NotificationCenter.default.post(name: .skillsChanged, object: nil)
        guard setupWindow == nil else { return }
        let pending = SkillPrompt.pending(manager.entries(), dismissed: SkillPrompt.dismissed())
        guard !pending.isEmpty else { return }
        // The switch in Settings → Skills also covers skills that are not installed yet, for the agents found on this Mac.
        if config.config.skills.autoUpdate {
            installSkills(pending)
            return
        }
        let message = SkillPrompt.message(pending)
        announcer.automation(AutomationNotice(
            id: "skill-install", symbol: "sparkles", tint: .info, title: message.title, body: message.body,
            buttons: [.init(title: message.button, primary: true) { [weak self] in self?.installSkills(pending) },
                      .init(title: "Not now") { SkillPrompt.dismiss(pending) }]))
    }

    private func installSkills(_ pending: [SkillManager.Entry]) {
        defer { NotificationCenter.default.post(name: .skillsChanged, object: nil) }
        do {
            let results = try SkillManager.standard.install(names: pending.map(\.skill.name))
            let outcomes = results.flatMap { $0.outcomes }
            let problems = outcomes.filter { $0.result == "failed" || $0.result == "skipped" }
            let linked = outcomes.filter { $0.result == "linked" || $0.result == "copied" }
            let agents = Set(linked.map { $0.agent.name }).sorted()
            var body = "Installed in ~/.agents/skills."
            if !problems.isEmpty { body = SkillInstaller.describe(problems) }
            else if !agents.isEmpty { body = "Installed for " + agents.joined(separator: ", ") + "." }
            announcer.automation(AutomationNotice(
                id: "skill-install", symbol: problems.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                tint: problems.isEmpty ? .good : .warn, title: problems.isEmpty ? "Skills installed" : "Skills installed with problems",
                body: body, expires: 15))
        } catch {
            announcer.automation(AutomationNotice(id: "skill-install", symbol: "exclamationmark.triangle.fill", tint: .bad,
                                                  title: "Could not install the skills", body: error.localizedDescription, expires: 20))
        }
    }

    /// The tools Ghost's chat agents get: ironpet's automations, over a stdio bridge to the loopback server.
    private func registerMCPServer() {
        guard let executable = Bundle.main.executablePath else { return }
        var env: [JSON] = []
        if Paths.isIsolated { env.append(["name": "IRONPET_ROOT", "value": Paths.root.path]) }
        let entry: JSON = ["name": "ironpet", "command": executable, "args": ["mcp"], "env": env]
        ACPBackend.defaultMCPServers = { [entry] }
    }

    /// Applies settings that need more than being read at the point of use.
    private func apply(config new: Config, previous old: Config) {
        let (newAgents, oldAgents) = (hookAgents(in: new), hookAgents(in: old))
        setHooks(installed: newAgents.filter { !oldAgents.contains($0) })
        setHooks(removed: oldAgents.filter { !newAgents.contains($0) })
        if new.hotkeys != old.hotkeys || new.voice.enabled != old.voice.enabled
            || new.meetings.enabled != old.meetings.enabled { registerHotKeys() }
        if new.telegram.enabled != old.telegram.enabled { telegram.setEnabled(new.telegram.enabled) }
        if !new.voice.enabled { chat.voice.cancel() }
        if !new.meetings.enabled { meeting.dismiss() }
        startCallMonitor()
        if new.pet.sprite != old.pet.sprite { pet.reloadAtlas() }
    }

    private func registerHotKeys() {
        hotKeys = [] // Unregister first: the same combination can't be registered twice.
        let hotkeys = config.config.hotkeys
        let bindings: [(String, UInt32, () -> Void)] = [
            (hotkeys.chat, 1, { [weak self] in self?.toggleChat() }),
            (hotkeys.captureWindow, 2, { [weak self] in self?.captureScreen(region: false) }),
            (hotkeys.captureRegion, 3, { [weak self] in self?.captureScreen(region: true) }),
        ]
        var failed: Set<String> = []
        for (text, id, action) in bindings where !text.isEmpty {
            guard let shortcut = Shortcut(text) else {
                failed.insert(text)
                continue
            }
            let hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: id) {
                MainActor.assumeIsolated { action() }
            }
            if hotKey.isRegistered { hotKeys.append(hotKey) } else { failed.insert(text) }
        }
        // Voice shortcut (hold to talk or press to toggle). Only registered with voice notes on, so a disabled feature owns no key.
        if let text = VoiceController.hotkey(in: config.config), let shortcut = Shortcut(text) {
            // The mode is read on every press, so flipping the switch in Settings applies to the next one.
            let hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: 4, onRelease: { [weak self] in
                MainActor.assumeIsolated {
                    self?.chat.voice.shortcutReleased(holdToTalk: ConfigStore.shared.config.voice.holdToTalk)
                }
            }, handler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.showChat()
                    self.chat.voice.shortcutPressed()
                }
            })
            if hotKey.isRegistered { hotKeys.append(hotKey) } else { failed.insert(text) }
        } else if config.config.voice.enabled, !config.config.hotkeys.voice.isEmpty {
            failed.insert(config.config.hotkeys.voice)
        }
        // Start or stop a meeting transcript. Only registered with meetings on, and unbound by default.
        if let text = MeetingController.hotkey(in: config.config) {
            if let shortcut = Shortcut(text) {
                let hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: 5) { [weak self] in
                    MainActor.assumeIsolated { self?.toggleMeeting() }
                }
                if hotKey.isRegistered { hotKeys.append(hotKey) } else { failed.insert(text) }
            } else {
                failed.insert(text)
            }
        }
        settingsModel.failedHotKeys = failed
    }

    private func unregisterHotKeys() {
        hotKeys = []
    }

    private func hookAgents(in config: Config) -> [HookInstaller.Agent] {
        HookInstaller.Agent.allCases.filter { config.integrations.watches($0) }
    }

    private func setHooks(installed agents: [HookInstaller.Agent], quietly: Bool = false) {
        // A copy of the app with its own IRONPET_ROOT must not rewrite the user's real Cursor and Claude Code configs.
        guard !Paths.isIsolated else { return }
        do {
            try installer.install(agents)
        } catch {
            quietly ? NSLog("ironpet: could not refresh hooks: \(error)") : showError("Could not install agent hooks", error)
        }
    }

    private func setHooks(removed agents: [HookInstaller.Agent]) {
        guard !Paths.isIsolated else { return }
        do { try installer.uninstall(agents) } catch { showError("Could not remove agent hooks", error) }
    }

    private func showSetup() {
        let setup = SetupWindow { [weak self] choices in
            self?.setupWindow = nil
            self?.finishSetup(choices)
        }
        setupWindow = setup
        setup.show()
    }

    /// Applies the welcome window's choices. "Not now" still writes config.json so the defaults are visible.
    private func finishSetup(_ choices: SetupWindow.Choices?) {
        guard let choices else {
            if !FileManager.default.fileExists(atPath: Config.file.path) { try? config.config.save() }
            return
        }
        config.update {
            $0.pet.name = choices.name
            for agent in HookInstaller.Agent.allCases { $0.integrations.setWatches(choices.agents.contains(agent), agent) }
            $0.integrations.githubAlerts = choices.githubAlerts
        }
        // The welcome choices now switch automations, which hold the reminders and the GitHub watcher.
        for reminder in AutomationMigration.reminders {
            try? automations.store.update(reminder.id) { $0.enabled = choices.reminders }
        }
        if automations.store.automations.contains(where: { $0.id == AutomationMigration.githubID }) {
            try? automations.store.update(AutomationMigration.githubID) { $0.enabled = choices.githubAlerts }
        } else if choices.githubAlerts {
            try? automations.store.replace(automations.store.automations + [AutomationDefaults.github(enabled: true)])
        }
        if !FileManager.default.fileExists(atPath: Config.file.path) { try? config.config.save() }
        // Hooks left by an older version that the user unticked.
        setHooks(removed: HookInstaller.Agent.allCases.filter { !choices.agents.contains($0) && installer.isInstalled($0) })
        if choices.launchAtLogin != LoginItem.isEnabled { LoginItem.set(choices.launchAtLogin) }
        Task { await chat.refreshAgents() }
    }

    @objc func showSettings(_ sender: Any?) {
        settingsWindow.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        meeting.prepareForQuit()
        chat.persistForRelaunch()
        chat.shutdown()
        try? FileManager.default.removeItem(at: Paths.portFile)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        pet.show()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        hookMenuItems().forEach(menu.addItem)
        return menu
    }

    private func startServer() throws {
        try Paths.ensureRoot()
        let token = try loadToken()
        let server = EventServer(token: token) { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        if TestControl.isEnabled {
            let control = TestControl(chat: chat, actions: TestControl.Actions(
                showChat: { [weak self] in self?.showChat() },
                buildPet: { [weak self] description in self?.requestPet(description) },
                chatWindowID: { [weak self] in self?.chatPanel.windowNumber ?? 0 },
                chatFrame: { [weak self] in
                    guard let frame = self?.chatPanel.frame, let screen = NSScreen.screens.first else { return .zero }
                    return CGRect(x: frame.minX, y: screen.frame.height - frame.maxY, width: frame.width, height: frame.height)
                },
                openSession: { [weak self] id in self?.openSession(id) },
                scrollChat: { [weak self] fraction, path in
                    // The transcript is the tallest scroll view; the composer's text view has one too.
                    @MainActor func find(_ view: NSView?) -> [NSScrollView] {
                        guard let view else { return [] }
                        return (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap { find($0) }
                    }
                    let scrolls = find(self?.chatPanel.contentView)
                    guard let scroll = scrolls.max(by: { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }), let doc = scroll.documentView else { return [String: Any]() }
                    let visible = scroll.contentView.bounds
                    if let fraction {
                        let maxTop = max(0, doc.bounds.height - visible.height)
                        scroll.contentView.scroll(to: NSPoint(x: visible.minX, y: maxTop * fraction))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    let now = scroll.contentView.bounds
                    let result: [String: Any] = ["top": now.minY, "bottomGap": doc.bounds.height - now.maxY, "content": doc.bounds.height, "viewport": now.height]
                    if let path {
                        if let view = self?.chatPanel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                        }
                    }
                    return result
                },
                showSettings: { [weak self] tab, snapshot in
                    self?.settingsWindow.show()
                    if let tab { self?.settingsModel.tab = tab }
                    if let snapshot { _ = self?.settingsWindow.snapshot(to: URL(fileURLWithPath: snapshot)) }
                    return self?.settingsWindow.windowNumber ?? 0
                },
                capture: { [weak self] region in self?.captureScreen(region: region) },
                notificationAction: { [weak self] id, allow in self?.notifier.onApprovalAction?(id, allow) },
                signals: signals,
                meeting: meeting,
                meetingFrame: { [weak self] in
                    guard let screen = NSScreen.screens.first else { return .zero }
                    let showsBubble = self?.announcer.bubbles.bubbles.contains { $0.id == Self.meetingBubbleID } == true
                    let window: NSWindow? = self?.meetingPanel.isVisible == true ? self?.meetingPanel
                        : showsBubble && self?.bubblePanel.panel.isVisible == true ? self?.bubblePanel.panel : nil
                    guard let frame = window?.frame else { return .zero }
                    return CGRect(x: frame.minX, y: screen.frame.height - frame.maxY, width: frame.width, height: frame.height)
                },
                meetingMenuTitle: { [weak self] in self?.meetingMenuItem()?.title ?? "" },
                meetingUI: { [weak self] in
                    ((self?.announcer.bubbles.bubbles.contains { $0.id == Self.meetingBubbleID }) == true,
                     self?.pet.view.recording == .hidden)
                },
                meetingBubble: { [weak self] show in
                    if show { self?.showMeetingBubble() } else { self?.announcer.bubbles.dismiss(Self.meetingBubbleID) }
                },
                telegram: telegram,
                simulateCall: { [weak self] app, event in self?.simulateCall(app, event) },
                callOffer: { [weak self] in
                    self?.announcer.bubbles.bubbles.first { $0.id == Self.callBubbleID }?.title ?? ""
                },
                automations: automations,
                advanceClock: { [weak self] seconds in self?.testClockOffset += seconds },
                bubbles: { [weak self] in
                    (self?.announcer.bubbles.bubbles ?? []).map {
                        ["id": $0.id, "title": $0.title, "body": $0.body ?? "", "buttons": $0.actions.map(\.title)]
                    }
                },
                pressBubbleButton: { [weak self] id, title in
                    guard let action = self?.announcer.bubbles.bubbles.first(where: { $0.id == id })?.actions.first(where: { $0.title == title }) else { return false }
                    action.run()
                    return true
                }
            ))
            testControl = control
            server.onTest = { request, respond in
                DispatchQueue.main.async { respond(control.handle(request)) }
            }
            NSLog("ironpet: test mode enabled")
        }
        let snapshot = StatusSnapshot()
        server.status = { snapshot.data }
        pet.onRefresh = { [weak self] mood in
            guard let self else { return }
            let service = self.automations
            snapshot.update(store: self.store, mood: mood, automations: (service?.store.automations ?? []).map { a in
                var entry = service!.summary(a)
                entry["recentRuns"] = service!.history(a.id, limit: 5)
                return entry
            })
        }
        server.onAutomation = { [weak self] request, respond in
            AutomationMCP.route(request, service: { self?.automations }, respond: respond)
        }
        try server.start()
        self.server = server
        registerMCPServer()
        try String(server.port).write(to: Paths.portFile, atomically: true, encoding: .utf8)
        NSLog("ironpet: listening on 127.0.0.1:\(server.port)")
    }

    private func handle(_ event: HookEvent) {
        // Cursor replays its events through Claude Code hooks too; keep only the Cursor copy.
        if event.source == .claude, event.payload["cursor_version"] != nil { return }
        store.apply(event)
    }

    private func loadToken() throws -> String {
        if let existing = try? String(contentsOf: Paths.tokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), existing.count >= 32 {
            return existing
        }
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        try token.write(to: Paths.tokenFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.tokenFile.path)
        return token
    }

    private func toggleChat() {
        chatPanel.isVisible && chatPanel.isKeyWindow && NSApp.isActive ? chatPanel.close() : showChat()
    }

    /// Opening the chat never changes its session or folder. Only the user does, with New Chat, the folder picker,
    /// a saved thread or the agent switch.
    private func showChat() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        chat.prepareForShow()
        chat.isVisible = true
        wispr.start()
        NSApp.activate()
        chatPanel.show(near: pet.panel.frame)
        pet.refreshMood()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            // Cooperative activation can be refused for a background app; force it so Wispr Flow
            // sees ironpet as the frontmost app.
            if !NSApp.isActive { NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps]) }
            self.chatPanel.makeKeyAndOrderFront(nil)
            self.chatPanel.focusInput()
        }
    }

    /// Captures the front window (or a dragged region) before ironpet activates, then opens the chat with it.
    private func captureScreen(region: Bool) {
        guard ScreenCapture.hasPermission else {
            ScreenCapture.requestPermission()
            announcer.chat("Allow Screen Recording for ironpet, then try again",
                           detail: "System Settings → Privacy & Security → Screen Recording.")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        let target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previousApp : front
        if chatPanel.isVisible { chatPanel.orderOut(nil) }
        Task { @MainActor in
            let shot = region ? await ScreenCapture.captureRegion() : await ScreenCapture.captureWindow(of: target)
            if let shot { chat.attach(shot) }
            if shot != nil || chat.isVisible { showChat() }
        }
    }

    /// Hands focus back to the app the user was in before opening the chat.
    private func restorePreviousApp() {
        if NSApp.isActive { previousApp?.activate() }
        previousApp = nil
    }

    private func openSession(_ id: String) {
        guard let session = store.sessions[id] else { return }
        pet.jump(to: session)
    }

    /// Sends `prompt` to the agent in the current chat and folder. Without `show`, the chat stays hidden and Ghost says when the agent
    /// needs something. When the chat is busy with a turn or an approval, nothing is replaced: a bubble offers to send it.
    private func sendToChat(_ prompt: String, show: Bool, title: String, busyBody: String) {
        if chat.isRunning || !chat.approvals.isEmpty {
            announcer.automation(AutomationNotice(
                id: "automation-chat:\(title)", symbol: "wrench.and.screwdriver.fill", tint: .warn, title: title, body: busyBody,
                buttons: [.init(title: "Send", primary: true) { [weak self] in self?.sendToChat(prompt, show: true, title: title, busyBody: busyBody) },
                          .init(title: "Not now") {}]))
            return
        }
        let sent = sendInCurrentChat(prompt)
        // Without a folder the prompt waits in the input, so show the chat for the user to pick one.
        if show || !sent { showChat() } else {
            announcer.automation(AutomationNotice(
                id: "automation-chat:\(title)", symbol: "wrench.and.screwdriver.fill", tint: .info, title: title,
                body: "Asked \(chat.agent.name) to fix it.", buttons: [.init(title: "Open chat", primary: true) { [weak self] in self?.showChat() }], expires: 20))
        }
    }

    /// "Ask Ghost": opens the chat in the current session and folder with the prompt ready to send. A draft the user
    /// was typing stays below the prompt, separated by a blank line.
    private func ask(_ prompt: String) {
        showChat()
        let draft = chat.input.trimmingCharacters(in: .whitespacesAndNewlines)
        // A second press on the same Ask leaves the input as it is.
        if draft.hasPrefix(prompt) { return }
        chat.prefill(draft.isEmpty ? prompt : prompt + "\n\n" + draft)
    }

    /// Sends `prompt` in the current session and folder. A draft the user was typing and any attachments come back
    /// after the send. If the send does not go through (no folder chosen yet), the prompt waits in the input above
    /// the draft, and prefill keeps the dictation auto-send from firing on it.
    @discardableResult
    private func sendInCurrentChat(_ prompt: String) -> Bool {
        let draft = chat.input
        let staged = chat.attachments
        chat.attachments = []
        chat.input = prompt
        chat.send()
        chat.attachments = staged
        if chat.input.isEmpty {
            chat.input = draft
            return true
        } else {
            chat.prefill(draft.isEmpty ? chat.input : draft + "\n\n" + chat.input)
            return false
        }
    }

    /// "Build a new pet": opens the chat and sends the request in the current thread. The session and folder stay as
    /// they are. A draft the user was typing comes back after the send. While the agent is running, or before a folder
    /// is chosen, the request waits in the input box instead.
    private func requestPet(_ description: String) {
        showChat()
        PetPrompt.ensureSkillInstalled()
        sendInCurrentChat(PetPrompt.build(description: description))
    }

    // MARK: Meetings

    /// Shows the panel while a meeting is being set up, recorded or wrapped up, and hides it otherwise.
    ///
    /// The picker is a small window. Once recording starts, the status lives in a pet bubble. The user can hide that
    /// bubble, and the pet then shows a Recording button that brings it back.
    private func syncMeetingPanel() {
        let bubbles = announcer.bubbles
        switch meeting.phase {
        case .idle:
            meetingPanel.dismiss()
            meetingBubbleHidden = false
            removeMeetingBubble()
        case .choosing:
            meetingBubbleHidden = false
            removeMeetingBubble()
            meetingPanel.present(near: pet.panel.frame)
        default:
            meetingPanel.dismiss()
            if !meetingBubbleHidden, !bubbles.bubbles.contains(where: { $0.id == Self.meetingBubbleID }) {
                bubbles.show(Bubble(id: Self.meetingBubbleID, symbol: "record.circle", tint: .red, title: "Meeting",
                                    content: AnyView(MeetingView(controller: meeting, embedded: true))))
            }
        }
        pet.setRecording(meeting.phase == .recording || meeting.phase == .finishing || meeting.phase == .summarizing
                         ? (meetingBubbleHidden ? .hidden : .shown) : .none)
        pet.refreshMood()
    }

    static let meetingBubbleID = "meeting"
    static let callBubbleID = "meeting-call"

    // MARK: Call detection

    /// Watches the microphone while meetings and call offers are on, and stops otherwise.
    private func startCallMonitor() {
        let meetings = config.config.meetings
        let on = meetings.enabled && meetings.offerToRecordCalls
        if on, callMonitor == nil {
            let detector = CallDetector(source: { CallMonitor.micClients() })
            detector.onStarted = { [weak self] app in self?.callEvent(app, started: true) }
            detector.onEnded = { [weak self] app in self?.callEvent(app, started: false) }
            callMonitor = CallMonitor(detector: detector)
        }
        if on { callMonitor?.start() } else {
            callMonitor?.stop()
            announcer.bubbles.dismiss(Self.callBubbleID)
        }
    }

    private func callEvent(_ app: String, started: Bool) {
        let action = started ? callPrompt.callStarted(app) : callPrompt.callEnded(app)
        if !started, case .none = action { announcer.bubbles.dismiss(Self.callBubbleID) }
        switch action {
        case .offerRecord(let id): showCallBubble(id, stop: false)
        case .offerStop(let id): showCallBubble(id, stop: true)
        case nil: break
        }
    }

    private func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.localizedName
            ?? (bundleID == "net.whatsapp.WhatsApp" ? "WhatsApp" : bundleID)
    }

    private func showCallBubble(_ bundleID: String, stop: Bool) {
        let name = appName(bundleID)
        let close = { [weak self] in self?.announcer.bubbles.dismiss(Self.callBubbleID) }
        let actions: [Bubble.Action] = stop
            ? [.init(title: "Stop recording", style: .primary) { [weak self] in
                    self?.meeting.stop()
                    close()
                },
               .init(title: "Keep recording") { close() }]
            : [.init(title: "Record", style: .primary) { [weak self] in
                    close()
                    self?.recordCall(bundleID, name: name)
                },
               .init(title: "Not now") { [weak self] in
                    self?.callPrompt.notNow(bundleID)
                    close()
                }]
        announcer.bubbles.show(Bubble(id: Self.callBubbleID, symbol: "phone.fill", tint: .red,
                                      title: stop ? "Call ended. Stop recording?" : "Looks like a call in \(name). Record it?",
                                      actions: actions))
    }

    /// Opens the picker with the call's app chosen and starts, like the user pressing Start there.
    private func recordCall(_ bundleID: String, name: String) {
        guard meeting.phase == .idle || meeting.phase == .done else { return }
        meeting.showPicker()
        guard meeting.phase == .choosing else { return }
        callPrompt.accepted(bundleID)
        meeting.choice = .app(AudioApp(bundleID: bundleID, name: name))
        meeting.start()
    }

    private func simulateCall(_ bundleID: String, _ event: String) {
        switch event {
        case "record": recordCall(bundleID, name: appName(bundleID))
        case "not-now":
            callPrompt.notNow(bundleID)
            announcer.bubbles.dismiss(Self.callBubbleID)
        case "ended": callEvent(bundleID, started: false)
        default: callEvent(bundleID, started: true)
        }
    }

    private func removeMeetingBubble() {
        meetingBubbleRemoving = true
        announcer.bubbles.dismiss(Self.meetingBubbleID)
        meetingBubbleRemoving = false
    }

    /// The user closed the meeting bubble. Closing "Meeting saved" ends the meeting view; closing it while recording
    /// only hides it, and the pet's Recording button shows it again.
    private func meetingBubbleClosed(_ id: String) {
        guard id == Self.meetingBubbleID, !meetingBubbleRemoving else { return }
        if meeting.phase == .done {
            meeting.dismiss()
        } else {
            meetingBubbleHidden = true
            syncMeetingPanel()
        }
    }

    private func showMeetingBubble() {
        meetingBubbleHidden = false
        syncMeetingPanel()
    }

    private func toggleMeeting() {
        if meeting.phase == .recording {
            meeting.stop()
        } else {
            meeting.showPicker()
        }
    }

    @objc private func startMeeting(_ sender: Any?) {
        meeting.showPicker()
    }

    @objc private func stopMeeting(_ sender: Any?) {
        meeting.stop()
    }

    private func meetingMenuItem() -> NSMenuItem? {
        guard config.config.meetings.enabled else { return nil }
        if meeting.phase == .recording {
            let item = NSMenuItem(title: "Stop meeting transcript", action: #selector(stopMeeting), keyEquivalent: "")
            item.target = self
            return item
        }
        let item = NSMenuItem(title: "Start meeting transcript…", action: #selector(startMeeting), keyEquivalent: "")
        item.target = self
        item.isEnabled = !meeting.isBusy
        return item
    }

    /// Adds the transcript, and the summary if there is one, to the current chat. Never changes the chat's
    /// session or folder.
    private func openMeetingInChat(_ files: [URL]) {
        chat.attach(files)
        showChat()
    }

    private func hookMenuItems() -> [NSMenuItem] {
        let system = NSMenuItem(title: "Also show macOS notifications", action: #selector(toggleSystemNotifications), keyEquivalent: "")
        system.state = announcer.alsoSystemNotifications ? .on : .off
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.state = LoginItem.isEnabled ? .on : .off
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        for item in [system, login, settings] { item.target = self }
        return [meetingMenuItem(), settings, automationsMenuItem(), integrationsMenuItem(), system, login].compactMap { $0 }
    }

    private func integrationsMenuItem() -> NSMenuItem {
        let config = config.config.integrations
        let mcp = NSMenuItem(title: "Share MCP sign-ins across folders…", action: #selector(toggleMCPSharing), keyEquivalent: "")
        mcp.state = config.shareMCPSignIns ? .on : .off
        let submenu = NSMenu()
        for item in [mcp] {
            item.target = self
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Integrations", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Every automation with a switch, plus the pause for all reminders.
    private func automationsMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        for a in automations.store.automations {
            let item = NSMenuItem(title: a.name, action: #selector(toggleAutomation(_:)), keyEquivalent: "")
            item.representedObject = a.id
            item.state = a.enabled ? .on : .off
            item.target = self
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let pause = NSMenuItem(title: "Pause reminders", action: #selector(toggleReminderPause), keyEquivalent: "")
        pause.state = config.config.reminders.paused ? .on : .off
        pause.target = self
        submenu.addItem(pause)
        let logs = NSMenuItem(title: "Show logs…", action: #selector(showAutomationLogs), keyEquivalent: "")
        logs.target = self
        submenu.addItem(logs)
        let more = NSMenuItem(title: "Edit automations…", action: #selector(showSettings(_:)), keyEquivalent: "")
        more.target = self
        submenu.addItem(more)
        let item = NSMenuItem(title: "Automations", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func showAutomationLogs() {
        logWindow.show()
    }

    @objc private func toggleAutomation(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        try? automations.store.update(id) { $0.enabled.toggle() }
    }

    @objc private func toggleReminderPause() {
        config.update { $0.reminders.paused.toggle() }
    }

    @objc private func toggleMCPSharing() {
        if !config.config.integrations.shareMCPSignIns, !IntegrationsSettings.confirmMCPSharing() { return }
        config.update { $0.integrations.shareMCPSignIns.toggle() }
    }

    @objc private func toggleSystemNotifications() {
        announcer.alsoSystemNotifications.toggle()
    }

    @objc private func toggleLoginItem() {
        LoginItem.set(!LoginItem.isEnabled)
    }

    private func showError(_ title: String, _ error: Error) {
        NSLog("ironpet: \(title): \(error)")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit ironpet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(submenu("Edit", Self.editItems()))
        let newChat = NSMenuItem(title: "New Chat", action: #selector(newChat(_:)), keyEquivalent: "n")
        newChat.target = self
        main.addItem(submenu("Chat", [newChat]))
        // performClose(_:) beeps on the chat panel, which has no .closable style, so close the key window directly.
        let close = NSMenuItem(title: "Close", action: #selector(closeKeyWindow(_:)), keyEquivalent: "w")
        close.target = self
        main.addItem(submenu("Window", [close]))
        return main
    }

    /// Key equivalents reach a text field only through the main menu, so without these items ⌘Z, ⌘X, ⌘C,
    /// ⌘A and friends did nothing in the chat. The actions go to the first responder. AppKit adds
    /// "Start Dictation" and "Emoji & Symbols" to a menu titled "Edit" by itself.
    private static func editItems() -> [NSMenuItem] {
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        return [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Delete", #selector(NSText.delete(_:)), ""),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func closeKeyWindow(_ sender: Any?) {
        NSApp.keyWindow?.close()
    }

    @objc private func newChat(_ sender: Any?) {
        chat.newChat()
        showChat()
    }
}
