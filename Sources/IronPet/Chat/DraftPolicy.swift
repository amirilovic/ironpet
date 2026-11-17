import Foundation

/// Keeps the chat input small. A multi-megabyte string in the input freezes SwiftUI layout, and the
/// saved draft is read back at launch, so a huge paste could stop the app from starting at all.
/// Text over `limit` bytes becomes a text file attachment instead. This is a fixed safety bound for
/// the input field. The limits the user sets in Settings (`PasteLimits`) only decide what a paste does.
enum DraftPolicy {
    /// Largest input, in UTF-8 bytes, that stays in the text field and in UserDefaults.
    static let limit = 64 * 1024

    static func exceedsLimit(_ text: String) -> Bool {
        text.utf8.count > limit
    }

    /// Writes `text` to a new file under `directory` and returns its URL, or nil if the write fails.
    static func saveAsAttachment(_ text: String, into directory: URL = FileIntake.directory) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = directory.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(6))")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("pasted-text.txt")
            try text.write(to: file, atomically: true, encoding: .utf8)
            FileIntake.prune(directory)
            return file
        } catch {
            NSLog("ironpet: could not save long text as attachment: \(error)")
            return nil
        }
    }

    /// The text to keep in the input, plus the attachment that now holds the original when it was too long.
    /// If the file cannot be written, the text is truncated to the limit so the input stays bounded.
    static func apply(_ text: String, into directory: URL = FileIntake.directory) -> (input: String, attachment: URL?) {
        guard exceedsLimit(text) else { return (text, nil) }
        if let file = saveAsAttachment(text, into: directory) { return ("", file) }
        return (String(decoding: Array(text.utf8.prefix(limit)), as: UTF8.self), nil)
    }
}

/// When a paste becomes an attachment: over `chars` characters or over `lines` lines. Both come from Settings > Chat.
struct PasteLimits: Equatable {
    var chars: Int
    var lines: Int

    /// The values in Settings now, read on every paste so a change applies without a restart.
    @MainActor static var current: PasteLimits {
        let chat = ConfigStore.shared.config.chat
        return PasteLimits(chars: chat.pasteAttachmentChars, lines: chat.pasteAttachmentLines)
    }

    func exceeds(_ text: String) -> Bool {
        if text.count > chars { return true }
        return Self.lineCount(text) > lines
    }

    /// Lines separated by a newline. One trailing newline does not start a new line.
    static func lineCount(_ text: String) -> Int {
        var count = 1
        var lastWasNewline = false
        for character in text {
            lastWasNewline = character.isNewline
            if lastWasNewline { count += 1 }
        }
        return lastWasNewline ? count - 1 : count
    }
}
