import CryptoKit
import Foundation

/// Editable markdown memory the agent reads at the start of each thread and appends to as it learns.
enum Memory {
    static let directory = Paths.root.appendingPathComponent("memory")
    static let aboutMe = directory.appendingPathComponent("me.md")
    private static let maxBytes = 8_000

    static func projectFile(for workspace: URL) -> URL {
        let digest = SHA256.hash(data: Data(workspace.standardizedFileURL.path.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("projects/\(workspace.lastPathComponent)-\(suffix).md")
    }

    static func contains(_ path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }

    /// Context prepended to the first turn of a thread.
    static func preamble(for workspace: URL) -> String {
        let project = projectFile(for: workspace)
        let name = Config.load().config.pet.name
        ensure(aboutMe, header: "# About me\n\nThings \(name) has learned about how I work.\n")
        ensure(project, header: "# \(workspace.lastPathComponent)\n\nWorkspace: \(workspace.path)\n")
        return """
        You are \(name), a small desktop pet assistant (ironpet) helping the user with coding and everyday tasks. \
        Be concise: your replies appear in a small chat bubble.

        You have two memory files. Read them for context:
        - About the user: \(aboutMe.path)
        - About this project: \(project.path)

        <memory file="me.md">
        \(read(aboutMe))
        </memory>
        <memory file="\(project.lastPathComponent)">
        \(read(project))
        </memory>

        When you learn something durable (a preference, a workflow, a project convention, where things live), \
        append one short bullet to the right memory file. Never store secrets. Don't mention memory unless asked.

        User request:
        """
    }

    private static func ensure(_ file: URL, header: String) {
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? header.write(to: file, atomically: true, encoding: .utf8)
    }

    private static func read(_ file: URL) -> String {
        guard let data = try? Data(contentsOf: file) else { return "" }
        return String(decoding: data.suffix(maxBytes), as: UTF8.self)
    }
}
