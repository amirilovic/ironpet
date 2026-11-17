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
    @State private var reviewing: Automation?
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
                Toggle("Auto-approve automation changes", isOn: Binding(
                    get: { config.config.automations.autoApprove },
                    set: { on in
                        config.update { $0.automations.autoApprove = on }
                        if on { service.reviewApprovals() }
                    }))
            } footer: {
                Text("Agent-written scripts can run shell commands without review.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Ask the agent to fix automations that fail", isOn: Binding(
                    get: { config.config.automations.autoFix },
                    set: { on in config.update { $0.automations.autoFix = on } }))
            } footer: {
                Text("When a poll, script, shell command or prompt fails, ironpet sends the error to the current chat and asks your agent to fix it with the automation tools. Changes to a command, script or prompt still wait for your Approve. At most one request per automation every 6 hours, and only after it has run fine since the last one.")
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
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $asking) { NewAutomationSheet { text in asking = false; if let text { createWithAgent(text) } } }
        .sheet(item: $reviewing) { automation in ReviewSheet(service: service, opened: automation) { reviewing = nil } }
        .sheet(item: $editing) { automation in EditSheet(service: service, automation: automation) { editing = nil } }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in tick += 1 }
    }

    private func row(_ a: Automation) -> some View {
        // The next run, last run and approval state live in the service, not in observed state, so `tick` redraws the
        // row every 5 s. It must not become the row's id: that rebuilds the time picker and drops its focus mid-edit.
        let _ = tick
        return HStack(alignment: .top, spacing: 10) {
            Toggle(a.name, isOn: Binding(get: { a.enabled }, set: { on in try? store.update(a.id) { $0.enabled = on } }))
                .labelsHidden().toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.name)
                Text(subtitle(a)).font(.caption).foregroundStyle(.secondary)
                if DailySchedule.time(of: a.trigger) != nil { schedule(a) }
                if let last = service.lastRun(a.id) {
                    Text("Last: \(last.outcome)\(last.output.isEmpty ? "" : ", \(last.output)")")
                        .font(.caption).foregroundStyle(last.outcome == "failed" ? Color.red : Color.secondary).lineLimit(2)
                }
                if let hint = setupHint(a) {
                    Label(hint, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                }
                if service.needsApproval(a) {
                    let rejected = service.isRejected(a)
                    Label(rejected ? "Rejected" : "Waiting for your approval", systemImage: rejected ? "xmark.circle.fill" : "hand.raised.fill")
                        .font(.caption).foregroundStyle(rejected ? Color.red : Color.orange)
                    HStack(spacing: 6) {
                        Button("Review…") { reviewing = a }
                        Button("Approve") { service.approve(a.id); tick += 1 }.buttonStyle(.borderedProminent)
                        if !rejected { Button("Reject") { service.reject(a.id); tick += 1 } }
                    }
                    .controlSize(.small).padding(.top, 2)
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
    }

    /// The time of a daily automation with one time, and Weekdays only when its days are every day or Monday to Friday.
    private func schedule(_ a: Automation) -> some View {
        HStack(spacing: 12) {
            DatePicker("Time", selection: Binding(
                get: { DailySchedule.time(of: a.trigger) ?? Date() },
                set: { date in try? store.update(a.id) { $0.trigger.times = [DailySchedule.format(date)] } }),
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .accessibilityLabel("\(a.name) time")
            if let weekdaysOnly = DailySchedule.weekdaysOnly(a.trigger) {
                Toggle("Weekdays only", isOn: Binding(
                    get: { weekdaysOnly },
                    set: { on in try? store.update(a.id) { $0.trigger.weekdays = DailySchedule.weekdays(only: on) } }))
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("\(a.name) weekdays only")
            }
        }
        .controlSize(.small)
        .padding(.top, 2)
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
        if a.trigger.type == "stream", a.enabled {
            text += " · " + service.engine.streams.status(a.id).rawValue
            if let last = service.engine.streams.lastEvent(a.id) { text += ", last event " + Self.relative.localizedString(for: last, relativeTo: Date()) }
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

/// Shows what an automation would run, so the user reads it before pressing Approve.
private struct ReviewSheet: View {
    let service: AutomationService
    let opened: Automation
    let done: () -> Void

    /// The stored automation, so an edit made while the sheet is open is what the user reads and approves.
    private var automation: Automation { service.store.automations.first { $0.id == opened.id } ?? opened }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow \(automation.name)?").font(.headline)
            Text("Created by \(automation.createdBy). It wants to run this \(automation.action.type == "prompt" ? "prompt" : "command"):")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(service.approvalDetail(automation))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            .frame(minHeight: 180, maxHeight: 360)
            .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Close", action: done)
                if !service.isRejected(automation) { Button("Reject") { service.reject(automation.id); done() } }
                Button("Approve") { service.approve(automation.id); done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
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

/// The inline schedule editor's mapping between a daily trigger and the time picker.
enum DailySchedule {
    /// Today at the trigger's time, for a daily trigger with exactly one valid time. Nil hides the picker.
    static func time(of trigger: Automation.Trigger, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard trigger.type == "daily", let times = trigger.times, times.count == 1,
              let minutes = AutomationClock.minutes(of: times[0]) else { return nil }
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: now)
    }

    /// "09:05".
    static func format(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// True for Monday to Friday, false for every day, nil for any other set of days, which the toggle would lose.
    static func weekdaysOnly(_ trigger: Automation.Trigger) -> Bool? {
        guard let days = trigger.weekdays else { return false }
        if Set(days) == Set(AutomationDefaults.weekdays) { return true }
        if Set(days) == Set(AutomationValidator.weekdays) { return false }
        return nil
    }

    static func weekdays(only: Bool) -> [String]? { only ? AutomationDefaults.weekdays : nil }
}
