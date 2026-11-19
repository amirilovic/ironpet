import Foundation

/// A reference from a notification to something that already exists: a page, a file, a chat thread, an agent session, a task or an
/// alert. Nothing is copied, so a link is only a pointer and can go stale.
struct NotificationLink: Equatable, Codable {
    enum Kind: String, CaseIterable, Codable { case url, file, thread, session, task, alert }
    var kind: Kind
    var ref: String
    var label: String?

    static let maxLinks = 10
    static let maxRef = 2048
    static let maxLabel = 200

    /// The link, or nil when the kind is unknown, the reference is empty or too long, or a `url` is not http(s).
    init?(kind: String, ref: String, label: String? = nil) {
        guard let kind = Kind(rawValue: kind) else { return nil }
        let ref = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty, ref.count <= Self.maxRef else { return nil }
        if kind == .url {
            guard let url = URL(string: ref), ["http", "https"].contains(url.scheme?.lowercased()), url.host?.isEmpty == false else { return nil }
        }
        self.kind = kind
        self.ref = ref
        let label = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = (label?.isEmpty ?? true) ? nil : String(label!.prefix(Self.maxLabel))
    }

    init(_ kind: Kind, _ ref: String, label: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.label = label
    }

    /// Reads the `links` of a script action or a tool call. A link that does not validate is dropped, and so is everything past
    /// `maxLinks`. `dropped` counts both, so the caller can say so.
    static func parse(_ value: Any?) -> (links: [NotificationLink], dropped: Int) {
        guard let list = value as? [Any] else { return ([], 0) }
        var links: [NotificationLink] = []
        var dropped = 0
        for item in list {
            guard let object = item as? [String: Any], let kind = object["kind"] as? String, let ref = object["ref"] as? String,
                  links.count < maxLinks, let link = NotificationLink(kind: kind, ref: ref, label: object["label"] as? String) else {
                dropped += 1
                continue
            }
            links.append(link)
        }
        return (links, dropped)
    }

    var json: [String: Any] {
        var object: [String: Any] = ["kind": kind.rawValue, "ref": ref]
        if let label { object["label"] = label }
        return object
    }

    /// What the row shows: the label, else the reference.
    var title: String { label ?? ref }
}

enum NotificationType: String, CaseIterable, Codable {
    case reminder, backgroundResult = "background_result", digest, alertAnnouncement = "alert_announcement", approval
    case scriptBubble = "script_bubble", other

    var title: String {
        switch self {
        case .reminder: return "Reminder"
        case .backgroundResult: return "Background result"
        case .digest: return "Digest"
        case .alertAnnouncement: return "Alert"
        case .approval: return "Approval"
        case .scriptBubble: return "Script"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .reminder: return "bell"
        case .backgroundResult: return "sparkles"
        case .digest: return "sun.horizon"
        case .alertAnnouncement: return "bell.badge"
        case .approval: return "hand.raised"
        case .scriptBubble: return "terminal"
        case .other: return "text.bubble"
        }
    }
}

/// Everything a notification stores before it has an id and a time.
struct NotificationDraft: Equatable {
    /// An automation id, or `system`.
    var source = NotificationItem.systemSource
    var type: NotificationType = .other
    var title: String
    /// What the bubble shows. Empty means the first line of the description.
    var summary = ""
    var description = ""
    var links: [NotificationLink] = []

    static let maxDescription = 64 * 1024
    static let maxTitle = 500
    static let maxSummary = 500
    static let summaryLength = 140

    /// The first line of `text`, or its first `summaryLength` characters when that line is longer. Markdown markers at the start of
    /// the line (`#`, `-`, `*`, `>`) are dropped so a heading reads as a title.
    static func summary(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let plain = line.drop { "#-*>".contains($0) || $0 == " " }
        let shown = plain.isEmpty ? Substring(line) : plain
        // Emphasis and code marks would show as stray characters in a bubble.
        let unmarked = shown.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return unmarked.count > summaryLength ? String(unmarked.prefix(summaryLength - 1)) + "…" : unmarked
    }

    /// Cuts the description at `maxDescription` bytes of UTF-8 without splitting a character.
    static func capped(_ text: String) -> String {
        guard text.utf8.count > maxDescription else { return text }
        var bytes = 0
        var end = text.startIndex
        for index in text.indices {
            let next = bytes + String(text[index]).utf8.count
            if next > maxDescription { break }
            bytes = next
            end = text.index(after: index)
        }
        return String(text[..<end]) + "\n(cut off)"
    }
}

/// One stored notification.
struct NotificationItem: Identifiable, Equatable {
    static let systemSource = "system"

    let id: String
    var created: Date
    var source: String
    var type: NotificationType
    var title: String
    var summary: String
    var description: String
    var read: Date?
    var links: [NotificationLink]

    var isUnread: Bool { read == nil }
}

extension NotificationItem {
    /// The fields an agent sees. `description` and `links` only with `full`.
    func json(full: Bool) -> [String: Any] {
        let format = ISO8601DateFormatter()
        format.timeZone = .current
        var object: [String: Any] = ["id": id, "created": format.string(from: created), "source": source,
                                     "type": type.rawValue, "title": title, "summary": summary, "read": !isUnread]
        if let read { object["read_at"] = format.string(from: read) }
        if full {
            object["description"] = description
            object["links"] = links.map(\.json)
        } else {
            object["link_count"] = links.count
        }
        return object
    }
}
