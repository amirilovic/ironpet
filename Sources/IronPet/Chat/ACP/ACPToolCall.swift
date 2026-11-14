import Foundation

/// A tool call as ACP describes it, from `tool_call`, `tool_call_update` and `session/request_permission`.
struct ACPToolCall {
    var id: String
    var title: String
    /// ACP's tool kind: read, edit, delete, move, search, execute, think, fetch, switch_mode or other.
    var kind: String
    var rawInput: Any?
    var paths: [String]
    /// The agent's own tool name when it gives one (the Claude adapter sends `_meta.claudeCode.toolName`).
    var toolName: String?

    init(id: String = "", title: String = "", kind: String = "other", rawInput: Any? = nil, paths: [String] = [], toolName: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.rawInput = rawInput
        self.paths = paths
        self.toolName = toolName
    }

    init(json: JSON) {
        self.init()
        merge(json)
    }

    /// Applies the fields an update carries; fields it leaves out keep their value.
    mutating func merge(_ json: JSON) {
        if let value = json["toolCallId"] as? String { id = value }
        if let value = json["title"] as? String, !value.isEmpty { title = value }
        if let value = json["kind"] as? String { kind = value }
        if let value = json["rawInput"], !(value is NSNull) { rawInput = value }
        if let locations = json["locations"] as? [JSON] {
            let found = locations.compactMap { $0["path"] as? String }
            if !found.isEmpty { paths = found }
        }
        if let name = ((json["_meta"] as? JSON)?["claudeCode"] as? JSON)?["toolName"] as? String { toolName = name }
    }

    var input: JSON { rawInput as? JSON ?? [:] }

    /// The shell command, from the arguments or, when the agent sends none, from a title like "`ls .`".
    var command: String {
        if let text = input["command"] as? String { return text }
        if let parts = input["command"] as? [String] { return parts.joined(separator: " ") }
        if let text = rawInput as? String { return text }
        return title.trimmingCharacters(in: CharacterSet(charactersIn: "` "))
    }

    /// The file a tool reads or changes.
    var path: String? {
        paths.first ?? (input["file_path"] ?? input["path"] ?? input["target_file"] ?? input["notebook_path"]) as? String
    }

    /// Everything the agent passes in, as text for the destructive-pattern check and the approval card.
    var arguments: String {
        if let text = rawInput as? String { return text }
        guard let object = rawInput, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Splits `mcp__server__tool` into its server and tool. Nil for tools that are not MCP names.
    var mcp: (server: String, tool: String)? {
        for name in [toolName, title] {
            guard let name, name.hasPrefix("mcp__") else { continue }
            let parts = name.components(separatedBy: "__")
            if parts.count >= 3 { return (parts[1], parts.dropFirst(2).joined(separator: "__")) }
        }
        return nil
    }

    /// One line for the transcript, e.g. "Ran `npm test`".
    var summary: String {
        let file = path.map { URL(fileURLWithPath: $0).lastPathComponent }
        switch kind {
        case "execute":
            let text = command.replacingOccurrences(of: "\n", with: " ")
            return "Ran `\(text.isEmpty ? "a command" : String(text.prefix(120)))`"
        case "edit": return "Edited \(file ?? "a file")"
        case "delete": return "Deleted \(file ?? "a file")"
        case "move": return "Moved \(file ?? "a file")"
        case "read": return "Read \(file ?? "a file")"
        case "search": return "Searched the codebase"
        case "fetch": return "Searched the web"
        default: return title.isEmpty ? "Used a tool" : title
        }
    }
}

enum ApprovalPolicy: Equatable {
    case allow
    case ask(title: String, detail: String)
}

enum ApprovalRules {
    /// Commands that still ask in Auto mode.
    static let destructive = try! NSRegularExpression(pattern: #"""
        \brm\s+-[a-zA-Z]*(rf|fr)|\brm\s+-[a-zA-Z]*r[a-zA-Z]*\s+-[a-zA-Z]*f|git\s+reset\s+--hard|git\s+push\b.*(--force|\s-f\b)|git\s+clean\s+-[a-zA-Z]*f|\bdrop\s+(table|database|schema)\b|\btruncate\s+table\b|\bmkfs\b|\bdd\s+if=
        """#, options: [.caseInsensitive])

    /// MCP tool name prefixes treated as read-only (e.g. Sentry `search_issues`, Langfuse `getHealth`).
    static let readOnlyMCPVerbs = ["get", "list", "search", "find", "fetch", "read", "describe", "whoami", "lookup", "show", "count"]

    static func isReadOnlyMCP(_ tool: String) -> Bool {
        let name = tool.lowercased()
        return readOnlyMCPVerbs.contains { name == $0 || name.hasPrefix($0 + "_") || name.hasPrefix($0) && tool.dropFirst($0.count).first?.isUppercase == true }
    }

    static func isDestructive(_ text: String) -> Bool {
        destructive.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Whether ironpet answers a permission request itself or shows a card. The agent only asks about calls it
    /// considers risky, so anything not clearly read-only still asks.
    static func policy(for call: ACPToolCall, auto: Bool, isMemoryFile: (String) -> Bool = Memory.contains) -> ApprovalPolicy {
        switch call.kind {
        case "read", "search", "think", "fetch":
            return .allow
        case "execute":
            let command = call.command
            let dangerous = isDestructive(command + "\n" + call.arguments)
            if auto, !dangerous { return .allow }
            return .ask(title: dangerous ? "Run a destructive command?" : "Run this command?", detail: command)
        case "edit", "delete", "move":
            let path = call.path
            if auto || path.map(isMemoryFile) == true { return .allow }
            let preview = ((call.input["content"] ?? call.input["new_string"] ?? call.input["new_source"]) as? String)?
                .split(separator: "\n", omittingEmptySubsequences: false).prefix(8).joined(separator: "\n")
            let verb = call.kind == "delete" ? "Delete" : call.kind == "move" ? "Move" : "Edit"
            let title = path.map { "\(verb) \(URL(fileURLWithPath: $0).lastPathComponent)?" } ?? "\(verb) a file?"
            return .ask(title: title, detail: [path, preview].compactMap { $0 }.joined(separator: "\n\n"))
        default:
            // MCP servers can change real systems (databases, issue trackers), so anything not read-only asks first.
            let mcp = call.mcp
            let tool = mcp?.tool ?? call.toolName ?? call.title
            if isReadOnlyMCP(tool) { return .allow }
            let arguments = call.arguments
            let dangerous = isDestructive(arguments)
            if auto, !dangerous { return .allow }
            let target = mcp.map { " (\($0.server))" } ?? ""
            return .ask(title: (dangerous ? "Run a destructive tool: " : "Use ") + tool + target + "?", detail: String(arguments.prefix(600)))
        }
    }
}
