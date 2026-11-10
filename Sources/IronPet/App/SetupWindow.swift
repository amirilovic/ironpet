import AppKit
import SwiftUI

/// The one-time welcome window. Nothing outside `~/.ironpet` is touched until the user presses Start, and only what
/// they ticked: agent hooks, launch at login, reminders, GitHub alerts.
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    struct Choices {
        var name: String
        var agents: [HookInstaller.Agent]
        var launchAtLogin: Bool
        var reminders: Bool
        var githubAlerts: Bool
    }

    private static let completedKey = "setupCompleted"

    /// First launch: setup hasn't been finished or skipped, and there's no config.json (one brought along from
    /// another Mac counts as already set up).
    static var isNeeded: Bool {
        !UserDefaults.standard.bool(forKey: completedKey) && !FileManager.default.fileExists(atPath: Config.file.path)
    }

    private var window: NSWindow?
    private let onFinish: (Choices?) -> Void

    /// `onFinish` gets the choices from Start, or nil for Not now / closing the window.
    init(onFinish: @escaping (Choices?) -> Void) {
        self.onFinish = onFinish
    }

    func show() {
        let view = SetupView(installer: HookInstaller()) { [weak self] choices in self?.finish(choices) }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to ironpet"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard window != nil else { return }
        window = nil
        complete(nil)
    }

    private func finish(_ choices: Choices?) {
        let window = self.window
        self.window = nil
        window?.close()
        complete(choices)
    }

    private func complete(_ choices: Choices?) {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        onFinish(choices)
    }
}

private struct SetupView: View {
    let installer: HookInstaller
    let finish: (SetupWindow.Choices?) -> Void

    @State private var name = ConfigStore.shared.config.pet.name
    @State private var agents: Set<HookInstaller.Agent>
    @State private var launchAtLogin = true
    @State private var reminders = true
    @State private var githubAlerts = false

    private let present: Set<HookInstaller.Agent>
    private let hasChatCLI = CursorAgentBackend.executable() != nil || ClaudeCodeBackend.executable() != nil
    private let hasGitHubCLI = GitHubWatcher.ghExecutable != nil

    init(installer: HookInstaller, finish: @escaping (SetupWindow.Choices?) -> Void) {
        self.installer = installer
        self.finish = finish
        let present = Set(HookInstaller.Agent.allCases.filter { $0.isPresent || installer.isInstalled($0) })
        self.present = present
        _agents = State(initialValue: present)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                PetAvatar(size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hi, I'm \(displayName).").font(.title2.weight(.semibold))
                    Text("I sit on top of your windows, keep an eye on your coding agents, and help when you ask. Pick what I'm allowed to do; you can change any of it later in Settings (⌘,).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)

            Form {
                Section("Your pet") {
                    TextField("Name", text: $name)
                }
                Section {
                    ForEach(HookInstaller.Agent.allCases, id: \.self) { agent in
                        Toggle(isOn: binding(agent)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.displayName + (present.contains(agent) ? "" : " (not found)"))
                                Text("Adds hooks to \(tilde(agent.configFile)) (backed up first). Also needed to chat with me through \(agent.displayName), so I can ask before editing or running anything.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Watch my agents")
                } footer: {
                    if !hasChatCLI {
                        Label("To chat, install cursor-agent or Claude Code (claude) and sign in.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("Extras") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                    Toggle(isOn: $reminders) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Break reminders")
                            Text("Water, stretching and eye breaks, counted only while you're at the keyboard.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $githubAlerts) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("GitHub PR & CI alerts")
                            Text(hasGitHubCLI ? "Uses your gh CLI login; polls every 2 minutes."
                                              : "Needs the GitHub CLI (brew install gh, then gh auth login).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!hasGitHubCLI)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Text("Your chats and notes stay on this Mac in ~/.ironpet.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Not now") { finish(nil) }
                    .accessibilityIdentifier("setup.notNow")
                Button("Start") {
                    finish(.init(name: displayName, agents: HookInstaller.Agent.allCases.filter(agents.contains),
                                 launchAtLogin: launchAtLogin, reminders: reminders, githubAlerts: githubAlerts))
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setup.start")
            }
            .padding(20)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Config.Pet().name : trimmed
    }

    private func binding(_ agent: HookInstaller.Agent) -> Binding<Bool> {
        Binding(get: { agents.contains(agent) },
                set: { on in if on { agents.insert(agent) } else { agents.remove(agent) } })
    }

    private func tilde(_ url: URL) -> String {
        url.path.replacingOccurrences(of: Paths.home.path, with: "~", options: .anchored)
    }
}
