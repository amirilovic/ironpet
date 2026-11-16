import AppKit
import SwiftUI

/// The Transcripts section: past meetings newest first, and the summary or transcript of the one selected.
struct TranscriptsView: View {
    @ObservedObject var library: MeetingLibrary
    /// The folder of the meeting being recorded or summarized; it cannot be deleted.
    let activeFolder: () -> URL?
    let onAsk: ([URL]) -> Void

    @State private var selection: String?
    @State private var page: Page = .summary
    @State private var text: String?
    @State private var confirmDelete = false
    @State private var error: String?

    enum Page: String, CaseIterable { case summary = "Summary", transcript = "Transcript" }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: IronPetSection.transcripts.title) { EmptyView() }
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
    }

    private var selected: MeetingRecord? { library.meetings.first { $0.id == selection } }

    private var list: some View {
        List(selection: $selection) {
            ForEach(library.meetings) { meeting in
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12.5, weight: .medium))
                    Text(meeting.preview.isEmpty ? (meeting.folder == activeFolder() ? "Recording…" : "No transcript") : meeting.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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
                HStack(spacing: 8) {
                    Picker("", selection: $page) {
                        ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Button { onAsk(meeting.chatFiles) } label: {
                        Label("Ask \(ConfigStore.shared.config.pet.name)", systemImage: "sparkles")
                    }
                    .disabled(meeting.chatFiles.isEmpty)
                    .help("Open the chat with this meeting's transcript and summary attached")
                    IconButton(symbol: "folder", help: "Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([meeting.folder])
                    }
                    IconButton(symbol: "trash", help: "Move to Trash") { confirmDelete = true }
                        .disabled(meeting.folder == activeFolder())
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
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).padding(8)
                }
            }
            .confirmationDialog("Move this meeting to the Trash?", isPresented: $confirmDelete) {
                Button("Move to Trash", role: .destructive) { delete(meeting) }
            } message: {
                Text("Its audio chunks, transcript and summary go to the Trash.")
            }
        }
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
