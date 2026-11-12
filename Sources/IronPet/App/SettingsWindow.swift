import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the settings window needs from the rest of the app, beyond `ConfigStore`.
@MainActor
final class SettingsModel: ObservableObject {
    struct Actions {
        /// Global hotkeys are paused while a shortcut is being recorded, so pressing the current one records it.
        var suspendHotKeys: (Bool) -> Void
    }

    let actions: Actions
    /// Shortcut config strings that failed to register (taken by another app or invalid).
    @Published var failedHotKeys: Set<String> = []
    @Published var launchAtLogin = LoginItem.isEnabled
    private let announcer: Announcer

    init(actions: Actions, announcer: Announcer) {
        self.actions = actions
        self.announcer = announcer
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

    func show() {
        model.refresh()
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "ironpet Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }
                RemindersSettings().tabItem { Label("Reminders", systemImage: "drop") }
                IntegrationsSettings().tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
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
        .frame(width: 520, height: 600)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var store = ConfigStore.shared
    @State private var name = ConfigStore.shared.config.pet.name
    @State private var spriteError: String?

    var body: some View {
        Form {
            Section("Pet") {
                TextField("Name", text: $name)
                    .onSubmit(saveName)
                    .onChange(of: name) { saveName() }
                    .onChange(of: store.config.pet.name) { if store.config.pet.name != name { name = store.config.pet.name } }
                LabeledContent("Sprite sheet") {
                    HStack {
                        Text(store.config.pet.sprite.map { ($0 as NSString).lastPathComponent } ?? "Default")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseSprite)
                        if store.config.pet.sprite != nil {
                            Button("Reset") { store.update { $0.pet.sprite = nil } }
                        }
                    }
                }
                if let spriteError {
                    Text(spriteError).font(.caption).foregroundStyle(.red)
                } else {
                    Text("A PNG or WebP in the Codex pet v2 layout: 1536 px wide, 8 columns of 192×208 cells.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                Toggle("Watch Cursor", isOn: Binding(get: { store.config.integrations.cursorHooks },
                                                     set: { on in store.update { $0.integrations.cursorHooks = on } }))
                Toggle("Watch Claude Code", isOn: Binding(get: { store.config.integrations.claudeHooks },
                                                          set: { on in store.update { $0.integrations.claudeHooks = on } }))
            } header: {
                Text("Agents")
            } footer: {
                Text("Adds hooks to ~/.cursor/hooks.json and ~/.claude/settings.json so \(store.config.pet.name) sees your agents. Chatting through a backend needs its hooks too: that's how every edit and command waits for Allow / Deny. Turning one off removes only ironpet's hooks; the original file is backed up as *.ironpet-backup the first time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

    private func chooseSprite() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .webP]
        panel.directoryURL = Paths.petDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              Atlas(image: image) != nil else {
            spriteError = "\(url.lastPathComponent) isn't a sprite sheet in the expected layout."
            return
        }
        spriteError = nil
        let path = url.path.replacingOccurrences(of: Paths.home.path, with: "~", options: .anchored)
        store.update { $0.pet.sprite = path }
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
            let others = [\Config.Hotkeys.chat, \.captureWindow, \.captureRegion].filter { $0 != path }
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

// MARK: - Reminders

private struct RemindersSettings: View {
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Pause all reminders", isOn: binding(\.paused))
            } footer: {
                Text("Time only counts while you're at the keyboard. While an agent is working, a reminder can come a little early so you take the break while you'd be waiting anyway.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Reminders") {
                ForEach(ReminderScheduler.Kind.allCases, id: \.self) { kind in
                    LabeledContent(kind.name) {
                        HStack(spacing: 12) {
                            minutes(binding(kind.configPath.appending(path: \.minutes)), range: 1...240)
                            Toggle(kind.name, isOn: binding(kind.configPath.appending(path: \.enabled)))
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                    }
                }
            }
            Section("Timing") {
                LabeledContent("Reset after being away") { minutes(binding(\.idleResetMinutes), range: 1...60) }
                LabeledContent("Snooze for") { minutes(binding(\.snoozeMinutes), range: 1...120) }
            }
        }
        .formStyle(.grouped)
    }

    private func binding<T>(_ path: WritableKeyPath<Config.Reminders, T>) -> Binding<T> {
        Binding(get: { store.config.reminders[keyPath: path] },
                set: { value in store.update { $0.reminders[keyPath: path] = value } })
    }

    private func minutes(_ value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        Stepper(value: value, in: range, step: 5) {
            Text("\(Int(value.wrappedValue)) min").monospacedDigit().frame(minWidth: 56, alignment: .trailing)
        }
        .fixedSize()
    }
}

// MARK: - Integrations

struct IntegrationsSettings: View {
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("GitHub PR & CI alerts", isOn: Binding(
                    get: { store.config.integrations.githubAlerts },
                    set: { on in store.update { $0.integrations.githubAlerts = on } }))
                    .disabled(GitHubWatcher.ghExecutable == nil && !store.config.integrations.githubAlerts)
            } footer: {
                Text(GitHubWatcher.ghExecutable == nil
                     ? "Needs the GitHub CLI: brew install gh, then gh auth login."
                     : "Polls every 2 minutes, on every host `gh` is logged in to: CI on your PRs, approvals, changes requested, review requests.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Share MCP sign-ins across folders", isOn: Binding(
                    get: { store.config.integrations.shareMCPSignIns },
                    set: { on in
                        if on, !IntegrationsSettings.confirmMCPSharing() { return }
                        store.update { $0.integrations.shareMCPSignIns = on }
                    }))
            } footer: {
                Text("cursor-agent stores MCP sign-ins per folder. With this on, your MCP OAuth tokens are copied into each folder you chat in, so you sign in once. Relies on an internal Cursor file format.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Sentry alerts") {
                    Text(SentryWatcher.config.map { "On (\($0.org))" } ?? "Off").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Turn on or change with ./scripts/configure_sentry.sh, which keeps the auth token in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
