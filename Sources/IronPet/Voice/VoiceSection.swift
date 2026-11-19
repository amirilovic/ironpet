import SwiftUI

/// The Voice page of the ironpet window: a button to start or end a conversation, what was last said each way, quick
/// settings, and past voice conversations. With voice mode off it offers to turn it on, with the same check as Settings.
struct VoiceSection: View {
    @ObservedObject var conversation: VoiceConversation
    var onToggle: () -> Void
    var onOpenThread: (String) -> Void
    var onOpenSettings: () -> Void
    /// Past conversations; `ThreadStore.voice` in the app, sample threads in previews.
    var loadThreads: @Sendable () -> [ChatThread] = { ThreadStore.voice() }

    @ObservedObject private var config = ConfigStore.shared
    @State private var threads: [ChatThread] = []
    @State private var enabling = false
    @State private var enableError: String?
    @StateObject private var player = SpeechPlayer()

    private var settings: Config.VoiceMode { config.config.voiceMode }
    private var petName: String { config.config.pet.name }
    private var state: VoiceConversation.State { conversation.state }
    private var active: Bool { conversation.isActive }
    private var wispr: Bool { active ? conversation.mode == .wispr : settings.listenWith == Config.VoiceMode.wispr }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                talk
                if settings.enabled { quickSettings }
                history
            }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
        .pageHeader(IronPetSection.voice.title) {
            Button(action: onOpenSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Voice settings")
                .accessibilityLabel("Voice settings")
        }
        .onAppear(perform: refresh)
        .onChange(of: state) { if $0 == .idle { refresh() } }
    }

    // MARK: Talk

    private var talk: some View {
        VStack(spacing: 14) {
            Button(action: settings.enabled ? onToggle : turnOn) {
                ZStack {
                    Circle()
                        .fill(active ? Color.red.opacity(0.9) : Color.accentColor)
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    Image(systemName: active ? "stop.fill" : "mic.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 96, height: 96)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(enabling)
            .help(active ? "End the conversation" : settings.enabled ? "Talk to \(petName)" : "Turn on voice mode")
            .accessibilityLabel(active ? "End voice conversation" : settings.enabled ? "Talk to \(petName)" : "Turn on voice mode")

            Text(headline).font(.title3.weight(.semibold))
            if state == .listening, !wispr {
                VoiceLevelMeter(levels: conversation.levels, count: 9, barWidth: 5).frame(width: 90, height: 26)
            }
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if enabling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking that the server can hear and speak…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let enableError {
                Text(enableError).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).textSelection(.enabled)
            }
            if active, conversation.heard != nil || conversation.reply != nil { exchange }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var headline: String {
        if !settings.enabled { return "Voice mode is off" }
        return active ? state.title(wispr: wispr, petName: petName) : "Talk to \(petName)"
    }

    private var subtitle: String {
        guard settings.enabled else {
            return "Turn it on to talk with \(petName) hands free. The voice server is checked first: it must transcribe a test clip and speak one line."
        }
        if active { return "Say bye, press Esc or this button to end." }
        let shortcut = Shortcut.display(config.config.hotkeys.voiceMode).map { " or press \($0) anywhere" } ?? ""
        return "Click the button\(shortcut). \(petName) answers out loud and hands longer work to background jobs."
    }

    private var exchange: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let heard = conversation.heard { line("You", heard) }
            if let reply = conversation.reply { line(petName, reply) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func line(_ who: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(who).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).textSelection(.enabled)
        }
    }

    private func turnOn() {
        enableError = nil
        enabling = true
        Task {
            defer { enabling = false }
            if case .failed(let message) = await VoiceModeController.enable(using: player) { enableError = message }
        }
    }

    // MARK: Settings

    private var quickSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings").font(.headline)
            Picker("Listen with", selection: Binding(get: { settings.listenWith },
                                                     set: { value in config.update { $0.voiceMode.listenWith = value } })) {
                Text("Microphone").tag(Config.VoiceMode.ironpet)
                Text("Wispr Flow").tag(Config.VoiceMode.wispr)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            .disabled(active)
            Toggle("Say when a voice job is done or needs me", isOn: Binding(
                get: { settings.speakJobUpdates }, set: { on in config.update { $0.voiceMode.speakJobUpdates = on } }))
            Toggle("Voice mode", isOn: Binding(get: { settings.enabled }, set: { on in
                if !on { config.update { $0.voiceMode.enabled = false } }
            }))
            .help("Turn voice mode off. Turning it back on runs the server check again.")
        }
    }

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Past conversations").font(.headline)
            if threads.isEmpty {
                Text("Conversations show up here, and in the chat's history, once you have talked with \(petName).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(threads) { thread in
                Button { onOpenThread(thread.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mic.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(thread.title).lineLimit(1)
                            Text(Self.summary(of: thread)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .help("Open in the chat")
            }
        }
    }

    /// "3 things said": how many times the user spoke in the conversation.
    nonisolated static func summary(of thread: ChatThread) -> String {
        let said = thread.items.filter { if case .user = $0.kind { return true } else { return false } }.count
        return said == 1 ? "1 thing said" : "\(said) things said"
    }

    private func refresh() {
        let load = loadThreads
        Task {
            let found = await Task.detached(priority: .userInitiated) { load() }.value
            threads = found
        }
    }
}
