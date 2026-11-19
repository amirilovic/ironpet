import AppKit
import SwiftUI

/// Settings → Screen: the master switch for screen capture and everything that goes with it.
struct ScreenSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let service = model.capture {
            ScreenSettingsBody(service: service, settings: model, model: service.model).formStyle(.grouped)
        } else {
            Form { Text("Screen capture is not available.").foregroundStyle(.secondary) }.formStyle(.grouped)
        }
    }
}

private struct ScreenSettingsBody: View {
    let service: CaptureService
    let settings: SettingsModel
    @ObservedObject var model: CaptureStatusModel
    @ObservedObject private var store = SettingsAPI.live
    @State private var seen: [(bundleId: String, name: String, captures: Int)] = []
    @State private var excludeText = ""

    private var capture: Config.ScreenCapture { store.config.screenCapture }

    private func update(_ change: @escaping (inout Config.ScreenCapture) -> Void) { store.update { change(&$0.screenCapture) } }

    var body: some View {
        Form {
            masterSection
            if capture.enabled {
                statusSection
                ocrSection
                excludeSection
                dataSection
            }
            DesktopControlSections(settings: settings)
        }
        .onAppear { service.refreshModel(); seen = service.store.seenApps() }
    }

    // MARK: Master switch

    private var masterSection: some View {
        Section {
            Toggle("Screen capture", isOn: Binding(get: { capture.enabled }, set: { on in update { $0.enabled = on } }))
        } footer: {
            Text("Off by default. When on, ironpet reads the text of the window you are using through Accessibility, with no rules for particular apps, and keeps what changed in ~/.ironpet/ironpet.db on this Mac. Keys, tokens and passwords are replaced by [redacted:…] before the text is stored, and password fields are never read. Agents you run in ironpet can search it with the screen_search and screen_window tools. Nothing leaves this Mac otherwise. Password managers and private browser windows are never captured. When off, nothing is read and macOS shows no permission prompt.")
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
                Text("Recent captures and search are in the main window under Screen.").font(.caption).foregroundStyle(.secondary)
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

    // MARK: Screenshot fallback

    private var ocrSection: some View {
        Section {
            Toggle("Read windows that have no text from a screenshot", isOn: Binding(get: { capture.ocr }, set: { on in update { $0.ocr = on } }))
            if capture.ocr {
                LabeledContent("Screen Recording") {
                    if model.screenRecording {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") { ScreenCapture.requestPermission() }
                    }
                }
            }
        } header: {
            Text("Screenshot fallback")
        } footer: {
            Text("Some windows (a canvas, a remote desktop, a game) expose no text to Accessibility. With this on, ironpet takes a screenshot of that window, reads its text with Apple Vision on this Mac, and drops the image. The image is never saved to disk. Turning this on asks macOS for Screen Recording permission. With it off, such windows are skipped.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Never capture

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
            Text("These apps are not read at all. Password managers, authenticator apps and private browser windows are always excluded and do not need to be listed.")
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

    // MARK: Data

    private var dataSection: some View {
        Section {
            Stepper(value: Binding(get: { capture.retentionDays }, set: { v in update { $0.retentionDays = v } }), in: 1...365) {
                Text("Keep captures for \(capture.retentionDays) days")
            }
            HStack {
                Text("\(model.captureCount) \(model.captureCount == 1 ? "capture" : "captures") stored").foregroundStyle(.secondary)
                Spacer()
                Button("Delete all captures") {
                    service.store.clear()
                    service.refreshModel()
                    seen = []
                }
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Older captures are deleted automatically.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Settings → Screen → Desktop control: the switch for the `desktop_*` tools and the list of what agents did with them.
struct DesktopControlSections: View {
    let settings: SettingsModel
    @ObservedObject private var store = SettingsAPI.live
    @State private var log: [ActivityEvent] = []

    var body: some View {
        Group {
            Section {
                Toggle("Desktop control", isOn: Binding(get: { store.config.desktopControl.enabled }, set: { on in
                    store.update { $0.desktopControl.enabled = on }
                    if on { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
                }))
            } footer: {
                Text("Off by default. When on, agents you run in ironpet can read and operate other apps through Accessibility with the desktop_* tools, using the Accessibility access ironpet has. They press buttons, set text, pick options, tick boxes, expand rows and focus elements, open web addresses, and can press keys in one app. They send no mouse events. Password fields, password managers, the apps you excluded from screen capture and private browser windows are never read or operated, and nothing works while capture is paused. An action on an element or window that says send, pay, delete, submit or buy waits for your Approve. So does a key press of Cmd+Return, Cmd+Q or Cmd+W, or of Return or a Cmd combo in such a window. A window picture needs Screen Recording access.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.config.desktopControl.enabled {
                Section("Recent actions") {
                    if log.isEmpty { Text("Nothing yet.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(log.prefix(20).enumerated()), id: \.offset) { _, event in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(event.title).lineLimit(1)
                                Spacer()
                                Text(event.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(DesktopLogText.line(event)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
        .onAppear { log = settings.desktopLog() }
        .onChange(of: store.config.desktopControl.enabled) { _ in log = settings.desktopLog() }
    }
}

/// The text of one row of the desktop action list.
enum DesktopLogText {
    static func line(_ event: ActivityEvent) -> String {
        let key = ActivityEvent.DesktopKey.self
        var parts = [event.extra[key.outcome] ?? "", event.extra[key.window].map { $0.isEmpty ? "" : "window: \($0)" } ?? ""]
        if let note = event.extra[key.note], !note.isEmpty { parts.append(note) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
