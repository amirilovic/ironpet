import CryptoKit
import Foundation

/// The platform-neutral accessibility tree the capture rules read. It encodes to the same JSON as lookback's `Node`, so the
/// rules (copied from lookback) see the shape they were written for.
struct CaptureRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct CaptureNode: Codable, Equatable {
    var role: String
    var name: String?
    var value: String?
    var attrs: [String: String] = [:]
    var frame: CaptureRect?
    var focused = false
    var selected = false
    var hidden = false
    var children: [CaptureNode] = []

    init(role: String, name: String? = nil, value: String? = nil, attrs: [String: String] = [:], frame: CaptureRect? = nil,
         focused: Bool = false, selected: Bool = false, hidden: Bool = false, children: [CaptureNode] = []) {
        self.role = role
        self.name = name
        self.value = value
        self.attrs = attrs
        self.frame = frame
        self.focused = focused
        self.selected = selected
        self.hidden = hidden
        self.children = children
    }

    private enum Keys: String, CodingKey { case role, name, value, attrs, frame, focused, selected, hidden, children }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        role = try c.decode(String.self, forKey: .role)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        attrs = try c.decodeIfPresent([String: String].self, forKey: .attrs) ?? [:]
        frame = try c.decodeIfPresent(CaptureRect.self, forKey: .frame)
        focused = try c.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        children = try c.decodeIfPresent([CaptureNode].self, forKey: .children) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(value, forKey: .value)
        if !attrs.isEmpty { try c.encode(attrs, forKey: .attrs) }
        try c.encodeIfPresent(frame, forKey: .frame)
        if focused { try c.encode(true, forKey: .focused) }
        if selected { try c.encode(true, forKey: .selected) }
        if hidden { try c.encode(true, forKey: .hidden) }
        if !children.isEmpty { try c.encode(children, forKey: .children) }
    }

    /// A secure input is the secure role, or any role whose subrole contains "secure". No code reads a secure node's value.
    var isSecure: Bool {
        role == "SecureTextField" || (attrs["subrole"]?.lowercased().contains("secure") ?? false)
    }

    var count: Int { 1 + children.reduce(0) { $0 + $1.count } }

    /// The tree with every secure field's value, selection and placeholder removed.
    func scrubbed() -> CaptureNode {
        var node = self
        if node.isSecure {
            node.value = nil
            node.attrs["selected_text"] = nil
            node.attrs["placeholder"] = nil
        }
        node.children = node.children.map { $0.scrubbed() }
        return node
    }
}

struct CaptureApp: Codable, Equatable {
    var bundleId: String
    var name: String
    var pid: Int32 = 0

    private enum CodingKeys: String, CodingKey { case bundleId = "bundle_id", name, pid }

    init(bundleId: String, name: String, pid: Int32 = 0) {
        self.bundleId = bundleId
        self.name = name
        self.pid = pid
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = try c.decode(String.self, forKey: .bundleId)
        name = try c.decode(String.self, forKey: .name)
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
    }
}

struct CaptureSnapshot: Codable, Equatable {
    var app: CaptureApp
    var windowTitle: String?
    /// The page URL for browser windows. Not yet redacted.
    var url: String?
    var root: CaptureNode
    var capturedAt: Int64 = 0
    var truncated = false
    /// Text read from the screen in the regions the window's parser asked for, by region name, top line first.
    var ocr: [String: [String]] = [:]

    private enum CodingKeys: String, CodingKey {
        case app, windowTitle = "window_title", url, root, capturedAt = "captured_at", truncated, ocr
    }

    init(app: CaptureApp, windowTitle: String? = nil, url: String? = nil, root: CaptureNode, capturedAt: Int64 = 0,
         truncated: Bool = false, ocr: [String: [String]] = [:]) {
        self.app = app
        self.windowTitle = windowTitle
        self.url = url
        self.root = root
        self.capturedAt = capturedAt
        self.truncated = truncated
        self.ocr = ocr
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decode(CaptureApp.self, forKey: .app)
        windowTitle = try c.decodeIfPresent(String.self, forKey: .windowTitle)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        root = try c.decode(CaptureNode.self, forKey: .root)
        capturedAt = try c.decodeIfPresent(Int64.self, forKey: .capturedAt) ?? 0
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        ocr = try c.decodeIfPresent([String: [String]].self, forKey: .ocr) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(app, forKey: .app)
        try c.encodeIfPresent(windowTitle, forKey: .windowTitle)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encode(root, forKey: .root)
        try c.encode(capturedAt, forKey: .capturedAt)
        if truncated { try c.encode(true, forKey: .truncated) }
        if !ocr.isEmpty { try c.encode(ocr, forKey: .ocr) }
    }
}

struct CaptureMessage: Codable, Equatable {
    var author: String?
    var text: String
    /// The time exactly as the app shows it. Not parsed.
    var sentAt: String?
    var isMe: Bool?
    /// The user's unsent composer text. The store keeps only the latest draft per thread.
    var draft = false

    private enum CodingKeys: String, CodingKey { case author, text, sentAt = "sent_at", isMe = "is_me", draft }

    init(author: String? = nil, text: String, sentAt: String? = nil, isMe: Bool? = nil, draft: Bool = false) {
        self.author = author
        self.text = text
        self.sentAt = sentAt
        self.isMe = isMe
        self.draft = draft
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        text = try c.decode(String.self, forKey: .text)
        sentAt = try c.decodeIfPresent(String.self, forKey: .sentAt)
        isMe = try c.decodeIfPresent(Bool.self, forKey: .isMe)
        draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(author, forKey: .author)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(sentAt, forKey: .sentAt)
        try c.encodeIfPresent(isMe, forKey: .isMe)
        if draft { try c.encode(true, forKey: .draft) }
    }

    /// The fingerprint used to diff captures: a hash of the author ("unknown" when absent), the time and the text.
    var id: String {
        let basis = "\(author ?? "unknown")\u{1F}\(sentAt ?? "")\u{1F}\(text)"
        return CaptureHash.hex(basis, length: 24)
    }
}

enum CaptureContent: Codable, Equatable {
    case conversation(title: String, isGroup: Bool, messages: [CaptureMessage])
    case document(title: String, text: String)
    case page(title: String, text: String)

    private enum Keys: String, CodingKey { case kind, title, isGroup = "is_group", messages, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        switch try c.decode(String.self, forKey: .kind) {
        case "conversation":
            self = .conversation(title: title, isGroup: try c.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false,
                                 messages: try c.decode([CaptureMessage].self, forKey: .messages))
        case "document": self = .document(title: title, text: try c.decode(String.self, forKey: .text))
        case "page": self = .page(title: title, text: try c.decode(String.self, forKey: .text))
        case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown content kind \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .conversation(let title, let isGroup, let messages):
            try c.encode("conversation", forKey: .kind)
            try c.encode(title, forKey: .title)
            if isGroup { try c.encode(true, forKey: .isGroup) }
            try c.encode(messages, forKey: .messages)
        case .document(let title, let text):
            try c.encode("document", forKey: .kind)
            try c.encode(title, forKey: .title)
            try c.encode(text, forKey: .text)
        case .page(let title, let text):
            try c.encode("page", forKey: .kind)
            try c.encode(title, forKey: .title)
            try c.encode(text, forKey: .text)
        }
    }

    var kindName: String {
        switch self {
        case .conversation: return "conversation"
        case .document: return "document"
        case .page: return "page"
        }
    }

    var isEmpty: Bool {
        switch self {
        case .conversation(_, _, let messages): return messages.isEmpty
        case .document(_, let text), .page(_, let text): return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// What a parser rule produces for one window.
struct CaptureItem: Codable, Equatable {
    var app: CaptureApp
    /// Redacted. Never contains secret parameters.
    var url: String?
    var windowTitle: String?
    var threadKey: String
    var threadTitle: String
    /// Slack workspace, Outlook or Teams tenant, mail account.
    var account: String?
    var content: CaptureContent
    var parser: String
    var truncated = false

    private enum CodingKeys: String, CodingKey {
        case app, url, windowTitle = "window_title", threadKey = "thread_key", threadTitle = "thread_title", account, content, parser, truncated
    }

    init(app: CaptureApp, url: String? = nil, windowTitle: String? = nil, threadKey: String, threadTitle: String, account: String? = nil,
         content: CaptureContent, parser: String, truncated: Bool = false) {
        self.app = app
        self.url = url
        self.windowTitle = windowTitle
        self.threadKey = threadKey
        self.threadTitle = threadTitle
        self.account = account
        self.content = content
        self.parser = parser
        self.truncated = truncated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decode(CaptureApp.self, forKey: .app)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        windowTitle = try c.decodeIfPresent(String.self, forKey: .windowTitle)
        threadKey = try c.decode(String.self, forKey: .threadKey)
        threadTitle = try c.decode(String.self, forKey: .threadTitle)
        account = try c.decodeIfPresent(String.self, forKey: .account)
        content = try c.decode(CaptureContent.self, forKey: .content)
        parser = try c.decode(String.self, forKey: .parser)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(app, forKey: .app)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(windowTitle, forKey: .windowTitle)
        try c.encode(threadKey, forKey: .threadKey)
        try c.encode(threadTitle, forKey: .threadTitle)
        try c.encodeIfPresent(account, forKey: .account)
        try c.encode(content, forKey: .content)
        try c.encode(parser, forKey: .parser)
        if truncated { try c.encode(true, forKey: .truncated) }
    }
}

enum CaptureHash {
    /// The SHA-256 of `text` as lowercase hex, cut to `length` characters when given.
    static func hex(_ text: String, length: Int? = nil) -> String {
        let full = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return length.map { String(full.prefix($0)) } ?? full
    }
}

enum CaptureJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func string<T: Encodable>(_ value: T) -> String? {
        (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(text.utf8))
    }
}
