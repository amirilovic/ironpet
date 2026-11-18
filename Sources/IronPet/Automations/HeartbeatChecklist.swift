import Foundation

/// `~/.ironpet/HEARTBEAT.md`, the list the heartbeat automation works through. The user and the agent own it.
/// ironpet writes it once, when it is missing, and never changes it afterwards.
enum HeartbeatChecklist {
    static let defaultText = """
        # Heartbeat

        <!--
        The heartbeat skill reads this file every 15 minutes and works through the entries in order.
        Each entry is one plain instruction. Add, change or remove entries freely.
        Lines that start with # and text inside an HTML comment are ignored.
        -->

        - Resolve every pending task suggestion. Accept it when the evidence holds, reject it when it is wrong or a duplicate.
        - Check every open task. Close the ones a query can verify, and tell me what only I can do next.
        - Read the screen activity since the last run and match it to my tasks. Update a task when something changed it, and add one for a new commitment.

        """

    /// Writes the default checklist when the file is missing. Returns true when it wrote it.
    @discardableResult
    static func ensureExists(at file: URL = Paths.heartbeat) -> Bool {
        guard !FileManager.default.fileExists(atPath: file.path) else { return false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? defaultText.write(to: file, atomically: true, encoding: .utf8)) != nil
    }

    /// The entries of the file: every line that is not blank, a `#` line or inside an HTML comment.
    static func entries(in text: String) -> [String] {
        let withoutComments = text.replacingOccurrences(of: "<!--[\\s\\S]*?(-->|$)", with: "", options: .regularExpression)
        return withoutComments.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// True when the file exists and has at least one entry.
    static func hasEntries(at file: URL = Paths.heartbeat) -> Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        return !entries(in: String(decoding: data, as: UTF8.self)).isEmpty
    }
}
