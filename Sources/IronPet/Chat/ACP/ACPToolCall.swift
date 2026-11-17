import Foundation

/// A tool call as ACP describes it, from `tool_call`, `tool_call_update` and `session/request_permission`.
struct ACPToolCall {
    var id: String
    var title: String
    /// ACP's tool kind: read, edit, delete, move, search, execute, think, fetch, switch_mode or other.
    var kind: String
    var rawInput: Any?
    var paths: [String]
    /// Paths named in `content` entries (`path`, `oldPath`, `newPath`, also inside their `_meta`), kept across updates.
    /// codex-acp puts a rename's destination only here: its `locations` list the sources.
    var contentPaths: [String] = []
    /// The agent's own tool name when it gives one (the Claude adapter sends `_meta.claudeCode.toolName`).
    var toolName: String?
    /// The tool call of the subagent this call runs under. The Claude adapter stamps `_meta.claudeCode.parentToolUseId`
    /// on every update that comes from a subagent, including a background one. Nil for the main agent's own calls.
    var parentToolUseID: String?

    init(id: String = "", title: String = "", kind: String = "other", rawInput: Any? = nil, paths: [String] = [], toolName: String? = nil,
         parentToolUseID: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.rawInput = rawInput
        self.paths = paths
        self.toolName = toolName
        self.parentToolUseID = parentToolUseID
    }

    /// The parent tool-use id an update's `_meta` names, if it comes from a subagent.
    static func parentID(in update: JSON) -> String? {
        let id = (((update["_meta"] as? JSON)?["claudeCode"] as? JSON)?["parentToolUseId"]) as? String
        return id?.isEmpty == false ? id : nil
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
        if let content = json["content"] as? [JSON] {
            for path in Self.paths(inContent: content) where !contentPaths.contains(path) { contentPaths.append(path) }
        }
        if let name = ((json["_meta"] as? JSON)?["claudeCode"] as? JSON)?["toolName"] as? String { toolName = name }
        if let parent = Self.parentID(in: json) { parentToolUseID = parent }
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

    static let pathKeys = ["file_path", "path", "target_file", "notebook_path", "destination", "new_path", "target", "source"]

    static let contentPathKeys = ["path", "oldPath", "newPath"]

    /// The paths in `content` entries and one level into their `_meta` (codex-acp's git patch keeps `oldPath` there).
    static func paths(inContent content: [JSON]) -> [String] {
        var found: [String] = []
        func collect(_ object: JSON) {
            for key in contentPathKeys {
                if let text = object[key] as? String, !text.isEmpty, !found.contains(text) { found.append(text) }
            }
        }
        for entry in content {
            collect(entry)
            if let meta = entry["_meta"] as? JSON {
                collect(meta)
                for case let nested as JSON in meta.values { collect(nested) }
            }
        }
        return found
    }

    /// Every file the call names: its locations, the path keys of its input and of a list of edits in it, and the keys
    /// of a map keyed by path (Codex's `changes`; elsewhere only keys that look like absolute or home paths).
    var allPaths: [String] {
        var found = paths + contentPaths
        func collect(_ object: JSON) {
            for key in Self.pathKeys {
                if let text = object[key] as? String, !text.isEmpty { found.append(text) }
            }
        }
        collect(input)
        for (name, value) in input {
            if let list = value as? [JSON] { list.forEach(collect) }
            if let map = value as? JSON {
                found += map.keys.filter { name == "changes" || $0.hasPrefix("/") || $0.hasPrefix("~") }.sorted()
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
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
    /// Answered with a refusal and no card, whatever the user's Auto setting. Only task runs get it.
    case refuse(String)
}

/// What a task run adds to the rules: it works in its own git worktree, asks before every change and never pushes.
struct RunScope: Equatable {
    /// The worktree. A card for a change outside it says so.
    let root: URL

    /// Compares real locations, so a symlink in the worktree that points outside it counts as outside. `~` and `$HOME`
    /// mean the home folder, as in a shell, not a folder of that name in the worktree.
    /// A path a shell would expand differently (`~user`, `$VAR`) or a URL counts as outside.
    func contains(_ path: String) -> Bool {
        relative(path) != nil
    }

    /// The path's components under the worktree, after resolving it. Nil when it is outside or cannot be placed.
    func relative(_ path: String) -> [String]? {
        var path = path
        if path == "~" || path.hasPrefix("~/") { path = (path as NSString).expandingTildeInPath }
        if path == "$HOME" || path.hasPrefix("$HOME/") { path = NSHomeDirectory() + path.dropFirst("$HOME".count) }
        if path.hasPrefix("~") || path.contains("$") || path.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil {
            return nil
        }
        let base = Self.resolve(root.path)
        let target = Self.resolve(path.hasPrefix("/") ? path : root.appendingPathComponent(path).path)
        if target == base { return [] }
        guard target.hasPrefix(base + "/") else { return nil }
        return target.dropFirst(base.count + 1).split(separator: "/").map(String.init)
    }

    /// The path with every symlink followed, including a dangling one, and the rest under the closest existing folder.
    /// `/private/var` and `/var` come out the same.
    static func resolve(_ path: String, depth: Int = 0) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let files = FileManager.default
        if depth < 32, let destination = try? files.destinationOfSymbolicLink(atPath: url.path) {
            let next = destination.hasPrefix("/") ? destination : url.deletingLastPathComponent().appendingPathComponent(destination).path
            return resolve(next, depth: depth + 1)
        }
        if url.path == "/" || files.fileExists(atPath: url.path) { return url.resolvingSymlinksInPath().path }
        let parent = resolve(url.deletingLastPathComponent().path, depth: depth)
        return URL(fileURLWithPath: parent).appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
    }
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

    /// ironpet's own task tools only read and write rows in `ironpet.db` and run nothing, like memory-note edits. Delete still asks.
    static let ownTaskTools: Set<String> = ["tasks_list", "tasks_get", "tasks_create", "tasks_update", "tasks_close"]

    /// Agents that name MCP tools `mcp__<server>__<tool>` must name the ironpet server; others report the bare tool name.
    static func isOwnTaskTool(server: String?, tool: String) -> Bool {
        guard ownTaskTools.contains(tool) else { return false }
        return server == nil || server == "ironpet"
    }

    static func isDestructive(_ text: String) -> Bool {
        destructive.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Commands that publish work or change where it goes. A task run never runs them: the user pushes with Open PR.
    /// `git -C dir push` counts; `git stash push` does not.
    static let pushOrPR = try! NSRegularExpression(pattern: #"""
        \bgit\s+(?:-[cC]\s+\S+\s+|--?[a-z-]+(?:=\S+)?\s+)*(?:push|remote\s+(?:add|set-url))\b|\bgh\s+pr\s+(?:create|merge)\b
        """#, options: [.caseInsensitive])

    static let refusedInRun = "ironpet does not let a task run push, open a PR or change remotes. The user pushes with Open PR in ironpet. Commit your work and stop."

    static func isPushOrPR(_ text: String) -> Bool {
        pushOrPR.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// A path into a `.git` folder or file, or the hooks setting. `.gitignore`, `.github` and `repo.git` do not count.
    static let gitInternals = try! NSRegularExpression(pattern: #"(?<![\w.-])\.git(?![\w.-])|core\.hookspath"#, options: [.caseInsensitive])

    /// The git subcommand and its arguments for every `git` in a command line, split at `&&`, `||`, `;`, `|`, `&` and
    /// new lines, with the options before the subcommand (`-C dir`, `-c key=value`, `--git-dir=...`) skipped.
    static func gitInvocations(_ text: String) -> [[String]] {
        let segments = text.components(separatedBy: CharacterSet(charactersIn: ";|&\n"))
        var found: [[String]] = []
        for segment in segments {
            let words = segment.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"`()")) }
            var index = 0
            while index < words.count {
                defer { index += 1 }
                guard words[index] == "git" || words[index].hasSuffix("/git") else { continue }
                var next = index + 1
                while next < words.count, words[next].hasPrefix("-") {
                    let option = words[next]
                    next += ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"].contains(option) ? 2 : 1
                }
                guard next < words.count else { continue }
                found.append(Array(words[next...]))
                index = next
            }
        }
        return found
    }

    /// Why a command changes git state the worktree shares with the user's copy (config, other branches, stashes,
    /// tags, hooks, worktrees, remotes), or nil. A task run asks about these even in Auto: they could change what
    /// Open PR pushes, or the user's own repository.
    static func sharedGitChange(_ text: String) -> String? {
        if gitInternals.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return "It touches the repository's .git folder or its hooks, which the user's copy shares."
        }
        func isRunRef(_ name: String) -> Bool {
            name.hasPrefix("ironpet/") || name.hasPrefix("refs/heads/ironpet/")
        }
        for words in gitInvocations(text) {
            guard let command = words.first?.lowercased() else { continue }
            let arguments = Array(words.dropFirst())
            let flags = arguments.filter { $0.hasPrefix("-") }
            let names = arguments.filter { !$0.hasPrefix("-") }
            switch command {
            case "config":
                let reads: Set<String> = ["--get", "--get-all", "--list", "-l", "--get-regexp"]
                if !flags.contains(where: reads.contains) { return "git config changes settings the user's copy shares." }
            case "branch":
                let changes: Set<String> = ["-d", "-D", "-f", "-m", "-M", "--delete", "--force", "--move", "-c", "-C", "--copy"]
                if flags.contains(where: changes.contains) || flags.contains(where: { $0.hasPrefix("--set-upstream") || $0 == "-u" }),
                   names.isEmpty || !names.allSatisfy(isRunRef) {
                    return "It changes a branch other than the task's own ironpet/ branch."
                }
            case "update-ref":
                if flags.contains("--stdin") || !(names.first.map(isRunRef) ?? false) {
                    return "It moves a ref other than the task's own ironpet/ branch."
                }
            case "symbolic-ref":
                if !names.allSatisfy({ $0 == "HEAD" || isRunRef($0) }) { return "It points a ref outside the task's own ironpet/ branch." }
            case "stash":
                if let action = names.first, ["drop", "clear", "pop"].contains(action) { return "Stashes are shared with the user's copy." }
            case "tag":
                if flags.contains("-d") || flags.contains("--delete") { return "Tags are shared with the user's copy." }
            case "worktree":
                return "Worktrees are listed in the user's repository."
            case "remote":
                if let action = names.first, !["show", "get-url"].contains(action) { return "Remotes are shared with the user's copy." }
            case "reflog":
                if names.first == "expire" { return "It expires history the user's copy shares." }
            case "gc":
                if flags.contains(where: { $0.hasPrefix("--prune") }) { return "It prunes objects the user's copy shares." }
            default:
                break
            }
        }
        return nil
    }

    /// Whether ironpet answers a permission request itself or shows a card. The agent only asks about calls it
    /// considers risky, so anything not clearly read-only still asks. A task run (`run`) has its own rules, where Auto does not apply.
    static func policy(for call: ACPToolCall, auto: Bool, isMemoryFile: (String) -> Bool = Memory.contains,
                       run: RunScope? = nil) -> ApprovalPolicy {
        if let run { return runPolicy(for: call, run: run) }
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
            if isReadOnlyMCP(tool) || isOwnTaskTool(server: mcp?.server, tool: tool) { return .allow }
            let arguments = call.arguments
            let dangerous = isDestructive(arguments)
            if auto, !dangerous { return .allow }
            let target = mcp.map { " (\($0.server))" } ?? ""
            return .ask(title: (dangerous ? "Run a destructive tool: " : "Use ") + tool + target + "?", detail: String(arguments.prefix(600)))
        }
    }

    /// Arguments that carry new content or a destination. A call with one may write, whatever kind it claims.
    static let writeArguments: Set<String> = ["content", "new_string", "old_string", "new_source", "newText", "edits", "changes",
                                              "destination", "new_path", "newPath", "patch", "diff"]

    /// A read, search, think or fetch call that names nothing it could write: no diff in its content, no write arguments,
    /// and for think and fetch no file at all. Gemini's `save_memory` is a think call with a diff of `~/.gemini/GEMINI.md`.
    static func isReadOnlyInRun(_ call: ACPToolCall) -> Bool {
        guard call.contentPaths.isEmpty, !call.input.keys.contains(where: writeArguments.contains) else { return false }
        switch call.kind {
        case "read", "search": return true
        case "think", "fetch": return call.allPaths.isEmpty
        default: return false
        }
    }

    /// A task run asks before every call that could change anything, whatever the Auto setting: only `isReadOnlyInRun`
    /// calls skip the card. Commands that match `pushOrPR` are refused and `sharedGitChange` ones ask with the reason.
    static func runPolicy(for call: ACPToolCall, run: RunScope) -> ApprovalPolicy {
        // A command, extra sandbox permissions or network access is judged as a command, whatever kind the call claims.
        let command = runCommand(call)
        if command != nil || grantsAccess(call) { return commandPolicy(call, command: command) }
        if isReadOnlyInRun(call) { return .allow }
        let all = call.allPaths
        let place = all.contains { !run.contains($0) } ? " outside the task's copy" : ""
        let files = all.isEmpty ? nil : all.joined(separator: "\n")
        switch call.kind {
        case "edit", "delete", "move":
            let preview = ((call.input["content"] ?? call.input["new_string"] ?? call.input["new_source"]) as? String)?
                .split(separator: "\n", omittingEmptySubsequences: false).prefix(8).joined(separator: "\n")
            let verb = call.kind == "delete" ? "Delete" : call.kind == "move" ? "Move" : "Edit"
            let title = all.first.map { "\(verb) \(URL(fileURLWithPath: $0).lastPathComponent)\(place)?" } ?? "\(verb) a file?"
            return .ask(title: title, detail: [files, preview].compactMap { $0 }.joined(separator: "\n\n"))
        case "read", "search", "think", "fetch":
            let name = call.title.isEmpty ? "this tool" : call.title
            return .ask(title: "Let \(name) write files\(place)?",
                        detail: [files, String(call.arguments.prefix(600))].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        default:
            let mcp = call.mcp
            let tool = mcp?.tool ?? call.toolName ?? (call.title.isEmpty ? "a tool" : call.title)
            let target = mcp.map { " (\($0.server))" } ?? ""
            let dangerous = isDestructive(call.arguments)
            return .ask(title: (dangerous ? "Run a destructive tool: " : "Use ") + tool + target + "?",
                        detail: [files, String(call.arguments.prefix(600))].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
    }

    /// Extra sandbox permissions or network access, as codex-acp asks for them.
    static func grantsAccess(_ call: ACPToolCall) -> Bool {
        let input = call.input
        if input["additionalPermissions"] != nil || input["permissions"] != nil { return true }
        guard call.kind != "fetch", let url = input["url"] as? String else { return false }
        return url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://")
    }

    /// A shell command or an access request in a task run: always a card, refused when it plainly pushes or opens a PR.
    static func commandPolicy(_ call: ACPToolCall, command: String?) -> ApprovalPolicy {
        let text = (command ?? "") + "\n" + call.arguments
        if isPushOrPR(text) { return .refuse(refusedInRun) }
        if let reason = sharedGitChange(text) {
            return .ask(title: "Change the project's shared git setup?", detail: (command ?? call.title) + "\n\n" + reason)
        }
        guard let command else {
            let network = call.input["url"] != nil && call.input["additionalPermissions"] == nil && call.input["permissions"] == nil
            return .ask(title: network ? "Allow network access?" : "Give the agent extra permissions?",
                        detail: [call.title, String(call.arguments.prefix(600))].filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
        return .ask(title: isDestructive(text) ? "Run a destructive command?" : "Run this command?", detail: command)
    }

    /// The shell command of an execute call, or of a call of another kind that carries one. Nil for other tools.
    static func runCommand(_ call: ACPToolCall) -> String? {
        if call.kind == "execute" { return call.command }
        if let text = call.input["command"] as? String ?? call.input["cmd"] as? String { return text }
        if let parts = call.input["command"] as? [String] ?? call.input["cmd"] as? [String] { return parts.joined(separator: " ") }
        if let text = call.rawInput as? String { return text }
        return nil
    }
}
