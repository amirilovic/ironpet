import Foundation

/// What a memory is about. Each kind lives in its own place, so a conversation summary never crowds out a preference.
enum MemoryKind: String, CaseIterable {
    /// A durable fact or preference about the user ("reviews PRs in the morning").
    case fact
    /// A person and what they are to the user ("Ana is my lead, she owns the auth service").
    case person
    /// A two or three line summary of a conversation, so the next one can pick up.
    case conversation
    /// A convention or fact about one project. Needs the project's folder.
    case project
}

struct MemoryEntry: Equatable {
    var kind: MemoryKind
    var text: String
}

struct MemoryError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Ghost's long-term memory as the agent tools see it. `FileMemoryStore` keeps it in the markdown files under
/// `~/.ironpet/memory`; another store (a memory service, a database) can replace it without the tools changing.
@MainActor
protocol MemoryStore: AnyObject {
    /// What a new conversation starts with: facts, people, the project's notes and the latest conversation summaries.
    func recall(workspace: URL?) -> String
    /// Stores one memory. Returns the stored entry, or the one that already said the same.
    @discardableResult
    func remember(_ text: String, kind: MemoryKind, workspace: URL?) throws -> MemoryEntry
    /// Removes every memory that contains `text` and returns what was removed.
    func forget(_ text: String) throws -> [MemoryEntry]
    /// Stored memories, of one kind or all. Project memories need `workspace`.
    func list(kind: MemoryKind?, workspace: URL?) -> [MemoryEntry]
}

/// Memory as editable markdown, one bullet per memory: `me.md` (facts), `people.md`, `conversations.md` and one file
/// per project. The files stay the source of truth, so the user can read and edit them and an agent can still append
/// to them directly, as the chat preamble asks.
@MainActor
final class FileMemoryStore: MemoryStore {
    /// A memory is one bullet, not a document.
    static let maxLength = 500
    /// `conversations.md` keeps this many summaries, newest last.
    static let keptConversations = 50
    /// `recall` includes this many of the newest summaries.
    static let recalledConversations = 5
    /// `forget` refuses a phrase that matches more than this many memories, so a vague phrase can't wipe the files.
    static let maxForget = 10

    let directory: URL
    private let now: () -> Date

    init(directory: URL = Memory.directory, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    var aboutMe: URL { directory.appendingPathComponent("me.md") }
    var people: URL { directory.appendingPathComponent("people.md") }
    var conversations: URL { directory.appendingPathComponent("conversations.md") }

    func projectFile(for workspace: URL) -> URL {
        Memory.projectFile(for: workspace, in: directory)
    }

    func recall(workspace: URL?) -> String {
        var blocks: [String] = []
        func block(_ name: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            blocks.append("<memory file=\"\(name)\">\n" + lines.map { "- \($0)" }.joined(separator: "\n") + "\n</memory>")
        }
        block("me.md", bullets(in: aboutMe))
        block("people.md", bullets(in: people))
        if let workspace { block(projectFile(for: workspace).lastPathComponent, bullets(in: projectFile(for: workspace))) }
        block("conversations.md", Array(bullets(in: conversations).suffix(Self.recalledConversations)))
        return blocks.joined(separator: "\n")
    }

    @discardableResult
    func remember(_ text: String, kind: MemoryKind, workspace: URL?) throws -> MemoryEntry {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-* "))
        guard !line.isEmpty else { throw MemoryError(message: "text is empty") }
        guard line.count <= Self.maxLength else { throw MemoryError(message: "a memory is one short line, at most \(Self.maxLength) characters") }
        guard CaptureRedactor.redact(line).report.isEmpty else {
            throw MemoryError(message: "this looks like it contains a secret (a key, token or password), which memory never stores")
        }
        let file = try self.file(for: kind, workspace: workspace)
        let stored = kind == .conversation ? "\(Self.stamp(now())): \(line)" : line
        if kind != .conversation, let same = bullets(in: file).first(where: { $0.caseInsensitiveCompare(line) == .orderedSame }) {
            return MemoryEntry(kind: kind, text: same)
        }
        try append(stored, to: file, kind: kind, workspace: workspace)
        return MemoryEntry(kind: kind, text: stored)
    }

    func forget(_ text: String) throws -> [MemoryEntry] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 3 else { throw MemoryError(message: "say what to forget in at least 3 characters") }
        let files = memoryFiles()
        let matches = files.flatMap { file, kind in
            bullets(in: file).filter { $0.localizedCaseInsensitiveContains(needle) }.map { MemoryEntry(kind: kind, text: $0) }
        }
        guard matches.count <= Self.maxForget else {
            throw MemoryError(message: "\"\(needle)\" matches \(matches.count) memories; use a longer phrase so only the right ones go")
        }
        for (file, _) in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let kept = content.components(separatedBy: "\n").filter { line in
                guard let bullet = Self.bullet(line) else { return true }
                return !bullet.localizedCaseInsensitiveContains(needle)
            }
            let next = kept.joined(separator: "\n")
            if next != content { try next.write(to: file, atomically: true, encoding: .utf8) }
        }
        return matches
    }

    func list(kind: MemoryKind?, workspace: URL?) -> [MemoryEntry] {
        let kinds = kind.map { [$0] } ?? MemoryKind.allCases
        return kinds.flatMap { kind -> [MemoryEntry] in
            guard let file = try? self.file(for: kind, workspace: workspace) else { return [] }
            return bullets(in: file).map { MemoryEntry(kind: kind, text: $0) }
        }
    }

    // MARK: Files

    private func file(for kind: MemoryKind, workspace: URL?) throws -> URL {
        switch kind {
        case .fact: return aboutMe
        case .person: return people
        case .conversation: return conversations
        case .project:
            guard let workspace else { throw MemoryError(message: "a project memory needs the project's folder") }
            return projectFile(for: workspace)
        }
    }

    /// Every file `forget` looks in: the three shared files and every project file.
    private func memoryFiles() -> [(URL, MemoryKind)] {
        let projects = (try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("projects"), includingPropertiesForKeys: nil)) ?? []
        return [(aboutMe, .fact), (people, .person), (conversations, .conversation)]
            + projects.filter { $0.pathExtension == "md" }.map { ($0, .project) }
    }

    /// Adds a bullet at the end of the file (a new file starts with its header). Everything else in the file stays where the
    /// user put it. Conversations drop their oldest bullets past `keptConversations`.
    private func append(_ entry: String, to file: URL, kind: MemoryKind, workspace: URL?) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = try? String(contentsOf: file, encoding: .utf8)
        var lines = (existing ?? header(kind, workspace: workspace)).components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        if !lines.contains(where: { Self.bullet($0) != nil }) { lines.append("") }
        lines.append("- \(entry)")
        if kind == .conversation {
            var extra = lines.filter { Self.bullet($0) != nil }.count - Self.keptConversations
            lines.removeAll { line in
                guard extra > 0, Self.bullet(line) != nil else { return false }
                extra -= 1
                return true
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func header(_ kind: MemoryKind, workspace: URL?) -> String {
        let name = ConfigStore.shared.config.pet.name
        switch kind {
        case .fact: return "# About me\n\nThings \(name) has learned about how I work.\n"
        case .person: return "# People\n\nPeople I work with, as \(name) has learned them.\n"
        case .conversation: return "# Conversations\n\nShort summaries of my conversations with \(name), newest last.\n"
        case .project:
            let folder = workspace ?? directory
            return "# \(folder.lastPathComponent)\n\nWorkspace: \(folder.path)\n"
        }
    }

    private func bullets(in file: URL) -> [String] {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return content.components(separatedBy: "\n").compactMap(Self.bullet)
    }

    /// The text of a `- ` or `* ` line, or nil for any other line.
    private static func bullet(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return nil }
        let text = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
