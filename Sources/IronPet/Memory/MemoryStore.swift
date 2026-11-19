import Foundation

/// A memory file, for the Settings list.
struct MemoryFile: Identifiable, Equatable {
    /// The path inside the memory folder: `me.md`, `people.md` or `projects/<name>-<hash>.md`.
    let path: String
    let url: URL
    let title: String
    let notes: Int
    let modified: Date
    var id: String { path }
}

struct MemoryError: Error, Equatable, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A note `forget` removed, and where it was.
struct ForgottenNote: Equatable {
    let file: String
    let section: String?
    let note: MemoryNote
}

/// Ghost's notes as the memory tools, the chat preamble and the reflection pass see them. `FileMemoryStore` keeps them in the
/// markdown files under `~/.ironpet/memory`; another store (a memory service, a database) can replace it without those changing.
/// The Settings editor, `.history`, Undo and tidying work on the files, so they stay with `FileMemoryStore`.
@MainActor
protocol MemoryStore: AnyObject {
    /// Saves a note in place of older ones it makes wrong (`replacing` names them by text; none for a plain save). A note that is
    /// already there comes back instead of being added twice. Refuses secrets, and replacing more than `MemoryNote.maxForget` notes.
    func replace(_ replacing: [String], with text: String, scope: MemoryScope, person: String?, project: ProjectKey?,
                 source: String) -> Result<MemoryNote, MemoryError>
    /// Removes the notes that contain every word of `query`, recoverably. Refuses when nothing matches or more than
    /// `MemoryNote.maxForget` notes do.
    func forget(_ query: String, scope: MemoryScope?, person: String?, project: ProjectKey?, source: String) -> Result<[ForgottenNote], MemoryError>
    /// One scope's notes for a prompt: whole notes, newest first, within `bytes`, and a line saying how many were left out. For
    /// people, those `message` names come first. Empty when there are none.
    func recall(_ scope: MemoryScope, project: ProjectKey?, bytes: Int, naming message: String) -> String
    /// Where a scope's notes live, to show the agent (`me.md`, `projects/ironpet-1a2b3c4d.md`).
    func location(_ scope: MemoryScope, project: ProjectKey?) -> String?
    /// The folder of note files an agent may also edit directly, or nil when the notes are not files.
    var editableFolder: URL? { get }
}

extension MemoryStore {
    @discardableResult
    func remember(_ text: String, scope: MemoryScope, person: String? = nil, project: ProjectKey? = nil, source: String) -> Result<MemoryNote, MemoryError> {
        replace([], with: text, scope: scope, person: person, project: project, source: source)
    }
}

/// Owns the markdown files in `~/.ironpet/memory/`. They are the source of truth: the user can read and edit them, and every
/// change made here first copies the old file to `.history/`, then writes the file, re-indexes its notes and logs the change for
/// Undo. Files are created on the first note, never by reading.
@MainActor
final class FileMemoryStore: MemoryStore {
    /// A variable so tests can point it at a temp folder. Set at launch or in a test's setUp, before any store reads it.
    nonisolated(unsafe) static var directory = Paths.root.appendingPathComponent("memory")

    private static var current: FileMemoryStore?
    /// The app's store, with the search index once the database is open. It follows `directory`, so a test that moves the folder
    /// gets a store there.
    static var shared: FileMemoryStore {
        get {
            if let current, current.directory == directory { return current }
            let store = FileMemoryStore(directory: directory)
            current = store
            return store
        }
        set { current = newValue }
    }

    /// Whether a path is inside the memory folder, `.history` included.
    nonisolated static func contains(_ path: String) -> Bool {
        comparable(path).hasPrefix(comparable(directory.path) + "/")
    }

    /// A note file an agent may edit without a card (`ApprovalRules`): inside the memory folder, outside `.history`, which is what
    /// Undo and forgotten notes come back from.
    nonisolated static func isNoteFile(_ path: String) -> Bool {
        contains(path) && !comparable(path).hasPrefix(comparable(directory.path) + "/.history/")
    }

    /// Resolved and lowercased, since the Mac's file system ignores case: `~/.IRONPET/Memory/me.md` is the same file.
    nonisolated private static func comparable(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }

    /// Past this size a file is tidied after the next reflection.
    static let sizeLimit: [MemoryScope: Int] = [.me: 8_000, .project: 12_000, .people: 8_000]
    /// Earlier versions kept per file. The oldest go, with their index entries, when a new one is written.
    static let historyLimit = 50

    let directory: URL
    var index: MemoryIndex?
    var now: () -> Date = Date.init
    var calendar = Calendar.current

    init(directory: URL, index: MemoryIndex? = nil) {
        self.directory = directory
        self.index = index
    }

    // MARK: Files

    var aboutMe: URL { directory.appendingPathComponent("me.md") }
    var people: URL { directory.appendingPathComponent("people.md") }
    var historyRoot: URL { directory.appendingPathComponent(".history") }

    func projectFile(_ project: ProjectKey) -> URL {
        directory.appendingPathComponent("projects").appendingPathComponent(project.fileName)
    }

    func file(_ scope: MemoryScope, project: ProjectKey?) -> URL? {
        switch scope {
        case .me: return aboutMe
        case .people: return people
        case .project: return project.map(projectFile)
        }
    }

    func relativePath(_ url: URL) -> String {
        let base = directory.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }

    /// `.history/<file with / as _>`, the folder that holds a file's earlier versions.
    nonisolated static func historyFolder(for path: String) -> String {
        ".history/" + path.replacingOccurrences(of: "/", with: "_")
    }

    private func header(for url: URL, project: ProjectKey?) -> String {
        if url == aboutMe { return "# About me\n" }
        if url == people { return "# People\n" }
        return project?.header ?? "# \(url.deletingPathExtension().lastPathComponent)\n"
    }

    func document(_ url: URL) -> MemoryDocument? {
        (try? String(contentsOf: url, encoding: .utf8)).map(MemoryDocument.init)
    }

    func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// `me.md`, `people.md` and the project files that exist, newest first after the two fixed ones.
    func files() -> [MemoryFile] {
        let fixed = [aboutMe, people].filter { FileManager.default.fileExists(atPath: $0.path) }
        let projects = ((try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("projects"),
                                                                      includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "md" }
        let summaries = (fixed + projects).map(summary)
        return Array(summaries.prefix(fixed.count)) + summaries.dropFirst(fixed.count).sorted { $0.modified > $1.modified }
    }

    private func summary(_ url: URL) -> MemoryFile {
        let document = document(url) ?? MemoryDocument("")
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return MemoryFile(path: relativePath(url), url: url, title: title(url, document), notes: document.entries.count, modified: modified)
    }

    func title(_ url: URL, _ document: MemoryDocument? = nil) -> String {
        if url == aboutMe { return "About me" }
        if url == people { return "People" }
        let heading = (document ?? self.document(url))?.lines.first { $0.hasPrefix("# ") }?.dropFirst(2)
            .trimmingCharacters(in: .whitespaces)
        return heading.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
    }

    // MARK: Writing

    /// Copies the file as it is now to `.history/`, then writes `document`, re-indexes and returns the copy's path inside the folder.
    @discardableResult
    private func write(_ document: MemoryDocument, to url: URL) throws -> String? {
        let files = FileManager.default
        var saved: String?
        if let old = try? String(contentsOf: url, encoding: .utf8) {
            let folder = historyRoot.appendingPathComponent(String(Self.historyFolder(for: relativePath(url)).dropFirst(".history/".count)))
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = Self.stamp(now())
            // Numbered after the newest copy of the same millisecond, so after the oldest were pruned a new copy still sorts last.
            let taken = ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).map(Self.historyOrder).filter { $0.0 == stamp }.map(\.1)
            let n = (taken.max() ?? 0) + 1
            let copy = folder.appendingPathComponent(n == 1 ? "\(stamp).md" : "\(stamp)-\(n).md")
            try old.write(to: copy, atomically: true, encoding: .utf8)
            saved = relativePath(copy)
            index?.indexHistory(ref: saved!, title: "Earlier version of \(relativePath(url))", text: old, at: now())
            pruneHistory(folder)
        }
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.text.write(to: url, atomically: true, encoding: .utf8)
        reindex(url, document)
        return saved
    }

    /// Keeps the newest `historyLimit` copies in a file's history folder.
    private func pruneHistory(_ folder: URL) {
        let copies = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".md") }
            .sorted { Self.historyOrder($0) < Self.historyOrder($1) }
        for name in copies.dropLast(Self.historyLimit) {
            let url = folder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            index?.removeHistory(ref: relativePath(url))
        }
    }

    /// A copy's time and, for copies written in the same millisecond, its number: `<time>.md` is 1, `<time>-2.md` is 2.
    nonisolated static func historyOrder(_ name: String) -> (String, Int) {
        let base = String(name.dropLast(".md".count))
        if let dash = base.lastIndex(of: "-"), base[..<dash].hasSuffix("Z"), let n = Int(base[base.index(after: dash)...]) {
            return (String(base[..<dash]), n)
        }
        return (base, 1)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS'Z'"
        return f
    }()

    private static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    private func reindex(_ url: URL, _ document: MemoryDocument) {
        index?.indexNotes(file: relativePath(url), title: title(url, document), entries: document.entries, modified: now())
    }

    /// Indexes every file's notes and every earlier version, for a first launch with the index.
    func reindexAll() {
        guard let index else { return }
        for file in files() { if let document = document(file.url) { reindex(file.url, document) } }
        let enumerator = FileManager.default.enumerator(at: historyRoot, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "md", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let at = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now()
            let ref = relativePath(url)
            // `historyFolder` turned the one `/` of a project path into `_`; any other `_` is part of the name.
            let folder = url.deletingLastPathComponent().lastPathComponent
            let original = folder.hasPrefix("projects_") ? "projects/" + folder.dropFirst("projects_".count) : folder
            index.indexHistory(ref: ref, title: "Earlier version of \(original)", text: text, at: at)
        }
    }

    private func log(_ url: URL, section: String?, _ action: MemoryChange.Action, note: String, previous: String?, source: String) {
        index?.record(at: now(), file: relativePath(url), section: section, action: action, note: note, previous: previous, source: source)
    }

    private func target(_ scope: MemoryScope, person: String?, project: ProjectKey?) -> Result<(URL, String?), MemoryError> {
        switch scope {
        case .people:
            guard let name = MemoryNote.personName(person) else { return .failure(MemoryError(message: "a note about a person needs the person's name")) }
            return .success((people, name))
        case .project:
            guard let project else { return .failure(MemoryError(message: "there is no project folder to keep a project note for")) }
            return .success((projectFile(project), nil))
        case .me:
            return .success((aboutMe, nil))
        }
    }

    /// Saves a note, dated today, in place of older ones it makes wrong. `replacing` names them by their text; ones not found are
    /// ignored. A note that is already there (compared without case and punctuation) is not added twice; the existing one comes back.
    @discardableResult
    func replace(_ replacing: [String], with raw: String, scope: MemoryScope, person: String? = nil, project: ProjectKey? = nil,
                 source: String) -> Result<MemoryNote, MemoryError> {
        let text: String
        switch MemoryNote.clean(raw) {
        case .success(let cleaned): text = cleaned
        case .failure(let rejection): return .failure(MemoryError(message: rejection.message))
        }
        let url: URL, section: String?
        switch target(scope, person: person, project: project) {
        case .success(let found): (url, section) = found
        case .failure(let failure): return .failure(failure)
        }
        var document = self.document(url) ?? MemoryDocument(header(for: url, project: project))
        let inSection = document.entries.filter { section == nil || $0.section?.caseInsensitiveCompare(section!) == .orderedSame }
        let key = MemoryNote.normalized(text)
        let old = Set(replacing.map(MemoryNote.normalized).filter { !$0.isEmpty && $0 != key })
        let removed = inSection.filter { old.contains(MemoryNote.normalized($0.note.text)) }
        guard removed.count <= MemoryNote.maxForget else {
            return .failure(MemoryError(message: "a note may replace at most \(MemoryNote.maxForget) others; \(removed.count) match"))
        }
        if removed.isEmpty, let existing = inSection.first(where: { MemoryNote.normalized($0.note.text) == key }) {
            return .success(existing.note)
        }
        document.remove(lineAt: removed.map(\.index) + inSection.filter { MemoryNote.normalized($0.note.text) == key }.map(\.index))
        let note = MemoryNote(text: text, date: MemoryNote.day(now(), calendar: calendar), source: source)
        document.append(note, section: section)
        do {
            try write(document, to: url)
        } catch {
            return .failure(MemoryError(message: "could not write \(relativePath(url)): \(error.localizedDescription)"))
        }
        if removed.isEmpty {
            log(url, section: section, .added, note: note.line, previous: nil, source: source)
        } else {
            log(url, section: section, .replaced, note: note.line, previous: removed.map(\.note.line).joined(separator: "\n"), source: source)
        }
        return .success(note)
    }

    /// Removes the notes that contain every word of `query`, in `scope` or in all of me, people and the project. The old file goes to
    /// `.history`, so nothing is lost. Refuses when nothing matches or more than `maxForget` notes do.
    func forget(_ query: String, scope: MemoryScope? = nil, person: String? = nil, project: ProjectKey? = nil, source: String) -> Result<[ForgottenNote], MemoryError> {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return .failure(MemoryError(message: "say which note to forget")) }
        let urls: [URL] = scope.map { [file($0, project: project)].compactMap { $0 } } ?? [aboutMe, people] + [project.map(projectFile)].compactMap { $0 }
        let name = MemoryNote.personName(person)
        var matches: [(URL, MemoryDocument.Entry)] = []
        for url in urls {
            guard let document = document(url) else { continue }
            for entry in document.entries {
                if let name, entry.section?.caseInsensitiveCompare(name) != .orderedSame { continue }
                let text = entry.note.text.lowercased()
                if words.allSatisfy(text.contains) { matches.append((url, entry)) }
            }
        }
        guard !matches.isEmpty else { return .failure(MemoryError(message: "no note matches \"\(query)\"")) }
        guard matches.count <= MemoryNote.maxForget else {
            let list = matches.prefix(10).map { "- \($0.1.note.text)" }.joined(separator: "\n")
            return .failure(MemoryError(message: "\(matches.count) notes match \"\(query)\"; nothing was removed. Be more specific:\n\(list)"))
        }
        var forgotten: [ForgottenNote] = []
        for url in Set(matches.map(\.0.path)).map(URL.init(fileURLWithPath:)) {
            guard var document = document(url) else { continue }
            let entries = matches.filter { $0.0.path == url.path }.map(\.1)
            document.remove(lineAt: entries.map(\.index))
            do { try write(document, to: url) } catch {
                let done = forgotten.isEmpty ? "" : " Already removed: " + forgotten.map(\.note.text).joined(separator: "; ") + "."
                return .failure(MemoryError(message: "could not write \(relativePath(url)): \(error.localizedDescription).\(done)"))
            }
            for entry in entries {
                log(url, section: entry.section, .forgot, note: entry.note.line, previous: nil, source: source)
                forgotten.append(ForgottenNote(file: relativePath(url), section: entry.section, note: entry.note))
            }
        }
        return .success(forgotten)
    }

    /// Writes a whole new version of a file: the Settings editor (`edited`) or a tidy pass (`tidied`). Undo goes back to the copy in
    /// `.history`.
    @discardableResult
    func rewrite(_ url: URL, with text: String, action: MemoryChange.Action, source: String, summary: String) -> Result<Void, MemoryError> {
        let document = MemoryDocument(text)
        guard document.text != self.document(url)?.text else { return .success(()) }
        do {
            let previous = try write(document, to: url)
            log(url, section: nil, action, note: summary, previous: previous, source: source)
            return .success(())
        } catch {
            return .failure(MemoryError(message: "could not write \(relativePath(url)): \(error.localizedDescription)"))
        }
    }

    // MARK: Undo

    func recentChanges(limit: Int = 20) -> [MemoryChange] { index?.changes(limit: limit) ?? [] }

    /// Reverses one change. Also writes a `.history` copy first, so an undo can itself be recovered. A note that changed since (edited,
    /// tidied) cannot be found, so that undo fails and the change stays as it is.
    @discardableResult
    func undo(_ change: MemoryChange) -> Result<Void, MemoryError> {
        guard !change.undone else { return .success(()) }
        let url = directory.appendingPathComponent(change.file)
        guard url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
            return .failure(MemoryError(message: "that change is outside the memory folder"))
        }
        var document = self.document(url) ?? MemoryDocument(header(for: url, project: nil))
        let changed = MemoryError(message: "that note has changed since; edit \(change.file) instead")
        func removeLine(_ line: String) -> Bool {
            guard let note = MemoryNote.parse(line) else { return false }
            let matching = document.entries.filter { $0.note == note && ($0.section ?? "") == (change.section ?? "") }
            document.remove(lineAt: matching.prefix(1).map(\.index))
            return !matching.isEmpty
        }
        func restore(_ line: String) {
            guard let note = MemoryNote.parse(line), !document.notes.contains(note) else { return }
            document.append(note, section: change.section)
        }
        switch change.action {
        case .added:
            guard removeLine(change.note) else { return .failure(changed) }
        case .forgot:
            restore(change.note)
        case .replaced:
            guard removeLine(change.note) else { return .failure(changed) }
            change.previous?.components(separatedBy: "\n").forEach(restore)
        case .tidied, .edited:
            // Going back to the whole earlier file would drop what was learned after it.
            if index?.hasLaterChange(to: change.file, after: change.id) == true {
                return .failure(MemoryError(message: "\(change.file) changed after this; undo the newer changes first, or edit the file"))
            }
            guard let previous = change.previous,
                  directory.appendingPathComponent(previous).standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/"),
                  let text = try? String(contentsOf: directory.appendingPathComponent(previous), encoding: .utf8) else {
                return .failure(MemoryError(message: "the earlier version of \(change.file) is gone"))
            }
            document = MemoryDocument(text)
        }
        do { try write(document, to: url) } catch {
            return .failure(MemoryError(message: "could not write \(change.file): \(error.localizedDescription)"))
        }
        index?.markUndone(change.id)
        return .success(())
    }

    // MARK: Reading for the prompt

    var editableFolder: URL? { directory }

    func location(_ scope: MemoryScope, project: ProjectKey?) -> String? {
        file(scope, project: project).map(relativePath)
    }

    func recall(_ scope: MemoryScope, project: ProjectKey?, bytes: Int, naming message: String) -> String {
        switch scope {
        case .me: return budgeted(aboutMe, bytes: bytes)
        case .project: return project.map { budgeted(projectFile($0), bytes: bytes) } ?? ""
        case .people: return budgeted(people, bytes: bytes, sections: peopleSections(named: message))
        }
    }

    /// The notes newest first, as whole lines, until the next one would pass `bytes`. When some are left out, one more line says how
    /// many and where to find them. Empty when the file has no notes.
    func budgeted(_ url: URL, bytes: Int, sections: [String]? = nil) -> String {
        guard let document = document(url) else { return "" }
        var entries = document.entries
        if let sections {
            let wanted = sections.map { $0.lowercased() }
            // Lines outside any `## Name` section (hand-written, or from older builds) stay in.
            entries = entries.filter { $0.section.map { wanted.contains($0.lowercased()) } ?? true }
        }
        return Self.budget(entries, bytes: bytes, grouped: sections != nil)
    }

    /// Newest first: by date, and later in the file first within a day. Hand-written lines have no date and count as the oldest.
    nonisolated static func budget(_ entries: [MemoryDocument.Entry], bytes: Int, grouped: Bool) -> String {
        let ordered = entries.sorted { a, b in
            let (da, db) = (a.note.date ?? "", b.note.date ?? "")
            return da != db ? da > db : a.index > b.index
        }
        var kept: [MemoryDocument.Entry] = [], used = 0
        for entry in ordered {
            let size = entry.note.line.utf8.count + 1
            if used + size > bytes { break }
            kept.append(entry)
            used += size
        }
        var lines: [String]
        if grouped {
            var order: [String] = []
            var bySection: [String: [String]] = [:]
            for entry in kept {
                let name = entry.section ?? ""
                if bySection[name] == nil { order.append(name) }
                bySection[name, default: []].append(entry.note.line)
            }
            lines = order.flatMap { ($0.isEmpty ? [] : ["## \($0)"]) + (bySection[$0] ?? []) }
        } else {
            lines = kept.map(\.note.line)
        }
        let left = entries.count - kept.count
        if left > 0 { lines.append("(\(left) older note\(left == 1 ? "" : "s") not shown; use memory_search to find them.)") }
        return lines.joined(separator: "\n")
    }

    /// The people to show for a first message: the ones it names, then the most recently noted, as many as fit.
    func peopleSections(named message: String) -> [String] {
        guard let document = document(people) else { return [] }
        let words = Set(message.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "'" }.map(String.init))
        let text = message.lowercased()
        let sections = document.sections
        let named = sections.filter { name in
            let lower = name.lowercased()
            return lower.contains(" ") ? text.contains(lower) : words.contains(lower)
        }
        let latest = Dictionary(grouping: document.entries.filter { $0.section != nil }, by: { $0.section! })
            .mapValues { $0.map { $0.note.date ?? "" }.max() ?? "" }
        let rest = sections.filter { !named.contains($0) }.sorted { (latest[$0] ?? "") > (latest[$1] ?? "") }
        return named + rest
    }

    // MARK: Housekeeping

    /// Deletes every memory file and earlier version, and their index. Chats and meetings stay where they are.
    func forgetEverything() {
        let files = FileManager.default
        for name in (try? files.contentsOfDirectory(atPath: directory.path)) ?? [] where name != Self.layoutMarker {
            try? files.removeItem(at: directory.appendingPathComponent(name))
        }
        index?.clearNotes()
    }

    static let layoutMarker = ".layout"

    /// Once per folder: deletes project files that hold only the header the old preamble wrote on every first chat, and moves files
    /// with notes for a folder that is now in a repo to the repo's file, merging when that file exists.
    func migrateLayout() {
        let files = FileManager.default
        let marker = directory.appendingPathComponent(Self.layoutMarker)
        guard !files.fileExists(atPath: marker.path) else { return }
        let folder = directory.appendingPathComponent("projects")
        for url in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "md" {
            guard let document = document(url) else { continue }
            if document.isHeaderOnly {
                try? files.removeItem(at: url)
                continue
            }
            guard let line = document.lines.first(where: { $0.hasPrefix("Workspace: ") }) else { continue }
            let workspace = URL(fileURLWithPath: String(line.dropFirst("Workspace: ".count)).trimmingCharacters(in: .whitespaces))
            guard files.fileExists(atPath: workspace.path) else { continue }
            let project = ProjectKey.of(workspace)
            let target = projectFile(project)
            guard project.isRepo, target.standardizedFileURL != url.standardizedFileURL else { continue }
            var merged: MemoryDocument
            if let existing = self.document(target) {
                merged = existing
                let known = Set(existing.notes.map { MemoryNote.normalized($0.text) })
                for note in document.notes where !known.contains(MemoryNote.normalized(note.text)) { merged.append(note) }
            } else {
                merged = document
                if let index = merged.lines.firstIndex(of: line) { merged.lines[index] = "Repo: \(project.key)" }
            }
            do {
                try write(merged, to: target)
                try files.removeItem(at: url)
            } catch {
                NSLog("ironpet: could not move \(relativePath(url)) to \(relativePath(target)): \(error.localizedDescription)")
            }
        }
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        try? "2\n".write(to: marker, atomically: true, encoding: .utf8)
    }
}
