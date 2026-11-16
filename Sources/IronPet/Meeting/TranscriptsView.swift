import AppKit
import SwiftUI

/// The Transcripts section: past meetings newest first, and the summary or transcript of the one selected.
struct TranscriptsView: View {
    @ObservedObject var library: MeetingLibrary
    @ObservedObject private var regenerator: MeetingRegenerator
    /// The folder of the meeting being recorded or summarized; it cannot be deleted.
    let activeFolder: () -> URL?
    let onAsk: ([URL]) -> Void

    init(library: MeetingLibrary, activeFolder: @escaping () -> URL?, onAsk: @escaping ([URL]) -> Void) {
        self.library = library
        self.regenerator = library.regenerator
        self.activeFolder = activeFolder
        self.onAsk = onAsk
    }

    @State private var selection: String?
    @State private var page: Page = .summary
    @State private var text: String?
    @State private var confirmDelete = false
    @State private var error: String?

    enum Page: String, CaseIterable { case summary = "Summary", transcript = "Transcript" }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: IronPetSection.transcripts.title) {
                if let progress = regenerator.progress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(progress.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if library.meetings.isEmpty {
                EmptyState(symbol: "waveform", title: "No meetings yet",
                           detail: "Start one from \(ConfigStore.shared.config.pet.name)'s right-click menu; its transcript and summary show up here.")
            } else {
                HStack(spacing: 0) {
                    list
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            library.reload()
            if selection == nil || !library.meetings.contains(where: { $0.id == selection }) { selection = library.meetings.first?.id }
            load()
        }
        .onChange(of: selection) { load() }
        .onChange(of: page) { load() }
        // A run changed files on disk: the list previews and the open text may be new.
        .onChange(of: regenerator.completed) {
            library.reload()
            load()
        }
    }

    private var selected: MeetingRecord? { library.meetings.first { $0.id == selection } }

    private var list: some View {
        List(selection: $selection) {
            ForEach(library.meetings) { meeting in
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12.5, weight: .medium))
                    if regenerator.activeID == meeting.id, let progress = regenerator.progress {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text(progress.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } else {
                        Text(meeting.preview.isEmpty ? (meeting.folder == activeFolder() ? "Recording…" : "No transcript") : meeting.preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
                .tag(meeting.id)
            }
        }
        .listStyle(.inset)
        .frame(width: 230)
    }

    @ViewBuilder private var detail: some View {
        if let meeting = selected {
            VStack(alignment: .leading, spacing: 0) {
                // At the narrowest window the Ask label would be cut, so it falls back to its icon.
                ViewThatFits(in: .horizontal) {
                    toolbar(meeting, askLabel: true)
                    toolbar(meeting, askLabel: false)
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                ScrollView {
                    Group {
                        if let text, !text.isEmpty {
                            MarkdownView(text: text)
                        } else {
                            Text(page == .summary ? "No summary for this meeting." : "No transcript for this meeting.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                if let message = error ?? regenerator.errors[meeting.id] {
                    Text(message).font(.caption).foregroundStyle(.red).padding(8)
                }
            }
            .confirmationDialog("Move this meeting to the Trash?", isPresented: $confirmDelete) {
                Button("Move to Trash", role: .destructive) { delete(meeting) }
            } message: {
                Text("Its audio chunks, transcript and summary go to the Trash.")
            }
        }
    }

    private func toolbar(_ meeting: MeetingRecord, askLabel: Bool) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: $page) {
                ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Button { onAsk(meeting.chatFiles) } label: {
                if askLabel {
                    Label("Ask \(ConfigStore.shared.config.pet.name)", systemImage: "sparkles")
                } else {
                    Label("Ask \(ConfigStore.shared.config.pet.name)", systemImage: "sparkles").labelStyle(.iconOnly)
                }
            }
            .disabled(meeting.chatFiles.isEmpty)
            .help("Open the chat with this meeting's transcript and summary attached")
            regenerateMenu(meeting)
            IconButton(symbol: "folder", help: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([meeting.folder])
            }
            IconButton(symbol: "trash", help: "Move to Trash") { confirmDelete = true }
                .disabled(meeting.folder == activeFolder() || regenerator.activeID == meeting.id)
        }
    }

    /// Click for a new transcript and summary, or pick "Summary only" to keep the transcript, for example after naming a speaker.
    private func regenerateMenu(_ meeting: MeetingRecord) -> some View {
        let reason = regenerator.unavailableReason(for: meeting, activeFolder: activeFolder())
        return Menu {
            Button("Transcript and summary") { regenerate(meeting, .full) }
            Button("Summary only") { regenerate(meeting, .summaryOnly) }
                .disabled(!meeting.hasTranscript)
        } label: {
            Label("Regenerate", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
        } primaryAction: {
            regenerate(meeting, .full)
        }
        .fixedSize()
        .accessibilityLabel("Regenerate transcript and summary")
        .disabled(reason != nil)
        .help(reason ?? "Transcribe the saved audio again and write a new summary, with today's model, speaker names and summary agent. The old files are kept as .prev.md")
    }

    private func regenerate(_ meeting: MeetingRecord, _ mode: RegenerationMode) {
        error = nil
        let folder = activeFolder()
        Task { await regenerator.regenerate(meeting, mode: mode, activeFolder: folder) }
    }

    private func load() {
        guard let meeting = selected else { text = nil; return }
        let url = page == .summary ? meeting.summaryURL : meeting.transcriptURL
        let id = meeting.id, wanted = page
        text = nil
        Task {
            let loaded = await Task.detached { try? String(contentsOf: url, encoding: .utf8) }.value
            // A slow read for a meeting the user already left must not replace the newer one.
            guard selection == id, page == wanted else { return }
            text = loaded
        }
    }

    private func delete(_ meeting: MeetingRecord) {
        do {
            try library.delete(meeting.id)
            error = nil
            selection = library.meetings.first?.id
        } catch {
            self.error = "Could not move it to the Trash: \(error.localizedDescription)"
        }
    }
}
