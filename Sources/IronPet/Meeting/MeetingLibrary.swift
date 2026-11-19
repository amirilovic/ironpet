import Foundation

/// A past (or running) meeting: one folder under `~/.ironpet/meetings`.
struct MeetingRecord: Identifiable, Equatable {
    let folder: URL
    let date: Date
    /// The first line of the summary that is not a heading, or of the transcript when there is no summary yet.
    let preview: String
    let hasSummary: Bool
    let hasTranscript: Bool
    /// The folder still has `mic-NNN.wav` or `them-NNN.wav` chunks, so it can be transcribed again.
    var hasAudio = false

    var id: String { folder.lastPathComponent }
    var transcriptURL: URL { folder.appendingPathComponent("transcript.md") }
    var summaryURL: URL { folder.appendingPathComponent("summary.md") }
    /// What "Ask Ghost about this meeting" attaches, the same files the meeting bubble sends.
    var chatFiles: [URL] { [transcriptURL, summaryURL].filter { FileManager.default.fileExists(atPath: $0.path) } }
}

/// The Transcripts section's list. Reads only the folder names and the start of each summary; the full texts are read
/// when a meeting is opened, off the main thread.
@MainActor
final class MeetingLibrary: ObservableObject {
    @Published private(set) var meetings: [MeetingRecord] = [] {
        didSet { if meetings != oldValue { events?.publish(.meetingsChanged) } }
    }
    /// Where `meetings.changed` is published for API clients.
    weak var events: APIEventBus?
    /// Rebuilds a meeting's transcript and summary. Lives here so the list and the work on it share one place.
    let regenerator = MeetingRegenerator()
    private let root: URL

    init(root: URL = Paths.meetings) {
        self.root = root
    }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        meetings = folders.compactMap(Self.record).sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    /// Moves the folder to the Trash rather than deleting it, so a wrong click can be undone in Finder.
    func delete(_ id: String) throws {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        try FileManager.default.trashItem(at: meeting.folder, resultingItemURL: nil)
        reload()
    }

    static func record(_ folder: URL) -> MeetingRecord? {
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              let date = date(folderName: folder.lastPathComponent) else { return nil }
        let summary = folder.appendingPathComponent("summary.md"), transcript = folder.appendingPathComponent("transcript.md")
        let hasSummary = FileManager.default.fileExists(atPath: summary.path)
        let hasTranscript = FileManager.default.fileExists(atPath: transcript.path)
        let preview = (hasSummary ? head(of: summary) : hasTranscript ? head(of: transcript) : nil).flatMap(firstLine) ?? ""
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return MeetingRecord(folder: folder, date: date, preview: preview, hasSummary: hasSummary, hasTranscript: hasTranscript,
                             hasAudio: files.contains { MeetingFolderScan.chunkName($0) != nil })
    }

    /// `yyyy-MM-dd-HHmm`, with the `-2`, `-3` … suffix a second meeting in the same minute gets.
    nonisolated static func date(folderName: String) -> Date? {
        let parts = folderName.split(separator: "-")
        guard parts.count == 4 || parts.count == 5, parts.dropFirst(4).allSatisfy({ Int($0) != nil }) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.date(from: parts.prefix(4).joined(separator: "-"))
    }

    static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && $0 != "---" }
            .map { line in
                var line = line
                for marker in ["- ", "* ", "> "] where line.hasPrefix(marker) { line.removeFirst(marker.count) }
                return line.replacingOccurrences(of: "**", with: "")
            }
    }

    /// The first few KB, enough for a preview line, so a long transcript is not read for the list.
    private static func head(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4096)).flatMap { String(decoding: $0, as: UTF8.self) }
    }
}
