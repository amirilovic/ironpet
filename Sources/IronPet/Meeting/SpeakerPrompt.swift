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
    @ObservedObject var meetings: MeetingsAPI

    var body: some View {
        if meetings.hasSpeakersToName {
            Section {
                SpeakerPrompt(meetings: meetings)
            } footer: {
                Text("Voices found in the last meeting. A name you give is added to the transcript, and ironpet recognises that voice in later meetings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// "Who is this?": the voices of a finished meeting that have no name, each with a clip, a line and a name field.
struct SpeakerPrompt: View {
    @ObservedObject var meetings: MeetingsAPI
    @StateObject private var clips = SpeakerClipPlayer()
    @State private var storedNames: [String] = []

    var body: some View {
        let speakers = meetings.speakersToName
        if !speakers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Who is this?").font(.system(size: 12, weight: .semibold))
                ForEach(speakers) { speaker in
                    SpeakerRow(meetings: meetings, clips: clips, speaker: speaker, storedNames: storedNames)
                }
                RegenerateSummaryRow(meetings: meetings)
            }
            .onAppear { storedNames = meetings.storedNames }
            .onDisappear { clips.stop() }
        } else {
            RegenerateSummaryRow(meetings: meetings)
        }
    }
}

/// The one button of the naming flow that follows a name: summarise again, so the summary uses it. Never automatic.
struct RegenerateSummaryRow: View {
    @ObservedObject var meetings: MeetingsAPI

    var body: some View {
        if meetings.canRegenerateSummary {
            HStack {
                Text("The summary does not have these names yet.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if meetings.regeneratingSummary { ProgressView().controlSize(.small) }
                Button("Regenerate summary") { meetings.regenerateSummary() }
                    .controlSize(.small)
                    .disabled(meetings.regeneratingSummary)
                    .help("Summarise the transcript again with the names you gave. The old summary is kept as summary.prev.md")
            }
        }
    }
}

private struct SpeakerRow: View {
    @ObservedObject var meetings: MeetingsAPI
    @ObservedObject var clips: SpeakerClipPlayer
    let speaker: MeetingSpeaker
    @State private var name = ""
    @State private var showNames = false
    let storedNames: [String]

    private var matches: [String] {
        let typed = name.trimmingCharacters(in: .whitespaces)
        return meetings.knownNames(stored: storedNames).filter { typed.isEmpty || $0.localizedCaseInsensitiveContains(typed) }.prefix(4).map { $0 }
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
            if let line = meetings.sampleLine(for: speaker.id) {
                Text("\u{201C}\(line)\u{201D}").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            if let suggestion = speaker.suggestion {
                HStack {
                    Text("Is this \(suggestion)?").font(.caption)
                    Button("Yes") { try? meetings.nameSpeaker(NameSpeakerRequest(speaker: speaker.id, name: suggestion)) }.controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .controlSize(.small)
                    .onSubmit { try? meetings.nameSpeaker(NameSpeakerRequest(speaker: speaker.id, name: name)) }
                    .onChange(of: name) { _, _ in showNames = true }
                Button("Save") { try? meetings.nameSpeaker(NameSpeakerRequest(speaker: speaker.id, name: name)) }
                    .controlSize(.small).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu {
                    Button("Ignore") { try? meetings.dismissSpeaker(DismissSpeakerRequest(speaker: speaker.id, mixed: false)) }
                    Button("Two people mixed") { try? meetings.dismissSpeaker(DismissSpeakerRequest(speaker: speaker.id, mixed: true)) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            if showNames, !matches.isEmpty, !matches.contains(name) {
                HStack(spacing: 4) {
                    ForEach(matches, id: \.self) { person in
                        Button(person) { name = person; showNames = false; try? meetings.nameSpeaker(NameSpeakerRequest(speaker: speaker.id, name: person)) }
                            .controlSize(.mini)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }
}
