import Foundation

/// A folder a job may run in, and why ironpet knows it.
struct ProjectCandidate: Equatable {
    enum Source: String {
        /// The folder of the front Cursor window, when Cursor is the app the user was in.
        case frontmost
        /// The chat's current folder.
        case chat
        /// A folder open in Cursor.
        case cursor
        /// The folder of an agent session ironpet watches (Claude Code in iTerm, Cursor and the others).
        case session
        /// A folder the chat used before.
        case recent
        /// `~/.ironpet/scratch`, for work that is not about code.
        case noProject = "no_project"
    }

    var url: URL
    var sources: [Source]

    var name: String { sources.contains(.noProject) ? "No project" : url.lastPathComponent }

    var json: [String: Any] { ["path": url.path, "name": name, "sources": sources.map(\.rawValue)] }
}

/// Matches a spoken or typed project name ("the ironpet repo", "kokous") to the folders ironpet knows. It never makes up a
/// path: a job can only start in one of the candidates.
enum ProjectResolver {
    struct Result {
        var matches: [ProjectCandidate]
        /// The folder to use, when one match stands out (or no name was given and the user was in a project).
        var best: ProjectCandidate?
        var ambiguous: Bool { best == nil && matches.count > 1 }
    }

    /// Merges the sources in order of preference, one candidate per folder. Missing folders are dropped. Folders are compared
    /// by path: Cursor's `file://` URLs end in a slash and `fileURLWithPath` ones may not.
    static func candidates(frontmost: URL?, chat: URL?, cursor: [URL], sessions: [URL] = [], recents: [URL], scratch: URL,
                           exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [ProjectCandidate] {
        var list: [ProjectCandidate] = []
        let scratchPath = path(scratch)
        func add(_ url: URL?, _ source: ProjectCandidate.Source) {
            guard let url, url.isFileURL else { return }
            let key = path(url)
            guard source == .noProject || key != scratchPath else { return }
            if let index = list.firstIndex(where: { path($0.url) == key }) {
                if !list[index].sources.contains(source) { list[index].sources.append(source) }
            } else if source == .noProject || exists(url) {
                list.append(ProjectCandidate(url: URL(fileURLWithPath: key, isDirectory: true), sources: [source]))
            }
        }
        add(frontmost, .frontmost)
        add(chat, .chat)
        cursor.forEach { add($0, .cursor) }
        sessions.forEach { add($0, .session) }
        recents.forEach { add($0, .recent) }
        add(scratch, .noProject)
        return list
    }

    /// The standardized path, without a trailing slash, that two spellings of a folder share.
    static func path(_ url: URL) -> String { url.standardizedFileURL.path }

    /// The candidate for `path`, however it is spelled (`~`, a trailing slash, `..`).
    static func candidate(at path: String, in candidates: [ProjectCandidate]) -> ProjectCandidate? {
        let key = self.path(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        return candidates.first { self.path($0.url) == key }
    }

    static func resolve(_ name: String?, in candidates: [ProjectCandidate]) -> Result {
        let filler: Set<String> = ["the", "my", "repo", "repository", "project", "folder", "codebase", "app"]
        let words = (name ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let query = normalize(words.filter { !filler.contains($0) }.joined())
        let projects = candidates.filter { !$0.sources.contains(.noProject) }
        guard !query.isEmpty else {
            let best = projects.first { $0.sources.contains(.frontmost) } ?? projects.first { $0.sources.contains(.chat) }
            return Result(matches: projects, best: best)
        }
        if ["no", "none", "scratch", "nocode", "general"].contains(query) {
            let scratch = candidates.filter { $0.sources.contains(.noProject) }
            return Result(matches: scratch, best: scratch.first)
        }
        let scored = projects.map { ($0, score(query, normalize($0.url.lastPathComponent))) }.filter { $0.1 > 0 }
        let top = scored.map(\.1).max() ?? 0
        let matches = scored.sorted { $0.1 > $1.1 }.map(\.0)
        let leaders = scored.filter { $0.1 == top }.map(\.0)
        return Result(matches: matches, best: leaders.count == 1 ? leaders[0] : nil)
    }

    /// 3 for the same name, 2 when one contains the other, 1 for names that only start alike. A short name ("api", "ui")
    /// inside a longer request is too likely to be a coincidence to count.
    private static func score(_ query: String, _ name: String) -> Int {
        guard !name.isEmpty else { return 0 }
        if query == name { return 3 }
        if name.contains(query) || name.count >= 4 && query.contains(name) { return 2 }
        return query.count >= 3 && name.hasPrefix(String(query.prefix(3))) ? 1 : 0
    }

    /// Lowercase letters and digits only, so "Iron Pet", "iron-pet" and "ironpet" are the same.
    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
