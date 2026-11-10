import Foundation

enum BackendKind: String, CaseIterable, Codable {
    case cursor, claude

    var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .claude: return "Claude Code"
        }
    }

    @MainActor
    func make() -> CLIBackend {
        switch self {
        case .cursor: return CursorAgentBackend()
        case .claude: return ClaudeCodeBackend()
        }
    }
}

enum AgentEvent {
    case session(String)
    case assistant(String)
    case toolStarted(id: String, summary: String)
    case toolFinished(id: String, ok: Bool)
    case finished(error: String?)
}

struct RunRequest {
    let prompt: String
    let workspace: URL
    let resume: String?
    let auto: Bool
    let model: String?
}

/// Runs one turn of a headless coding-agent CLI and turns its stream-json output into `AgentEvent`s.
/// Subclasses supply the executable, arguments and line parser.
@MainActor
class CLIBackend {
    let runID = UUID().uuidString
    private var process: Process?
    private var buffer = Data()
    private var stderr = Data()
    private var finished = false
    private var onEvent: ((AgentEvent) -> Void)?

    nonisolated class var executableNames: [String] { [] }
    func arguments(for request: RunRequest) -> [String] { [] }
    /// Whether the prompt is written to stdin instead of passed as the last argument.
    var promptOnStdin: Bool { false }
    func handle(_ object: [String: Any]) {}

    nonisolated class func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local"]
        for name in executableNames {
            for dir in dirs where FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") {
                return URL(fileURLWithPath: "\(dir)/\(name)")
            }
        }
        return nil
    }

    func start(_ request: RunRequest, onEvent: @escaping (AgentEvent) -> Void) throws {
        guard let exe = Self.executable() else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "\(Self.executableNames.first ?? "agent") was not found"])
        }
        for dir in [Memory.directory, ScreenCapture.directory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.onEvent = onEvent
        let process = Process()
        process.executableURL = exe
        process.arguments = arguments(for: request) + (promptOnStdin ? [] : [request.prompt])
        process.currentDirectoryURL = request.workspace
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["IRONPET_RUN_ID"] = runID
        process.environment = env

        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = promptOnStdin ? input : FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consume(data) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.stderr.append(data) }
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                let message = String(data: self.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.finish(error: status == 0 ? nil : (message?.isEmpty == false ? message : "The agent exited with \(status)"))
            }
        }
        try process.run()
        if promptOnStdin {
            input.fileHandleForWriting.write(Data(request.prompt.utf8))
            try? input.fileHandleForWriting.close()
        }
        self.process = process
    }

    func stop() {
        process?.terminate()
    }

    func emit(_ event: AgentEvent) {
        onEvent?(event)
    }

    /// Reports the end of the turn once, whether from the stream's result line or process exit.
    func finish(error: String?) {
        guard !finished else { return }
        finished = true
        onEvent?(.finished(error: error))
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { handle(object) }
        }
    }

    static func shortPath(_ path: String?) -> String? {
        path.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}

/// Headless `cursor-agent -p --output-format stream-json`.
final class CursorAgentBackend: CLIBackend {
    nonisolated override class var executableNames: [String] { ["cursor-agent"] }

    override func start(_ request: RunRequest, onEvent: @escaping (AgentEvent) -> Void) throws {
        if Config.load().config.integrations.shareMCPSignIns { MCPAuthSharing.prepare(workspace: request.workspace) }
        try super.start(request, onEvent: onEvent)
    }

    override func arguments(for r: RunRequest) -> [String] {
        var args = ["-p", "--output-format", "stream-json", "--trust", "--workspace", r.workspace.path,
                    "--add-dir", Memory.directory.path, "--add-dir", ScreenCapture.directory.path]
        if r.auto { args.append("--force") }
        if let model = r.model { args += ["--model", model] }
        if let resume = r.resume { args += ["--resume", resume] }
        return args
    }

    override func handle(_ object: [String: Any]) {
        switch object["type"] as? String {
        case "system":
            if let id = object["session_id"] as? String { emit(.session(id)) }
        case "assistant":
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { emit(.assistant(text)) }
        case "tool_call":
            guard let id = object["call_id"] as? String,
                  let call = object["tool_call"] as? [String: Any],
                  let entry = call.first(where: { $0.key.hasSuffix("ToolCall") }) else { return }
            let body = entry.value as? [String: Any] ?? [:]
            if object["subtype"] as? String == "started" {
                emit(.toolStarted(id: id, summary: Self.summary(kind: entry.key, args: body["args"] as? [String: Any] ?? [:])))
            } else if object["subtype"] as? String == "completed" {
                emit(.toolFinished(id: id, ok: (body["result"] as? [String: Any])?["success"] != nil))
            }
        case "result":
            finish(error: (object["is_error"] as? Bool ?? false) ? (object["result"] as? String ?? "The agent reported an error") : nil)
        default:
            break
        }
    }

    private static func summary(kind: String, args: [String: Any]) -> String {
        let path = shortPath(args["path"] as? String)
        switch kind {
        case "shellToolCall": return "Ran `\(args["command"] as? String ?? "a command")`"
        case "editToolCall": return "Edited \(path ?? "a file")"
        case "readToolCall": return "Read \(path ?? "a file")"
        case "deleteToolCall": return "Deleted \(path ?? "a file")"
        case "grepToolCall", "globToolCall": return "Searched the codebase"
        default: return kind.replacingOccurrences(of: "ToolCall", with: "").capitalized
        }
    }
}

/// Headless `claude -p --output-format stream-json --verbose`. The prompt goes on stdin because
/// `--add-dir` takes a variable number of values and would swallow a trailing prompt argument.
final class ClaudeCodeBackend: CLIBackend {
    nonisolated override class var executableNames: [String] { ["claude"] }
    override var promptOnStdin: Bool { true }

    static let models = [ChatModel(id: "sonnet", name: "Sonnet (latest)"), ChatModel(id: "opus", name: "Opus (latest)"),
                         ChatModel(id: "haiku", name: "Haiku (latest)")]

    override func arguments(for r: RunRequest) -> [String] {
        var args = ["-p", "--output-format", "stream-json", "--verbose",
                    "--add-dir", Memory.directory.path, ScreenCapture.directory.path]
        if r.auto { args += ["--permission-mode", "bypassPermissions"] }
        if let model = r.model { args += ["--model", model] }
        if let resume = r.resume { args += ["--resume", resume] }
        return args
    }

    override func handle(_ object: [String: Any]) {
        switch object["type"] as? String {
        case "system":
            if object["subtype"] as? String == "init", let id = object["session_id"] as? String { emit(.session(id)) }
        case "assistant":
            for block in (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty { emit(.assistant(text)) }
                case "tool_use":
                    guard let id = block["id"] as? String else { continue }
                    emit(.toolStarted(id: id, summary: Self.summary(name: block["name"] as? String ?? "Tool",
                                                                    input: block["input"] as? [String: Any] ?? [:])))
                default:
                    break
                }
            }
        case "user":
            for block in (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                if let id = block["tool_use_id"] as? String { emit(.toolFinished(id: id, ok: !(block["is_error"] as? Bool ?? false))) }
            }
        case "result":
            finish(error: (object["is_error"] as? Bool ?? false) ? (object["result"] as? String ?? "Claude Code reported an error") : nil)
        default:
            break
        }
    }

    private static func summary(name: String, input: [String: Any]) -> String {
        let path = shortPath((input["file_path"] ?? input["path"] ?? input["notebook_path"]) as? String)
        switch name {
        case "Bash": return "Ran `\(input["command"] as? String ?? "a command")`"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Edited \(path ?? "a file")"
        case "Read": return "Read \(path ?? "a file")"
        case "Grep", "Glob", "LS": return "Searched the codebase"
        case "WebFetch", "WebSearch": return "Searched the web"
        default: return name
        }
    }
}
