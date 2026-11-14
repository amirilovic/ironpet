import AppKit
import Carbon
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let signals = SignalStore()
    private lazy var github = GitHubWatcher(store: signals)
    private lazy var sentry = SentryWatcher(store: signals)
    private let chat = ChatSession()
    private let notifier = Notifier()
    private let installer = HookInstaller()
    private let reminders = ReminderScheduler()
    private lazy var announcer = Announcer(notifier: notifier)
    private var bubblePanel: BubblePanel!
    private var server: EventServer?
    private var pet: PetController!
    private var chatPanel: ChatPanel!
    private var hotKeys: [HotKey] = []
    private var previousApp: NSRunningApplication?
    private let wispr = WisprBridge()
    private var testControl: TestControl?
    private var timers: [Timer] = []
    private var cancellables: Set<AnyCancellable> = []
    private let config = ConfigStore.shared
    private var setupWindow: SetupWindow?
    private lazy var settingsModel = SettingsModel(actions: .init(
        suspendHotKeys: { [weak self] suspended in suspended ? self?.unregisterHotKeys() : self?.registerHotKeys() }
    ), announcer: announcer)
    private lazy var settingsWindow = SettingsWindow(model: settingsModel)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        announcer.openSession = { [weak self] id in self?.openSession(id) }
        announcer.openChat = { [weak self] in self?.showChat() }
        announcer.ask = { [weak self] prompt in self?.ask(prompt) }
        announcer.decide = { [weak self] id, allow in self?.chat.decide(id: id, allow: allow) }
        announcer.reminderAction = { [weak self] kinds, snooze in
            if snooze {
                self?.reminders.snooze(kinds)
            } else {
                self?.pet.nudge([.done], each: 3)
            }
        }
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
        if config.config.integrations.githubAlerts { github.start() }
        sentry.start()

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
        chat.onAttention = { [weak self] title in self?.announcer.chat(title) }
        chat.onApprovalNeeded = { [weak self] approval in
            self?.announcer.approval(id: approval.id, title: approval.title, detail: approval.detail)
        }
        chat.onApprovalResolved = { [weak self] id in self?.announcer.clearApproval(id: id) }
        chat.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pet.refreshMood() }
            .store(in: &cancellables)
        registerHotKeys()
        config.$config
            .removeDuplicates()
            .scan((Config(), config.config)) { ($0.1, $1) }
            .dropFirst()
            .sink { [weak self] old, new in self?.apply(config: new, previous: old) }
            .store(in: &cancellables)

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

        reminders.isAgentWorking = { [weak self] in
            guard let self else { return false }
            return self.chat.state == .running || self.store.sessions.values.contains { $0.status == .running }
        }
        reminders.isBusy = { [weak self] in
            guard let self else { return false }
            return self.chat.isVisible || !self.chat.approvals.isEmpty || self.store.summary.status == .needsInput
        }
        reminders.onDeliver = { [weak self] kinds, working in
            self?.announcer.reminder(kinds, agentWorking: working)
            self?.pet.nudge(kinds.map(\.mood))
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reminders.tick() }
        })
    }

    /// Applies settings that need more than being read at the point of use.
    private func apply(config new: Config, previous old: Config) {
        let (newAgents, oldAgents) = (hookAgents(in: new), hookAgents(in: old))
        setHooks(installed: newAgents.filter { !oldAgents.contains($0) })
        setHooks(removed: oldAgents.filter { !newAgents.contains($0) })
        if new.hotkeys != old.hotkeys || new.voice.enabled != old.voice.enabled { registerHotKeys() }
        if !new.voice.enabled { chat.voice.cancel() }
        if new.integrations.githubAlerts != old.integrations.githubAlerts {
            new.integrations.githubAlerts ? github.start() : github.stop()
        }
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
        // Hold to talk. Only registered with voice notes on, so a disabled feature owns no key.
        if let text = VoiceController.hotkey(in: config.config), let shortcut = Shortcut(text) {
            let hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: 4, onRelease: { [weak self] in
                MainActor.assumeIsolated { self?.chat.voice.stop() }
            }, handler: { [weak self] in
                MainActor.assumeIsolated {
                    self?.showChat()
                    self?.chat.voice.start()
                }
            })
            if hotKey.isRegistered { hotKeys.append(hotKey) } else { failed.insert(text) }
        } else if config.config.voice.enabled, !config.config.hotkeys.voice.isEmpty {
            failed.insert(config.config.hotkeys.voice)
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
            $0.reminders.paused = !choices.reminders
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
                chatWindowID: { [weak self] in self?.chatPanel.windowNumber ?? 0 },
                chatFrame: { [weak self] in
                    guard let frame = self?.chatPanel.frame, let screen = NSScreen.screens.first else { return .zero }
                    return CGRect(x: frame.minX, y: screen.frame.height - frame.maxY, width: frame.width, height: frame.height)
                },
                openSession: { [weak self] id in self?.openSession(id) },
                showSettings: { [weak self] snapshot in
                    self?.settingsWindow.show()
                    if let snapshot { _ = self?.settingsWindow.snapshot(to: URL(fileURLWithPath: snapshot)) }
                    return self?.settingsWindow.windowNumber ?? 0
                },
                capture: { [weak self] region in self?.captureScreen(region: region) },
                notificationAction: { [weak self] id, allow in self?.notifier.onApprovalAction?(id, allow) },
                signals: signals,
                github: github
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
            snapshot.update(store: self.store, mood: mood)
        }
        try server.start()
        self.server = server
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

    private func showChat() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        chat.prepareForShow(detected: WorkspaceDetector.workspace(of: previousApp ?? front))
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

    /// "Ask Ghost": a new chat with the prompt ready to send.
    private func ask(_ prompt: String) {
        chat.newChat()
        showChat()
        chat.prefill(prompt)
    }

    private func hookMenuItems() -> [NSMenuItem] {
        let system = NSMenuItem(title: "Also show macOS notifications", action: #selector(toggleSystemNotifications), keyEquivalent: "")
        system.state = announcer.alsoSystemNotifications ? .on : .off
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.state = LoginItem.isEnabled ? .on : .off
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        for item in [system, login, settings] { item.target = self }
        return [settings, reminders.menuItem(), integrationsMenuItem(), system, login]
    }

    private func integrationsMenuItem() -> NSMenuItem {
        let config = config.config.integrations
        let github = NSMenuItem(title: "GitHub PR & CI alerts", action: #selector(toggleGitHubAlerts), keyEquivalent: "")
        github.state = config.githubAlerts ? .on : .off
        let mcp = NSMenuItem(title: "Share MCP sign-ins across folders…", action: #selector(toggleMCPSharing), keyEquivalent: "")
        mcp.state = config.shareMCPSignIns ? .on : .off
        let submenu = NSMenu()
        for item in [github, mcp] {
            item.target = self
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Integrations", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func toggleGitHubAlerts() {
        config.update { $0.integrations.githubAlerts.toggle() }
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
