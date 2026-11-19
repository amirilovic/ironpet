import CryptoKit
import Foundation

/// Which file a note belongs in: `me.md`, `people.md` (one `## Name` section per person) or the current project's file.
enum MemoryScope: String, CaseIterable, Codable {
    case me, project, people
}

/// One line of a memory file: `- Prefers pnpm over npm. <!-- 2026-11-18 chat:3f2a9c1d -->`. The trailer holds the day the note was
/// saved and where it came from. A list line without a trailer was written by hand: it reads as source `user` with no date, and
/// is written back exactly as it was.
struct MemoryNote: Equatable, Hashable {
    var text: String
    /// `yyyy-MM-dd`. Nil for a hand-written line.
    var date: String?
    var source: String

    static let maxLength = 240
    /// At most this many notes go in one forget or replace, so a vague request cannot empty a file.
    static let maxForget = 5
    static let userSource = "user"

    var line: String { date.map { "- \(text) <!-- \($0) \(source) -->" } ?? "- \(text)" }

    /// A chat, a background job, the user or an agent in a chat. Meeting summaries and automation runs carry text other people wrote.
    var isFromOutside: Bool { Self.isOutside(source) }

    static func isOutside(_ source: String) -> Bool { source.hasPrefix("meeting:") || source.hasPrefix("automation:") }

    static func parse(_ line: String) -> MemoryNote? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return nil }
        let body = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
        if body.hasSuffix("-->"), let open = body.range(of: "<!--", options: .backwards) {
            let inner = body[open.upperBound..<body.index(body.endIndex, offsetBy: -3)].trimmingCharacters(in: .whitespaces)
            let parts = inner.split(separator: " ", maxSplits: 1).map(String.init)
            let text = body[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
            if parts.count == 2, isDay(parts[0]), !text.isEmpty {
                return MemoryNote(text: text, date: parts[0], source: parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return body.isEmpty ? nil : MemoryNote(text: body, date: nil, source: userSource)
    }

    static func isDay(_ text: String) -> Bool {
        text.count == 10 && text.enumerated().allSatisfy { index, c in index == 4 || index == 7 ? c == "-" : c.isASCII && c.isNumber }
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    enum Rejection: Error, Equatable {
        case empty, tooLong, secret

        var message: String {
            switch self {
            case .empty: return "the note is empty"
            case .tooLong: return "a note is one line of at most \(MemoryNote.maxLength) characters"
            case .secret: return "the note looks like it holds a key, token or password, so it was not saved"
            }
        }
    }

    /// Turns what an agent proposed into note text: one line, no list marker and no comment markers, which would end the trailer.
    /// A note with anything `CaptureRedactor` would redact is refused, not saved redacted.
    static func clean(_ raw: String) -> Result<String, Rejection> {
        var text = raw.replacingOccurrences(of: "<!--", with: "").replacingOccurrences(of: "-->", with: "")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        for marker in ["- ", "* "] where text.hasPrefix(marker) { text.removeFirst(marker.count) }
        guard !text.isEmpty else { return .failure(.empty) }
        guard text.count <= maxLength else { return .failure(.tooLong) }
        guard CaptureRedactor.redact(text).report.isEmpty else { return .failure(.secret) }
        return .success(text)
    }

    /// The form two notes are compared in, so "Prefers pnpm." and "prefers pnpm" are one note.
    static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A person's section name: one line, no heading marks, at most 60 characters. Nil when nothing is left.
    static func personName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let name = raw.replacingOccurrences(of: "#", with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty, name.count <= 60 else { return nil }
        return name
    }
}

/// A memory file as lines, with the notes in it. Lines that are not notes (headings, prose) stay as they are.
struct MemoryDocument: Equatable {
    struct Entry: Equatable {
        /// The index in `lines`.
        let index: Int
        let note: MemoryNote
        /// The `## ` heading above the note, if any. In `people.md` it is the person.
        let section: String?
    }

    var lines: [String]

    init(_ text: String) {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        self.lines = lines
    }

    var text: String { lines.joined(separator: "\n") + "\n" }

    var entries: [Entry] {
        var section: String?
        var result: [Entry] = []
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("## ") {
                section = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            } else if let note = MemoryNote.parse(line) {
                result.append(Entry(index: index, note: note, section: section))
            }
        }
        return result
    }

    var notes: [MemoryNote] { entries.map(\.note) }

    /// The headings of the `## ` sections, in file order.
    var sections: [String] { lines.filter { $0.hasPrefix("## ") }.map { $0.dropFirst(3).trimmingCharacters(in: .whitespaces) } }

    /// True when the file has nothing but headings, blank lines and the `Workspace:` or `Repo:` line ironpet writes under the title.
    var isHeaderOnly: Bool {
        lines.allSatisfy { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || t.hasPrefix("#") || t.hasPrefix("Workspace: ") || t.hasPrefix("Repo: ")
        }
    }

    /// Adds the note at the end of the file, or at the end of `section`, creating the section when it is missing.
    mutating func append(_ note: MemoryNote, section: String? = nil) {
        guard let section else {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true, lines.count > 1 { lines.removeLast() }
            if let last = lines.last, MemoryNote.parse(last) == nil { lines.append("") }
            lines.append(note.line)
            return
        }
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## ") && $0.dropFirst(3).trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare(section) == .orderedSame }) else {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true, lines.count > 1 { lines.removeLast() }
            lines += ["", "## \(section)", "", note.line]
            return
        }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
        // After the section's last non-blank line, so the blank line before the next heading stays.
        var at = end
        while at > start + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
        if at == start + 1 { lines.insert("", at: at); at += 1 }
        lines.insert(note.line, at: at)
    }

    mutating func remove(lineAt indices: [Int]) {
        for index in indices.sorted(by: >) where lines.indices.contains(index) { lines.remove(at: index) }
    }
}

/// What a project's memory file is keyed by: the git repo's `origin` remote, so every worktree and clone of a repo shares one file,
/// or the folder's path when it has no remote.
struct ProjectKey: Equatable, Hashable {
    /// `github.com/owner/repo`, or the folder's path.
    let key: String
    /// The repo's or the folder's name, for the file name and the heading.
    let name: String
    let isRepo: Bool
    /// The folder the chat used, for the heading of a new file.
    let workspace: URL

    /// `<name>-<8 hex>.md`. A path key hashes the path exactly as the files written before repo keys did, so those still match.
    var fileName: String {
        let digest = SHA256.hash(data: Data((isRepo ? "repo:" + key : key).utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(name)-\(suffix).md"
    }

    var header: String { "# \(name)\n\n" + (isRepo ? "Repo: \(key)" : "Workspace: \(workspace.path)") + "\n" }

    static func path(_ workspace: URL) -> ProjectKey {
        let folder = workspace.standardizedFileURL
        return ProjectKey(key: folder.path, name: folder.lastPathComponent, isRepo: false, workspace: folder)
    }

    /// Reads the git config files directly rather than running `git`, which on a Mac without the developer tools opens an
    /// install prompt.
    static func of(_ workspace: URL) -> ProjectKey {
        let folder = workspace.standardizedFileURL
        guard let remote = originURL(for: folder), let key = normalizeRemote(remote) else { return path(folder) }
        let name = key.split(separator: "/").last.map(String.init) ?? folder.lastPathComponent
        return ProjectKey(key: key, name: name.isEmpty ? folder.lastPathComponent : name, isRepo: true, workspace: folder)
    }

    /// `origin`'s URL from the repo that holds `folder`, following a worktree's `.git` file to the main repo's config.
    static func originURL(for folder: URL) -> String? {
        let files = FileManager.default
        var dir = folder
        while true {
            let git = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if files.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                var gitDir = git
                if !isDirectory.boolValue {
                    guard let text = try? String(contentsOf: git, encoding: .utf8),
                          let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
                }
                var common = gitDir
                if let relative = (try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !relative.isEmpty {
                    common = relative.hasPrefix("/") ? URL(fileURLWithPath: relative) : gitDir.appendingPathComponent(relative)
                }
                return (try? String(contentsOf: common.appendingPathComponent("config"), encoding: .utf8)).flatMap(originURL(config:))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || dir.path == "/" { return nil }
            dir = parent
        }
    }

    /// The `url` of `[remote "origin"]` in a git config file.
    static func originURL(config: String) -> String? {
        var inOrigin = false
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"
            } else if inOrigin, line.hasPrefix("url") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "url" {
                    return parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
        }
        return nil
    }

    /// `git@github.com:Owner/Repo.git`, `https://user@github.com/Owner/Repo` and `ssh://git@github.com:22/Owner/Repo.git` are all
    /// `github.com/Owner/Repo`. The host is lowercased; the path keeps its case, as hosts like GitLab treat it.
    static func normalizeRemote(_ raw: String) -> String? {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        if url.hasSuffix(".git") { url.removeLast(4) }
        guard !url.isEmpty else { return nil }
        if url.hasPrefix("file://") { return "file:" + url.dropFirst("file://".count) }
        var host: String, path: String
        if let scheme = url.range(of: "://") {
            var rest = url[scheme.upperBound...]
            if let at = rest.firstIndex(of: "@"), rest[..<at].firstIndex(of: "/") == nil { rest = rest[rest.index(after: at)...] }
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = String(rest[..<slash])
            path = String(rest[rest.index(after: slash)...])
            if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        } else if let colon = url.firstIndex(of: ":"), !url.hasPrefix("/"), url[..<colon].firstIndex(of: "/") == nil {
            var left = url[..<colon]
            if let at = left.firstIndex(of: "@") { left = left[left.index(after: at)...] }
            host = String(left)
            path = String(url[url.index(after: colon)...])
        } else {
            return "file:" + url
        }
        while path.hasPrefix("/") { path.removeFirst() }
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return host.lowercased() + "/" + path
    }
}
