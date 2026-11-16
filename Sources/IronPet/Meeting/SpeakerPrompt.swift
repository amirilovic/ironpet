import AVFoundation
import SwiftUI

/// Plays the 3 to 5 second clip of a voice from its chunk file. Only the part of the WAV that is needed is read.
@MainActor
final class SpeakerClipPlayer: ObservableObject {
    @Published private(set) var playing: Int?
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func toggle(_ speaker: MeetingSpeaker) {
        if playing == speaker.id { return stop() }
        stop()
        guard let clip = speaker.clip, let player = try? AVAudioPlayer(contentsOf: clip.url) else { return }
        let part = clip.playable
        player.currentTime = part.start
        guard player.play() else { return }
        self.player = player
        playing = speaker.id
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(part.length))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        stopTask?.cancel()
        player?.stop()
        player = nil
        playing = nil
    }
}

/// The Settings → Meetings section for the last meeting's unnamed voices. Hidden when there is nothing to label.
struct SpeakerLabelSection: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        if controller.hasSpeakersToName {
            Section {
                SpeakerPrompt(controller: controller)
            } footer: {
                Text("Voices found in the last meeting. A name you give is added to the transcript, and ironpet recognises that voice in later meetings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// "Who is this?": the voices of a finished meeting that have no name, each with a clip, a line and a name field.
struct SpeakerPrompt: View {
    @ObservedObject var controller: MeetingController
    @StateObject private var clips = SpeakerClipPlayer()
    @State private var storedNames: [String] = []

    var body: some View {
        let speakers = controller.speakersToName
        if !speakers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Who is this?").font(.system(size: 12, weight: .semibold))
                ForEach(speakers) { speaker in
                    SpeakerRow(controller: controller, clips: clips, speaker: speaker, storedNames: storedNames)
                }
                if controller.namesChangedSinceSummary, case .ready = controller.summary {
                    HStack {
                        Text("The summary was written before these names.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Summarize again") { controller.summarize() }.controlSize(.small)
                    }
                }
            }
            .onAppear { storedNames = controller.storedNames }
            .onDisappear { clips.stop() }
        } else if controller.namesChangedSinceSummary, case .ready = controller.summary {
            HStack {
                Text("The summary was written before these names.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Summarize again") { controller.summarize() }.controlSize(.small)
            }
        }
    }
}

private struct SpeakerRow: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject var clips: SpeakerClipPlayer
    let speaker: MeetingSpeaker
    @State private var name = ""
    @State private var showNames = false
    let storedNames: [String]

    private var matches: [String] {
        let typed = name.trimmingCharacters(in: .whitespaces)
        return controller.knownNames(stored: storedNames).filter { typed.isEmpty || $0.localizedCaseInsensitiveContains(typed) }.prefix(4).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button { clips.toggle(speaker) } label: {
                    Image(systemName: clips.playing == speaker.id ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(speaker.clip == nil)
                .help("Play a few seconds of this voice")
                .accessibilityLabel("Play \(speaker.displayName)")
                Text("\(speaker.displayName), \(MeetingTranscript.duration(speaker.seconds).dropFirst(3)) of speech")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }
            if let line = controller.sampleLine(for: speaker.id) {
                Text("\u{201C}\(line)\u{201D}").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            if let suggestion = speaker.suggestion {
                HStack {
                    Text("Is this \(suggestion)?").font(.caption)
                    Button("Yes") { controller.nameSpeaker(speaker.id, as: suggestion) }.controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .controlSize(.small)
                    .onSubmit { controller.nameSpeaker(speaker.id, as: name) }
                    .onChange(of: name) { _, _ in showNames = true }
                Button("Save") { controller.nameSpeaker(speaker.id, as: name) }
                    .controlSize(.small).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu {
                    Button("Ignore") { controller.dismissSpeaker(speaker.id, mixed: false) }
                    Button("Two people mixed") { controller.dismissSpeaker(speaker.id, mixed: true) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            if showNames, !matches.isEmpty, !matches.contains(name) {
                HStack(spacing: 4) {
                    ForEach(matches, id: \.self) { person in
                        Button(person) { name = person; showNames = false; controller.nameSpeaker(speaker.id, as: person) }
                            .controlSize(.mini)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }
}
