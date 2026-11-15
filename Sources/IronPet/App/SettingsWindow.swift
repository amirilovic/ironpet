import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the settings window needs from the rest of the app, beyond `ConfigStore`.
@MainActor
final class SettingsModel: ObservableObject {
    struct Actions {
        /// Global hotkeys are paused while a shortcut is being recorded, so pressing the current one records it.
        var suspendHotKeys: (Bool) -> Void
        /// Opens the chat and sends the "build a new pet" prompt in the current thread.
        var buildPet: (String) -> Void
    }

    let actions: Actions
    /// Set once the app has built it, before the window can open.
    var automations: AutomationService?
    /// Opens the execution log window, for one automation or all of them.
    var showLogs: (String?) -> Void = { _ in }
    /// Sends what the user wants to the chat, for the agent to create the automation.
    var createWithAgent: (String) -> Void = { _ in }
    /// Shortcut config strings that failed to register (taken by another app or invalid).
    @Published var failedHotKeys: Set<String> = []
    @Published var launchAtLogin = LoginItem.isEnabled
    let pets = PetGalleryModel()
    private let announcer: Announcer
    let telegram: TelegramBridge
    /// The selected tab's tag. Tests set it to screenshot a tab.
    @Published var tab = "general"

    init(actions: Actions, announcer: Announcer, telegram: TelegramBridge) {
        self.actions = actions
        self.announcer = announcer
        self.telegram = telegram
    }

    var alsoSystemNotifications: Bool {
        get { announcer.alsoSystemNotifications }
        set {
            objectWillChange.send()
            announcer.alsoSystemNotifications = newValue
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        LoginItem.set(on)
        launchAtLogin = LoginItem.isEnabled
    }

    func refresh() {
        launchAtLogin = LoginItem.isEnabled
        ConfigStore.shared.reloadIfChanged()
    }
}

@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
    }

    var windowNumber: Int { window?.windowNumber ?? 0 }

    /// Draws the window's own contents to a PNG, for tests; needs no screen-recording permission.
    func snapshot(to url: URL) -> Bool {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    func show() {
        model.refresh()
        if window == nil {
            // A fixed SwiftUI height plus the hosting controller's auto sizing both set the window height,
            // which logs "AttributeGraph: cycle detected" on tab switches. Only the width stays in SwiftUI.
            let host = NSHostingController(rootView: SettingsView(model: model))
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.title = "ironpet Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 520, height: 600))
            window.center()
            self.window = window
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.syncGalleryActivity() }
                },
                center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.model.pets.setWindowShown(false) }
                },
            ]
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        model.pets.setWindowShown(true)
    }

    private var observers: [NSObjectProtocol] = []

    /// Pauses the pet previews while the window is minimized or covered.
    private func syncGalleryActivity() {
        guard let window else { return }
        model.pets.setWindowShown(window.isVisible && window.occlusionState.contains(.visible))
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $model.tab) {
                GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag("general")
                AutomationsSettings(model: model).tabItem { Label("Automations", systemImage: "clock.badge.checkmark") }.tag("automations")
                IntegrationsSettings(telegram: model.telegram).tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }.tag("integrations")
                VoiceSettings(model: model).tabItem { Label("Voice", systemImage: "mic") }.tag("voice")
                MeetingSettings(model: model).tabItem { Label("Meetings", systemImage: "person.2.wave.2") }.tag("meetings")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            Divider().padding(.top, 8)
            HStack {
                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .lineLimit(2)
                }
                Spacer()
                Button("Open config.json") {
                    if !FileManager.default.fileExists(atPath: Config.file.path) { try? store.config.save() }
                    NSWorkspace.shared.open(Config.file)
                }
                .help("Every setting here lives in ~/.ironpet/config.json; edits apply within a few seconds.")
            }
            .padding(12)
        }
        .frame(width: 520)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var store = ConfigStore.shared
    @State private var name = ConfigStore.shared.config.pet.name

    var body: some View {
        Form {
            Section("Pet") {
                TextField("Name", text: $name)
                    .onSubmit(saveName)
                    .onChange(of: name) { saveName() }
                    .onChange(of: store.config.pet.name) { if store.config.pet.name != name { name = store.config.pet.name } }
                PetGallery(gallery: model.pets, buildPet: model.actions.buildPet)
            }
            Section("Shortcuts") {
                ShortcutRow(title: "Open chat", path: \.chat, model: model)
                ShortcutRow(title: "Ask about front window", path: \.captureWindow, model: model)
                ShortcutRow(title: "Ask about a region", path: \.captureRegion, model: model)
            }
            Section("App") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                Toggle("Also show macOS notifications", isOn: Binding(get: { model.alsoSystemNotifications },
                                                                      set: { model.alsoSystemNotifications = $0 }))
            }
            Section {
                Picker("Open sessions in", selection: Binding(get: { store.config.openIn },
                                                              set: { value in store.update { $0.openIn = value } })) {
                    Text("Auto (the app that started the agent)").tag(Editors.auto)
                    ForEach(openChoices, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                }
            } footer: {
                Text("Where the Open button on a session takes you. Add more apps under \"editors\" in ~/.ironpet/config.json.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(watchableAgents, id: \.self) { agent in
                    Toggle("Watch \(agent.displayName)", isOn: Binding(get: { store.config.integrations.watches(agent) },
                                                                     set: { on in store.update { $0.integrations.setWatches(on, agent) } }))
                        .help(agent.watchNote ?? "Adds ironpet's hooks to \(agent.configFile.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                }
            } header: {
                Text("Agents")
            } footer: {
                Text("Lists the agents found on this Mac. Watching adds ironpet's hooks to the agent's own config so \(store.config.pet.name) sees sessions you start yourself. Turning one off removes only ironpet's hooks; an existing file is backed up as *.ironpet-backup the first time. Codex asks you to trust new hooks in its /hooks screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SkillsSettings()
        }
        .formStyle(.grouped)
    }

    /// Agents found on this Mac, plus any already watched, so a switch never disappears while it is on.
    private var watchableAgents: [HookInstaller.Agent] {
        HookInstaller.Agent.allCases.filter { $0.isPresent || store.config.integrations.watches($0) }
    }

    /// Installed editors, plus the saved choice when that app is gone, so the picker never shows a blank.
    private var openChoices: [OpenTarget] {
        var choices = Editors.installed()
        let saved = store.config.openIn
        if saved != Editors.auto, !choices.contains(where: { $0.bundleID == saved }) {
            choices.append(OpenTarget(name: Editors.appName(saved) ?? saved, bundleID: saved))
        }
        return choices
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.update { $0.pet.name = trimmed }
    }
}

private struct ShortcutRow: View {
    let title: String
    let path: WritableKeyPath<Config.Hotkeys, String>
    @ObservedObject var model: SettingsModel
    @ObservedObject private var store = ConfigStore.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    private var value: String { store.config.hotkeys[keyPath: path] }

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack {
                    Button(action: toggleRecording) {
                        Text(recording ? "Type shortcut…" : Shortcut.display(value) ?? (value.isEmpty ? "Off" : "Invalid"))
                            .frame(minWidth: 110)
                    }
                    if !value.isEmpty && !recording {
                        Button { store.update { $0.hotkeys[keyPath: path] = "" } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .help("Turn this shortcut off")
                    }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                } else if model.failedHotKeys.contains(value) {
                    Text("In use by another app; pick another.").font(.caption).foregroundStyle(.orange)
                } else if !value.isEmpty, Shortcut(value) == nil {
                    Text("Can't read \"\(value)\" in config.json.").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        message = nil
        recording = true
        model.actions.suspendHotKeys(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stopRecording()
                return nil
            }
            guard let shortcut = Shortcut(event: event) else {
                message = "Use ⌘, ⌥ or ⌃ (Shift alone isn't enough), or a function key."
                return nil
            }
            let others = [\Config.Hotkeys.chat, \.captureWindow, \.captureRegion, \.voice, \.meeting].filter { $0 != path }
            if others.contains(where: { Shortcut(store.config.hotkeys[keyPath: $0]) == shortcut }) {
                message = "\(shortcut.display) is already used for another action."
                return nil
            }
            store.update { $0.hotkeys[keyPath: path] = shortcut.text }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        model.actions.suspendHotKeys(false)
    }
}

// MARK: - Voice

private struct VoiceSettings: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var store = ConfigStore.shared
    @State private var baseUrl = ConfigStore.shared.config.voice.baseUrl
    @State private var modelName = ConfigStore.shared.config.voice.model
    @State private var key = ""
    @State private var keySaved = VoiceKey.isSet
    @State private var keyError = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    var body: some View {
        Form {
            Section {
                Toggle("Voice notes", isOn: Binding(get: { store.config.voice.enabled },
                                                    set: { on in store.update { $0.voice.enabled = on } }))
            } footer: {
                Text("Off by default. When on, a microphone button appears in the chat, and what you record is sent to the server below. ironpet ships no speech model; point it at any server with an OpenAI-style /audio/transcriptions endpoint. Nothing is recorded or sent while this is off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Server") {
                TextField("Base URL", text: $baseUrl)
                    .onSubmit(saveServer)
                    .onChange(of: baseUrl) { saveServer() }
                TextField("Model", text: $modelName)
                    .onSubmit(saveServer)
                    .onChange(of: modelName) { saveServer() }
                LabeledContent("API key") {
                    HStack {
                        SecureField(keySaved ? "Saved in Keychain" : "Optional", text: $key)
                            .onSubmit(saveKey)
                            .multilineTextAlignment(.trailing)
                        if !key.isEmpty { Button("Save", action: saveKey) }
                        if keySaved && key.isEmpty {
                            Button("Remove") {
                                VoiceKey.delete()
                                keySaved = false
                            }
                        }
                    }
                }
                if keyError {
                    Text("Could not save the key to the Keychain.").font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Connection") {
                    HStack {
                        if testing { ProgressView().controlSize(.small) }
                        Button("Test connection", action: testConnection).disabled(testing)
                    }
                }
                if let testResult {
                    Text(testResult.text)
                        .font(.caption)
                        .foregroundStyle(testResult.ok ? Color.green : Color.red)
                        .textSelection(.enabled)
                }
            }
            Section {
                ShortcutRow(title: "Voice shortcut", path: \.voice, model: model)
                Toggle("Hold to talk", isOn: Binding(get: { store.config.voice.holdToTalk },
                                                     set: { on in store.update { $0.voice.holdToTalk = on } }))
            } footer: {
                Text("The transcript lands in the chat input, or is sent right away when \"Send after dictation\" is on in the chat's settings menu. With Hold to talk on, hold the shortcut to record and release to transcribe. With it off, press once to start and again to stop. While recording, Enter also stops and transcribes, and Esc cancels. The key is kept in your Keychain, not in config.json.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func saveServer() {
        store.update {
            $0.voice.baseUrl = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.voice.model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func saveKey() {
        keyError = !VoiceKey.save(key)
        keySaved = VoiceKey.isSet
        if !keyError { key = "" }
    }

    /// Sends one second of a quiet tone: enough to prove the URL, key and model are accepted without needing speech.
    private func testConnection() {
        saveServer()
        if !key.isEmpty { saveKey() }
        testing = true
        testResult = nil
        let transcriber = Transcriber(baseURL: baseUrl, model: modelName, apiKey: VoiceKey.load(), timeout: 30)
        Task {
            do {
                let text = try await transcriber.transcribe(wav: Self.testClip)
                testResult = (true, text.isEmpty ? "Connected. The server accepted the test clip." : "Connected. The server replied: \"\(text)\"")
            } catch {
                testResult = (false, error.localizedDescription)
            }
            testing = false
        }
    }

    static let testClip: Data = {
        let samples = (0..<WAV.sampleRate).map { Int16(sin(Double($0) * 2 * .pi * 440 / Double(WAV.sampleRate)) * 3000) }
        return WAV.encode(samples)
    }()
}

// MARK: - Meetings

private struct MeetingSettings: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var store = ConfigStore.shared
    @State private var testing = false
    @State private var enableError: String?
    @State private var installedAgents: [ACPAgent] = []

    private var meetings: Config.Meetings { store.config.meetings }

    /// The installed agents, plus the saved one so the picker never shows a blank.
    private var agents: [ACPAgent] {
        var list = installedAgents
        if !list.contains(where: { $0.id == meetings.summaryAgent }), let saved = AgentCatalog.agent(id: meetings.summaryAgent) { list.append(saved) }
        return list
    }

    /// Models the agent reported the last time it ran in the chat. An agent that never ran there has none yet.
    private var models: [ChatModel] {
        AgentCatalog.agent(id: meetings.summaryAgent).map(ChatSession.cachedModels(for:)) ?? []
    }

    var body: some View {
        Form {
            Section {
                Toggle("Meeting transcripts", isOn: Binding(get: { meetings.enabled }, set: setEnabled))
                    .disabled(testing)
                if testing {
                    HStack { ProgressView().controlSize(.small); Text("Testing the voice server…").font(.caption) }
                }
                if let enableError {
                    Text(enableError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            } footer: {
                Text("Off by default. Turning it on needs a voice server under Settings → Voice that passes Test connection. When on, \"Start meeting transcript\" appears in the pet's menu. It records your microphone as Me and one app's audio as Them, sends both to that server in chunks, and keeps the audio and transcript in ~/.ironpet/meetings. macOS asks for Screen & System Audio Recording the first time you start one. Tell everyone on the call.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Offer to record calls", isOn: Binding(
                    get: { meetings.offerToRecordCalls }, set: { on in store.update { $0.meetings.offerToRecordCalls = on } }))
                    .disabled(!meetings.enabled)
            } footer: {
                Text("When another app, such as WhatsApp, Zoom or a browser, uses your microphone for about 10 seconds, Ghost asks whether to record the call. Nothing is recorded until you click Record.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Summary") {
                Toggle("Summarize automatically when a meeting ends", isOn: Binding(
                    get: { meetings.autoSummary }, set: { on in store.update { $0.meetings.autoSummary = on } }))
                Picker("Summary agent", selection: Binding(get: { meetings.summaryAgent }, set: setAgent)) {
                    ForEach(agents) { agent in Text(agent.name).tag(agent.id) }
                }
                Picker("Summary model", selection: Binding(get: { meetings.summaryModel ?? "" },
                                                          set: { id in store.update { $0.meetings.summaryModel = id.isEmpty ? nil : id } })) {
                    Text("Default").tag("")
                    ForEach(modelChoices, id: \.id) { Text($0.name).tag($0.id) }
                }
                if models.isEmpty {
                    Text("The model list fills in after this agent has run once in the chat. Default uses the agent's own choice.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                ShortcutRow(title: "Start or stop", path: \.meeting, model: model)
            } footer: {
                Text("No shortcut is set by default, and none is registered while meeting transcripts are off. Pressing it starts the app picker, or stops a meeting that is recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                EmptyView()
            } footer: {
                Text("When a meeting ends, the transcript is sent to the summary agent, which only gets the meeting folder and has every permission request refused: it can read the transcript and answer, and it cannot change files or run commands. ironpet writes summary.md itself. The server, model and key are the ones under Voice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { installedAgents = await ACPProbe.installed() }
    }

    /// The model list plus the saved id, so a model that left the list still shows.
    private var modelChoices: [ChatModel] {
        var list = models
        if let saved = meetings.summaryModel, !list.contains(where: { $0.id == saved }) { list.append(ChatModel(id: saved, name: saved)) }
        return list
    }

    private func setAgent(_ agent: String) {
        // A model id from one agent means nothing to the other.
        store.update {
            if $0.meetings.summaryAgent != agent { $0.meetings.summaryModel = nil }
            $0.meetings.summaryAgent = agent
        }
    }

    /// Turning meetings on sends the voice settings' test clip first, so a wrong URL or key shows up here and not in
    /// the middle of a call.
    private func setEnabled(_ on: Bool) {
        guard on else {
            enableError = nil
            store.update { $0.meetings.enabled = false }
            return
        }
        let voice = store.config.voice
        let transcriber = Transcriber(baseURL: voice.baseUrl, model: voice.model, apiKey: VoiceKey.load(), timeout: 30)
        testing = true
        enableError = nil
        Task {
            do {
                _ = try await transcriber.transcribe(wav: VoiceSettings.testClip)
                store.update { $0.meetings.enabled = true }
            } catch {
                enableError = "Not turned on. The voice server failed Test connection: \(error.localizedDescription)"
            }
            testing = false
        }
    }
}

// MARK: - Integrations

struct IntegrationsSettings: View {
    let telegram: TelegramBridge
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        Form {
            IntegrationAccordion(
                title: "MCP sign-ins",
                status: .init(label: store.config.integrations.shareMCPSignIns ? "On" : "Off",
                              color: store.config.integrations.shareMCPSignIns ? .green : .secondary),
                isOn: Binding(
                    get: { store.config.integrations.shareMCPSignIns },
                    set: { on in
                        if on, !IntegrationsSettings.confirmMCPSharing() { return }
                        store.update { $0.integrations.shareMCPSignIns = on }
                    })
            ) {
                Text("cursor-agent stores MCP sign-ins per folder. With this on, your MCP OAuth tokens are copied into each folder you chat in, so you sign in once. Relies on an internal Cursor file format.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TelegramIntegration(bridge: telegram)
        }
        .formStyle(.grouped)
    }

    /// Asks before turning on MCP sign-in sharing, since it copies OAuth tokens. True to go ahead.
    @MainActor static func confirmMCPSharing() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Share MCP sign-ins across folders?"
        alert.informativeText = """
            cursor-agent stores MCP sign-ins per folder. With this on, before each chat ironpet copies your \
            signed-in MCP servers' OAuth tokens from ~/.cursor/projects/*/mcp-auth.json into the chat's folder, \
            so you only sign in once. The tokens stay on this Mac, but any folder you chat in gets them. This \
            relies on an internal Cursor file format.
            """
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
