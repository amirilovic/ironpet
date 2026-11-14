import Foundation

/// Keeps the chat input small. A multi-megabyte string in the input freezes SwiftUI layout, and the
/// saved draft is read back at launch, so a huge paste could stop the app from starting at all.
/// Text over `limit` bytes becomes a text file attachment instead.
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
