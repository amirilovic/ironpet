import AppKit
import SwiftUI

/// The Automations tab: every reminder and watcher with a switch, when it runs next, and how its last run went.
struct AutomationsSettings: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var config = ConfigStore.shared

    var body: some View {
        if let service = model.automations {
            AutomationList(service: service, store: service.store, config: config, showLogs: model.showLogs, createWithAgent: model.createWithAgent)
        } else {
            Text("Automations are not ready yet.").foregroundStyle(.secondary)
        }
    }
}

private struct AutomationList: View {
    let service: AutomationService
    @ObservedObject var store: AutomationStore
    @ObservedObject var config: ConfigStore
    let showLogs: (String?) -> Void
    let createWithAgent: (String) -> Void
    @State private var asking = false
    @State private var editing: Automation?
    @State private var tick = 0

    var body: some View {
        Form {
            Section {
                Toggle("Pause all reminders", isOn: binding(\.paused))
            } footer: {
                Text("A reminder on keyboard time only counts while you're at the keyboard. While an agent is working it can come a little early so you take the break while you'd be waiting anyway. Agents can add and change automations; anything that runs a command or a prompt waits for your Approve first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Automations") {
                if store.automations.isEmpty { Text("None yet. Ask an agent, or add one.").foregroundStyle(.secondary) }
                ForEach(store.automations) { automation in row(automation) }
                HStack {
                    Button("New automation…") { asking = true }
                    Button("Show logs") { showLogs(nil) }
                    Button("Open automations.json") { NSWorkspace.shared.open(store.paths.file) }
                    Spacer()
                }
            }
            Section {
                Toggle("Ask the agent to fix automations that fail", isOn: Binding(
                    get: { config.config.automations.autoFix },
                    set: { on in config.update { $0.automations.autoFix = on } }))
            } footer: {
                Text("When a poll, script, shell command or prompt fails, ironpet sends the error to a new chat and asks your agent to fix it with the automation tools. Changes to a command, script or prompt still wait for your Approve. At most one request per automation every 6 hours, and only after it has run fine since the last one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Timing") {
                LabeledContent("Reset after being away") { minutes(binding(\.idleResetMinutes), range: 1...60) }
                LabeledContent("Snooze for") { minutes(binding(\.snoozeMinutes), range: 1...120) }
                LabeledContent("Keep logs for") {
                    Stepper(value: Binding(get: { config.config.automations.logRetentionDays },
                                           set: { days in config.update { $0.automations.logRetentionDays = days } }), in: 1...365, step: 1) {
                        Text("\(config.config.automations.logRetentionDays) day\(config.config.automations.logRetentionDays == 1 ? "" : "s")")
                            .monospacedDigit().frame(minWidth: 56, alignment: .trailing)
                    }
                    .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $asking) { NewAutomationSheet { text in asking = false; if let text { createWithAgent(text) } } }
        .sheet(item: $editing) { automation in EditSheet(service: service, automation: automation) { editing = nil } }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in tick += 1 }
    }

    private func row(_ a: Automation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(a.name, isOn: Binding(get: { a.enabled }, set: { on in try? store.update(a.id) { $0.enabled = on } }))
                .labelsHidden().toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.name)
                Text(subtitle(a)).font(.caption).foregroundStyle(.secondary)
                if let last = service.lastRun(a.id) {
                    Text("Last: \(last.outcome)\(last.output.isEmpty ? "" : ", \(last.output)")")
                        .font(.caption).foregroundStyle(last.outcome == "failed" ? Color.red : Color.secondary).lineLimit(2)
                }
                if let hint = setupHint(a) {
                    Label(hint, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                }
                if service.needsApproval(a) {
                    Label("Waiting for your approval", systemImage: "hand.raised.fill").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Menu {
                Button("Show logs…") { showLogs(a.id) }
                Button("Run now") { Task { _ = await service.call("run_now", ["id": a.id], by: "user") } }
                Button("Edit…") { editing = a }
                Divider()
                Button("Delete", role: .destructive) { try? store.replace(store.automations.filter { $0.id != a.id }) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .id("\(a.id)-\(tick)")
    }

    /// What a default alert needs before it can report anything.
    private func setupHint(_ a: Automation) -> String? {
        guard a.enabled else { return nil }
        switch a.id {
        case AutomationDefaults.githubID: return AutomationDefaults.ghExecutable == nil ? "Needs the GitHub CLI: brew install gh, then gh auth login." : nil
        case AutomationDefaults.sentryID: return AutomationDefaults.sentryConfigured ? nil : "Not set up yet. Run ./scripts/configure_sentry.sh, which keeps the token in your Keychain."
        default: return nil
        }
    }

    private func subtitle(_ a: Automation) -> String {
        var text = service.describe(a.trigger)
        if a.enabled, let next = service.engine.nextRun(a) {
            text += " · next " + (a.trigger.type == "interval" && a.trigger.clock != "wall" ? "after about " : "") + Self.relative.localizedString(for: next, relativeTo: Date())
        }
        if a.createdBy != "user" { text += " · by \(a.createdBy)" }
        return text
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func binding<T>(_ path: WritableKeyPath<Config.Reminders, T>) -> Binding<T> {
        Binding(get: { config.config.reminders[keyPath: path] }, set: { value in config.update { $0.reminders[keyPath: path] = value } })
    }

    private func minutes(_ value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        Stepper(value: value, in: range, step: 5) {
            Text("\(Int(value.wrappedValue)) min").monospacedDigit().frame(minWidth: 56, alignment: .trailing)
        }
        .fixedSize()
    }
}

private struct EditSheet: View {
    let service: AutomationService
    let automation: Automation
    let done: () -> Void
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit \(automation.name)").font(.headline)
            Text("The automation as JSON. Fields are described in automations.schema.json next to automations.json.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 260)
                .border(Color.secondary.opacity(0.3))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: done)
                Button("Save") {
                    if let problem = service.saveEdited(id: automation.id, json: text) { error = problem } else { done() }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear { text = service.json(for: automation) }
    }
}

/// The box behind "New automation…": the user says what they want, and the message goes to the chat for the agent to build it.
private struct NewAutomationSheet: View {
    let done: (String?) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What kind of automation do you want?").font(.headline)
            Text("Say it in your own words. Your agent creates it with the automation tools and tells you what it made. For example: remind me to stretch every 45 minutes, tell me when CI fails on one of my PRs, or every weekday at 17:30 ask the agent to summarize what I changed today.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                Button("Ask the agent") { done(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}
