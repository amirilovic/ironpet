import AppKit
import SwiftUI

/// Settings → Screen: the master switch for screen capture and everything that goes with it.
struct ScreenSettings: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var store = ConfigStore.shared
    @State private var installedAgents: [ACPAgent] = []
    @State private var testing = false
    @State private var seen: [(bundleId: String, name: String, items: Int)] = []

    private var capture: Config.ScreenCapture { store.config.screenCapture }

    var body: some View {
        if let service = model.capture {
            content(service)
        } else {
            Form { Text("Screen capture is not available.").foregroundStyle(.secondary) }.formStyle(.grouped)
        }
    }

    private func content(_ service: CaptureService) -> some View {
        ScreenSettingsBody(service: service, settings: model, model: service.model, installedAgents: $installedAgents, testing: $testing, seen: $seen)
            .formStyle(.grouped)
            .task { installedAgents = await ACPProbe.installed() }
    }
}

private struct ScreenSettingsBody: View {
    let service: CaptureService
    let settings: SettingsModel
    @ObservedObject var model: CaptureStatusModel
    @ObservedObject private var store = ConfigStore.shared
    @Binding var installedAgents: [ACPAgent]
    @Binding var testing: Bool
    @Binding var seen: [(bundleId: String, name: String, items: Int)]

    private var capture: Config.ScreenCapture { store.config.screenCapture }

    private func update(_ change: @escaping (inout Config.ScreenCapture) -> Void) { store.update { change(&$0.screenCapture) } }

    private var agents: [ACPAgent] {
        var list = installedAgents
        if !list.contains(where: { $0.id == capture.agent }), let saved = AgentCatalog.agent(id: capture.agent) { list.append(saved) }
        return list
    }

    private var models: [ChatModel] {
        var list = AgentCatalog.agent(id: capture.agent).map(ChatSession.cachedModels(for:)) ?? []
        if let saved = capture.model, !list.contains(where: { $0.id == saved }) { list.append(ChatModel(id: saved, name: saved)) }
        return list
    }

    var body: some View {
        Form {
            masterSection
            if capture.enabled {
                statusSection
                decisionSection
                thresholdsSection
                agentSection
                appsSection
                excludeSection
                dataSection
            }
        }
        .onAppear { service.refreshModel(); seen = service.store.seenApps() }
    }

    // MARK: Master switch

    private var masterSection: some View {
        Section {
            Toggle("Screen capture", isOn: Binding(get: { capture.enabled }, set: { on in update { $0.enabled = on } }))
        } footer: {
            Text("Off by default. When on, ironpet reads the text of the window you are using through Accessibility, with rules that know how to read chats and documents, and keeps it in ~/.ironpet/ironpet.db on this Mac. Secrets that rules recognise (keys, tokens, passwords, credentials in URLs) are replaced by [redacted:…] before the text is stored. A model on this Mac then filters it. After a delay, captures from apps you allow below go to your chosen agent, which looks up your tasks and suggests what needs your action. Nothing is added without a click. Password managers, secure fields, private browser windows and local files are never captured. When off, nothing is read, no model runs and macOS shows no permission prompt.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Accessibility") {
                if model.accessibility {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Allow in System Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
            LabeledContent("Screen Recording") {
                if model.screenRecording {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Allow…") { ScreenCapture.requestPermission() }
                }
            }
            if !model.screenRecording {
                Text("Optional. Only Viber needs it, to read the chat name from the window header on the device. Without it all Viber chats share one thread.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.paused, let until = model.pausedUntil {
                LabeledContent("Capture") { Text("Paused until \(until.formatted(date: .omitted, time: .shortened))") }
            } else {
                LabeledContent("Capture") { Text(model.running ? "Running" : "Starting…") }
            }
            HStack {
                Button("Pause 15 min") { pause(15 * 60) }
                Button("Pause 1 hour") { pause(3600) }
                Button("Until tomorrow") { service.privacy.pauseUntilTomorrow(); service.refreshModel() }
                Button("Resume") { service.privacy.resume(); service.refreshModel() }.disabled(!model.paused)
            }
            HStack {
                Text("Activity and send history are in the main window under Screen.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Screen") { settings.showScreenSection() }
            }
            if let skip = model.lastSkip {
                LabeledContent("Last skipped") { Text(skip).foregroundStyle(.secondary) }
            }
        }
    }

    private func pause(_ seconds: TimeInterval) {
        service.privacy.pause(for: seconds)
        service.refreshModel()
    }

    // MARK: Decision model

    private var decisionSection: some View {
        Section {
            Toggle("Filter with a local model", isOn: Binding(get: { capture.decision.enabled }, set: { v in update { $0.decision.enabled = v } }))
            if !capture.decision.enabled {
                Label("Only rule-based redaction runs before captures are sent to the agent.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Group {
            Picker("API", selection: Binding(get: { capture.decision.api }, set: { v in update { $0.decision.api = v } })) {
                Text("H2O-Lightning (/v1/systemone)").tag("systemone")
                Text("OpenAI-compatible chat").tag("openai")
            }
            TextField("Base URL", text: Binding(get: { capture.decision.baseUrl }, set: { v in update { $0.decision.baseUrl = v } }), prompt: Text("http://127.0.0.1:8741"))
            TextField("Model", text: Binding(get: { capture.decision.model }, set: { v in update { $0.decision.model = v } }))
            HStack {
                Button("Test") {
                    testing = true
                    Task { await service.testDecisionModel(); testing = false }
                }.disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                decisionStatus
            }
            }.disabled(!capture.decision.enabled)
        } header: {
            Text("Local decision model")
        } footer: {
            Text("Rules redact the secrets they know first, so a key in a useful message is sent as [redacted:aws-key] and the rest of the message still goes. A model on this Mac, such as H2O-Lightning-4B, then scores the redacted text. An item it flags at or above the secret threshold stays on this Mac and its text is dropped. The unredacted text of an item that had a secret is kept for 24 hours so you can look at it under Screen, Captures, and is never sent. The address must be localhost. If no model is set or it does not answer, nothing is sent to the agent. With the filter off, none of this applies.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var thresholdsSection: some View {
        Section {
            thresholdRow("Secret", \.secretThreshold, "Kept on this Mac when the model's secret score is at or above this. Lower is stricter.")
            thresholdRow("Calendar", \.calendarThreshold, "A calendar score at or above this keeps an item in play as a calendar candidate.")
            thresholdRow("Skip", \.skipThreshold, "Items whose follow-up and new-task scores are both below this are not sent. 0 sends everything that passes.")
            Button("Reset to defaults") {
                let defaults = Config.ScreenCapture.Decision()
                update {
                    $0.decision.secretThreshold = defaults.secretThreshold
                    $0.decision.calendarThreshold = defaults.calendarThreshold
                    $0.decision.skipThreshold = defaults.skipThreshold
                }
            }
        } header: {
            Text("Decision thresholds")
        }
        .disabled(!capture.decision.enabled)
    }

    private func thresholdRow(_ title: String, _ key: WritableKeyPath<Config.ScreenCapture.Decision, Double>, _ help: String) -> some View {
        let value = Binding(get: { capture.decision[keyPath: key] }, set: { v in update { $0.decision[keyPath: key] = min(1, max(0, v)) } })
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Slider(value: value, in: 0...1, step: 0.05)
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2)))).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var decisionStatus: some View {
        switch model.decision {
        case .off:
            Text("Off").font(.caption).foregroundStyle(.secondary)
        case .unknown:
            Text("Not tested").font(.caption).foregroundStyle(.secondary)
        case .ready(let name):
            Label("Ready: \(name)", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .unavailable(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        }
    }

    // MARK: Agent

    private var agentSection: some View {
        Section {
            Picker("Agent", selection: Binding(get: { capture.agent }, set: { id in
                update { if $0.agent != id { $0.model = nil }; $0.agent = id }
            })) {
                ForEach(agents) { Text($0.name).tag($0.id) }
            }
            Picker("Model", selection: Binding(get: { capture.model ?? "" }, set: { id in update { $0.model = id.isEmpty ? nil : id } })) {
                Text("Default").tag("")
                ForEach(models, id: \.id) { Text($0.name).tag($0.id) }
            }
            Stepper(value: Binding(get: { capture.delayMinutes }, set: { v in update { $0.delayMinutes = v } }), in: 0.5...240, step: 0.5) {
                Text("Delay: \(capture.delayMinutes.formatted()) min of quiet before sending")
            }
            if let next = model.nextSend {
                LabeledContent("Next send") { Text(next.formatted(date: .omitted, time: .shortened)) }
            }
        } header: {
            Text("Larger model")
        } footer: {
            Text("The agent can only look up your tasks (read-only), and every other permission request is refused. It runs in its own folder, so your chat session and folder do not change. Captures that wait for the delay are grouped by conversation or document.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Apps

    private var appsSection: some View {
        Section {
            let rows = appRows
            if rows.isEmpty {
                Text("No apps captured yet. Apps appear here once ironpet has read them.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.bundleId) { row in
                Toggle(isOn: Binding(get: { capture.sendApps.contains(row.bundleId) }, set: { on in
                    update {
                        $0.sendApps.removeAll { $0 == row.bundleId }
                        if on { $0.sendApps.append(row.bundleId) }
                    }
                })) {
                    VStack(alignment: .leading) {
                        Text(row.name)
                        Text("\(row.bundleId), \(row.items) \(row.items == 1 ? "item" : "items")").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Allowed to send")
        } footer: {
            Text("Only captures from apps ticked here can go to the agent. None are ticked by default. Capture and the local filter work for every app either way.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var appRows: [(bundleId: String, name: String, items: Int)] {
        var rows = seen
        for id in capture.sendApps where !rows.contains(where: { $0.bundleId == id }) { rows.append((id, id, 0)) }
        return rows
    }

    // MARK: Never capture

    @State private var excludeText = ""

    private var excludeSection: some View {
        Section {
            if capture.excludedApps.isEmpty {
                Text("No apps excluded.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(capture.excludedApps, id: \.self) { entry in
                HStack {
                    Text(displayName(entry))
                    Spacer()
                    Button { update { $0.excludedApps.removeAll { $0 == entry } } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Capture this app again")
                }
            }
            HStack {
                Menu("Add app") {
                    ForEach(excludableApps, id: \.bundleId) { app in
                        Button(app.name) { exclude(app.bundleId) }
                    }
                }
                .disabled(excludableApps.isEmpty)
                TextField("Bundle id or app name", text: $excludeText).onSubmit(addTyped)
                Button("Add", action: addTyped).disabled(excludeText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Never capture")
        } footer: {
            Text("These apps are not read at all, so nothing from them is stored or sent. Password managers, authenticator apps and private browser windows are always excluded and do not need to be listed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Running apps and apps already captured that are not excluded yet, by name.
    private var excludableApps: [(bundleId: String, name: String)] {
        var found: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier { found[id] = app.localizedName ?? id }
        }
        for app in seen { found[app.bundleId] = app.name }
        found[Bundle.main.bundleIdentifier ?? ""] = nil
        return found.filter { !capture.excludedApps.contains($0.key) }.map { (bundleId: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func displayName(_ entry: String) -> String {
        let name = seen.first { $0.bundleId == entry }?.name
            ?? NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == entry }?.localizedName
        return name.map { "\($0) (\(entry))" } ?? entry
    }

    private func exclude(_ entry: String) {
        let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        update { if !$0.excludedApps.contains(value) { $0.excludedApps.append(value) } }
    }

    private func addTyped() {
        exclude(excludeText)
        excludeText = ""
    }

    // MARK: Data and rules

    private var dataSection: some View {
        Section {
            Stepper(value: Binding(get: { capture.retentionDays }, set: { v in update { $0.retentionDays = v } }), in: 1...365) {
                Text("Keep captures for \(capture.retentionDays) days")
            }
            HStack {
                Button("Delete all captures") {
                    service.store.clearCaptures()
                    service.refreshModel()
                    seen = []
                }
                Spacer()
                Button("Open rules folder") {
                    try? FileManager.default.createDirectory(at: CaptureService.rulesFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(CaptureService.rulesFolder)
                }
                Button("Reload rules") { service.reloadRules() }
            }
            let broken = model.rules.filter { $0.status == .error }
            Text("\(model.rules.filter { $0.status == .active }.count) rules active" + (broken.isEmpty ? "" : ", \(broken.count) with errors: " + broken.map(\.name).joined(separator: ", ")))
                .font(.caption).foregroundStyle(broken.isEmpty ? Color.secondary : Color.orange)
        } header: {
            Text("Data and rules")
        } footer: {
            Text("A file in ~/.ironpet/capture/rules replaces the bundled rule of the same name. Rules can only capture less than the built-in privacy floor allows.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
