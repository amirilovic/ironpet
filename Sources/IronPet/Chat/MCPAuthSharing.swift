import Foundation

/// cursor-agent stores MCP OAuth sign-ins per workspace in `~/.cursor/projects/<slug>/mcp-auth.json`, so signing in
/// to e.g. Sentry from one folder doesn't help a chat in another. Before each pet chat run, copy every signed-in
/// server's entry (tokens plus the client registration they belong to) from the most recently written file into
/// the run's workspace file. Other entries in that file are left alone. This relies on an internal Cursor file.
enum MCPAuthSharing {
    static let projects = Paths.home.appendingPathComponent(".cursor/projects")

    static func prepare(workspace: URL) {
        let best = newestSignedInEntries()
        guard !best.isEmpty else { return }
        for dir in projectDirectories(for: workspace) {
            merge(best, into: dir.appendingPathComponent("mcp-auth.json"))
        }
    }

    /// Per server, the entry with tokens from the most recently modified mcp-auth.json.
    private static func newestSignedInEntries() -> [String: Any] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        var best: [String: (entry: Any, date: Date)] = [:]
        for dir in dirs {
            let file = dir.appendingPathComponent("mcp-auth.json")
            guard let date = (try? fm.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
                  let json = read(file) else { continue }
            for (server, value) in json {
                guard let entry = value as? [String: Any], entry["tokens"] != nil, entry["clientInfo"] != nil else { continue }
                if date > best[server]?.date ?? .distantPast { best[server] = (entry, date) }
            }
        }
        return best.mapValues(\.entry)
    }

    private static func merge(_ entries: [String: Any], into file: URL) {
        var json = read(file) ?? [:]
        var changed = false
        for (server, entry) in entries where !NSDictionary(dictionary: ["v": entry]).isEqual(to: ["v": json[server] as Any]) {
            json[server] = entry
            changed = true
        }
        guard changed, let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Cursor names the folder after the workspace path with non-alphanumerics turned into dashes. Cover both the
    /// path as given and its resolved form (/tmp vs /private/tmp).
    private static func projectDirectories(for workspace: URL) -> [URL] {
        let paths = Set([workspace.standardizedFileURL.path, workspace.resolvingSymlinksInPath().path])
        return paths.map { path in
            let slug = String(path.drop(while: { $0 == "/" }).map { $0.isLetter || $0.isNumber ? $0 : "-" })
            return projects.appendingPathComponent(slug)
        }
    }

    private static func read(_ file: URL) -> [String: Any]? {
        (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
