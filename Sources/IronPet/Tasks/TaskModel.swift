import Foundation

/// Where a task stands. The agent moves tasks between these; the user only marks them done.
enum TaskStatus: String, CaseIterable, Codable {
    case backlog
    case inProgress = "in_progress"
    case needsYou = "needs_you"
    case done

    var title: String {
        switch self {
        case .backlog: return "Backlog"
        case .inProgress: return "In progress"
        case .needsYou: return "Needs you"
        case .done: return "Done"
        }
    }
}

/// What created a task. Shown as a symbol in the list.
enum TaskSource: String, CaseIterable, Codable {
    case chat, telegram, meeting, automation, cli, agent, user, capture, email, pr

    var symbol: String {
        switch self {
        case .chat: return "bubble.left"
        case .telegram: return "paperplane"
        case .meeting: return "person.2"
        case .automation: return "clock.badge.checkmark"
        case .cli: return "terminal"
        case .agent: return "sparkles"
        case .user: return "person"
        case .capture: return "text.viewfinder"
        case .email: return "envelope"
        case .pr: return "arrow.triangle.pull"
        }
    }

    /// The kinds an agent may name in a task's `origin`. Telegram and the CLI are ways in, not origins.
    static let originKinds: [TaskSource] = [.chat, .agent, .meeting, .capture, .automation, .email, .pr, .user]
}

/// Something a task points at: a chat thread, a watched agent session, a URL or a file.
struct TaskLink: Equatable, Codable {
    enum Kind: String, CaseIterable, Codable { case thread, session, url, file }
    var kind: Kind
    var ref: String
    var label: String?
}

struct TaskItem: Identifiable, Equatable {
    let id: String
    var title: String
    var notes: String
    var status: TaskStatus
    var source: TaskSource
    var due: Date?
    var links: [TaskLink]
    var created: Date
    var updated: Date
    var closed: Date?
    /// Who the user is waiting on (`Ana`, `Them`). Nil for the user's own work.
    var waitingOn: String? = nil
    /// Where the task came from, for diagnostics: a JSON object such as `{"meeting": "/path"}`. Nil when unknown.
    var sourceRef: String? = nil
    /// Key/value labels such as `merge=auto`. Data for filtering, never instructions.
    var labels: [String: String] = [:]

    /// Only the user can take the next step. A task waiting on someone else never counts, whatever its status.
    var needsUser: Bool { status == .needsYou && waitingOn == nil }
}

/// One line of a task's history: created, a status change, a note, closed. Nothing is overwritten, so a task the agent
/// rewrote can still be traced.
struct TaskEvent: Equatable {
    enum Kind: String { case created, status, edited, note, closed, deleted }
    var at: Date
    /// `user`, `agent:mcp`, `agent:cli`, `meeting`.
    var by: String
    var kind: Kind
    var detail: String
}

/// An action item from a meeting summary, or a task a watcher automation proposed, that waits for Add or Skip.
/// It is text only and never sent to an agent.
struct TaskSuggestion: Identifiable, Equatable {
    enum Origin: Equatable {
        /// The meeting folder.
        case meeting(URL)
        case automation(id: String, name: String)
    }

    /// One suggestion before it is stored: a meeting action item, or what a watcher returned in a `suggest_task` action
    /// (cleaned by `init?(action:)`).
    struct Draft: Equatable {
        /// The action's `id`, unique within its automation.
        var key: String
        var title: String
        var due: String?
        var notes = ""
        var url: URL?
        /// The owner of a meeting action item that is not the user. Watchers never set it.
        var waitingOn: String?
    }

    let id: String
    var title: String
    /// Free text from a meeting ("Friday"); `yyyy-MM-dd` from an automation.
    var due: String?
    var notes = ""
    var url: URL?
    var origin: Origin
    var created: Date
    /// The owner when it is not the user, so the task becomes one they wait on.
    var waitingOn: String? = nil
    /// Where the suggestion came from, for diagnostics: a JSON object. Copied to the task on accept.
    var sourceRef: String? = nil

    var meeting: URL? {
        if case .meeting(let url) = origin { return url }
        return nil
    }

    /// The source of the task it becomes.
    var source: TaskSource {
        switch origin {
        case .meeting: return .meeting
        case .automation: return .automation
        }
    }

    /// "Meeting", or "From" and the automation's name.
    var originLabel: String {
        switch origin {
        case .meeting: return "Meeting"
        case .automation(_, let name): return "From \(name)"
        }
    }
}

extension TaskSuggestion.Draft {
    static let maxKey = 200
    static let maxTitle = 200
    static let maxNotes = 2000
    static let maxURL = 2048

    /// Reads a script's `{type: "suggest_task", id, title, due?, notes?, url?}`. The text comes from outside (mail, chat,
    /// issues), so it is clamped and stripped of control characters, and a due or url that does not parse is dropped.
    init(action: [String: Any]) throws {
        func string(_ key: String) -> String? {
            guard let value = action[key], !(value is NSNull) else { return nil }
            return (value as? String) ?? "\(value)"
        }
        let key = Self.clean(string("id") ?? "", limit: Self.maxKey, newlines: false)
        guard !key.isEmpty else { throw TaskError(message: "a suggest_task needs an id") }
        let title = Self.clean(string("title") ?? "", limit: Self.maxTitle, newlines: false)
        guard !title.isEmpty else { throw TaskError(message: "a suggest_task needs a title") }
        self.key = key
        self.title = title
        if let raw = string("due")?.trimmingCharacters(in: .whitespaces), raw.count == 10, (try? TaskValidator.due(raw)) != nil {
            due = raw
        }
        notes = Self.clean(string("notes") ?? "", limit: Self.maxNotes, newlines: true)
        while notes.utf8.count > TaskValidator.maxNotes { notes.removeLast() }
        if let raw = string("url")?.trimmingCharacters(in: .whitespaces), raw.count <= Self.maxURL, let url = URL(string: raw),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false {
            self.url = url
        }
    }

    /// Drops control characters and bidirectional overrides, folds runs of whitespace in single-line text, trims and clamps.
    static func clean(_ text: String, limit: Int, newlines: Bool) -> String {
        let bidi = Set<UInt32>([0x061C, 0x200E, 0x200F] + Array(0x202A...0x202E) + Array(0x2066...0x2069))
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if bidi.contains(scalar.value) { continue }
            if newlines && scalar == "\n" { scalars.append(scalar); continue }
            if scalar == "\t" || scalar == "\n" || scalar == "\r" { scalars.append(" "); continue }
            if scalar.properties.generalCategory == .control { continue }
            scalars.append(scalar)
        }
        var result = String(scalars)
        if !newlines { result = result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.count > limit ? String(result.prefix(limit)).trimmingCharacters(in: .whitespaces) : result
    }
}

extension TaskItem {
    /// "Waiting on Ana", "Waiting on them". Nil for the user's own work.
    var waitingLabel: String? { waitingOn.map(describeWaiting) }
}

extension TaskSuggestion {
    var waitingLabel: String? { waitingOn.map(describeWaiting) }
}

private func describeWaiting(_ owner: String) -> String {
    "Waiting on \(owner.caseInsensitiveCompare("them") == .orderedSame ? "them" : owner)"
}

struct TaskError: Error, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Checks agent and CLI input before it reaches the database.
enum TaskValidator {
    static let maxTitle = 200
    static let maxNotes = 4096
    static let maxLinks = 10
    static let maxWaitingOn = 100
    static let maxLabels = 20
    static let maxLabelKey = 40
    static let maxLabelValue = 100

    /// A label key: one word with no whitespace, control characters, `=` or `,`.
    static func labelKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TaskError(message: "label key is empty") }
        guard key.count <= maxLabelKey else { throw TaskError(message: "label key \"\(key)\" is longer than \(maxLabelKey) characters") }
        guard !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.properties.generalCategory == .control || $0 == "=" || $0 == "," }) else {
            throw TaskError(message: "label key \"\(key)\" must not contain whitespace, \"=\" or \",\"")
        }
        return key
    }

    /// A `{key: value}` object. Values are strings (numbers and booleans are written as text) on one line.
    static func labels(_ value: Any?) throws -> [String: String] {
        guard let value, !(value is NSNull) else { return [:] }
        guard let object = value as? [String: Any] else { throw TaskError(message: "labels must be an object of key/value strings") }
        var result: [String: String] = [:]
        for (rawKey, rawValue) in object {
            let key = try labelKey(rawKey)
            guard result[key] == nil else { throw TaskError(message: "label key \"\(key)\" is given twice") }
            let text: String
            if let string = rawValue as? String { text = string }
            else if let number = rawValue as? NSNumber { text = "\(number)" }
            else { throw TaskError(message: "label \"\(key)\" must have a string value") }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { throw TaskError(message: "label \"\(key)\" has an empty value") }
            guard !clean.contains("\n"), clean.count <= maxLabelValue else {
                throw TaskError(message: "label \"\(key)\" must be one line of at most \(maxLabelValue) characters")
            }
            result[key] = clean
        }
        return result
    }

    /// A list of keys to remove.
    static func labelKeys(_ value: Any?) throws -> [String] {
        guard let value, !(value is NSNull) else { return [] }
        let list = (value as? [Any]) ?? [value]
        return try list.map { item in
            guard let raw = item as? String else { throw TaskError(message: "remove_labels must be a list of keys") }
            return try labelKey(raw)
        }
    }

    static func title(_ value: Any?) throws -> String {
        guard let raw = value as? String else { throw TaskError(message: "title must be a string") }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !title.isEmpty else { throw TaskError(message: "title is empty") }
        guard title.count <= maxTitle else { throw TaskError(message: "title is longer than \(maxTitle) characters") }
        return title
    }

    static func notes(_ value: Any?) throws -> String {
        guard let value, !(value is NSNull) else { return "" }
        guard let notes = value as? String else { throw TaskError(message: "notes must be a string") }
        guard notes.utf8.count <= maxNotes else { throw TaskError(message: "notes are longer than \(maxNotes) bytes") }
        return notes
    }

    static func status(_ value: Any?) throws -> TaskStatus {
        guard let raw = value as? String, let status = TaskStatus(rawValue: raw) else {
            throw TaskError(message: "status must be one of \(TaskStatus.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return status
    }

    static func source(_ value: Any?, default fallback: TaskSource) throws -> TaskSource {
        guard let value, !(value is NSNull) else { return fallback }
        guard let raw = value as? String, let source = TaskSource(rawValue: raw) else {
            throw TaskError(message: "source must be one of \(TaskSource.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return source
    }

    /// A person's name on one line. Null or blank clears it.
    static func waitingOn(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = value as? String else { throw TaskError(message: "waiting_on must be a string") }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard name.count <= maxWaitingOn else { throw TaskError(message: "waiting_on is longer than \(maxWaitingOn) characters") }
        return name.isEmpty ? nil : name
    }

    /// ISO 8601 with a time (`2026-11-20T15:30:00+01:00`) or a plain date (`2026-11-20`, local midnight). Null clears it.
    static func due(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = value as? String else { throw TaskError(message: "due must be an ISO 8601 date") }
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        if let date = day.date(from: raw) { return date }
        throw TaskError(message: "due \"\(raw)\" is not an ISO 8601 date such as 2026-11-20 or 2026-11-20T15:30:00+01:00")
    }

    static func links(_ value: Any?) throws -> [TaskLink] {
        guard let value, !(value is NSNull) else { return [] }
        guard let list = value as? [[String: Any]] else { throw TaskError(message: "links must be a list of {kind, ref, label?}") }
        guard list.count <= maxLinks else { throw TaskError(message: "at most \(maxLinks) links") }
        return try list.map { item in
            guard let raw = item["kind"] as? String, let kind = TaskLink.Kind(rawValue: raw) else {
                throw TaskError(message: "link kind must be one of \(TaskLink.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            guard let ref = (item["ref"] as? String)?.trimmingCharacters(in: .whitespaces), !ref.isEmpty, ref.count <= 2048 else {
                throw TaskError(message: "link ref must be a non-empty string")
            }
            if kind == .url, URL(string: ref)?.scheme.map({ ["http", "https"].contains($0.lowercased()) }) != true {
                throw TaskError(message: "url links must be http or https")
            }
            return TaskLink(kind: kind, ref: ref, label: (item["label"] as? String).map { String($0.prefix(100)) })
        }
    }
}
