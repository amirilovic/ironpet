import Foundation

struct HookEvent {
    let source: AgentSource
    let name: String
    let payload: [String: Any]
    let origin: SessionOrigin
    let runID: String?
}

/// Folds hook events into per-session status and a single pet-level summary.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [String: AgentSession] = [:]

    /// Called when a session enters a status worth announcing.
    var onAttention: ((AgentSession) -> Void)?

    var ordered: [AgentSession] {
        sessions.values
            .filter { $0.status != .idle }
            .sorted { ($0.status, $0.updatedAt) > ($1.status, $1.updatedAt) }
    }

    /// Most urgent status and how many sessions share it.
    var summary: (status: AgentStatus, count: Int) {
        let top = sessions.values.map(\.status).max() ?? .idle
        return (top, sessions.values.filter { $0.status == top }.count)
    }

    func apply(_ event: HookEvent) {
        guard let sessionID = Self.sessionID(event) else { return }
        let key = "\(event.source.rawValue):\(sessionID)"
        var session = sessions[key] ?? AgentSession(id: key, source: event.source)
        let previous = session.status
        if session.origin.workspace == nil { session.origin.workspace = event.origin.workspace }
        if let term = event.origin.termProgram, !term.isEmpty { session.origin.termProgram = term }
        if let iterm = event.origin.itermSessionID, !iterm.isEmpty { session.origin.itermSessionID = iterm }
        session.updatedAt = Date()

        switch event.source {
        case .cursor: applyCursor(event, to: &session)
        case .claude: applyClaude(event, to: &session)
        }

        if session.ended, session.status == .idle {
            sessions[key] = nil
        } else {
            sessions[key] = session
        }
        if session.status != previous, [.needsInput, .failed, .done].contains(session.status) {
            onAttention?(session)
        }
    }

    /// Sample sessions for `--render-previews`.
    func loadPreview(_ preview: [AgentSession]) {
        sessions = Dictionary(uniqueKeysWithValues: preview.map { ($0.id, $0) })
    }

    func acknowledge(_ id: String) {
        guard var session = sessions[id] else { return }
        guard session.status == .done || session.status == .failed else { return }
        session.status = .idle
        sessions[id] = session.ended ? nil : session
    }

    func acknowledgeAll() {
        for id in sessions.keys { acknowledge(id) }
    }

    /// Drops sessions whose agent went quiet without a closing event.
    func sweep(now: Date = Date()) {
        for (id, session) in sessions {
            let age = now.timeIntervalSince(session.updatedAt)
            if (session.status == .running || session.status == .needsInput), age > 30 * 60 {
                sessions[id]?.status = .idle
            } else if session.status == .idle, age > 2 * 60 * 60 {
                sessions[id] = nil
            }
        }
    }

    private static func sessionID(_ event: HookEvent) -> String? {
        (event.payload["conversation_id"] as? String) ?? (event.payload["session_id"] as? String)
    }

    private func applyCursor(_ event: HookEvent, to session: inout AgentSession) {
        let p = event.payload
        if let root = (p["workspace_roots"] as? [String])?.first { session.origin.workspace = root }
        switch event.name {
        case "sessionStart":
            // Headless cursor-agent never fires beforeSubmitPrompt.
            if session.status == .idle { session.status = .running }
        case "beforeSubmitPrompt":
            session.status = .running
            session.prompt = (p["prompt"] as? String).map(Self.snippet) ?? session.prompt
            session.detail = nil
            session.startTurn()
        case "postToolUse":
            if session.status != .needsInput { session.status = .running }
            if let tool = p["tool_name"] as? String {
                session.detail = tool
                if Self.cursorEditTools.contains(tool) { session.noteEdit(Self.path(in: p["tool_input"])) }
            }
        case "afterAgentResponse":
            if session.status != .needsInput { session.status = .running }
            if let text = (p["text"] ?? p["response"]) as? String, !text.isEmpty { session.lastResponse = text }
        case "stop":
            switch p["status"] as? String {
            case "error": session.status = .failed
            case "aborted": session.status = .idle
            default: session.status = .done
            }
        case "sessionEnd":
            session.ended = true
            if session.status == .running {
                session.status = (p["reason"] as? String) == "error" ? .failed : .done
            }
        default:
            break
        }
    }

    private func applyClaude(_ event: HookEvent, to session: inout AgentSession) {
        let p = event.payload
        if let cwd = p["cwd"] as? String { session.origin.workspace = cwd }
        switch event.name {
        case "UserPromptSubmit":
            session.status = .running
            session.prompt = (p["prompt"] as? String).map(Self.snippet) ?? session.prompt
            session.detail = nil
            session.startTurn()
        case "PreToolUse", "PostToolUse":
            session.status = .running
            if let tool = p["tool_name"] as? String {
                session.detail = tool
                if event.name == "PostToolUse", Self.claudeEditTools.contains(tool) {
                    session.noteEdit(Self.path(in: p["tool_input"]))
                }
            }
        case "PermissionRequest":
            session.status = .needsInput
            if let tool = p["tool_name"] as? String { session.detail = "Wants to use \(tool)" }
        case "StopFailure":
            session.status = .failed
            session.detail = p["error"] as? String ?? session.detail
        case "Notification":
            let type = p["notification_type"] as? String
            let message = p["message"] as? String ?? ""
            let isIdleReminder = type == "idle_prompt" || message.localizedCaseInsensitiveContains("waiting for your input")
            if !isIdleReminder {
                session.status = .needsInput
                session.detail = message
            }
        case "Stop":
            session.status = .done
            session.lastResponse = (p["last_assistant_message"] as? String)
                ?? (p["transcript_path"] as? String).flatMap { Self.lastAssistantText(transcript: $0) }
                ?? session.lastResponse
        case "SessionEnd":
            session.ended = true
            if session.status == .running || session.status == .needsInput { session.status = .idle }
        default:
            break
        }
    }

    static let cursorEditTools: Set<String> = ["Write", "Edit", "StrReplace", "MultiEdit", "Delete", "EditNotebook"]
    static let claudeEditTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    private static func path(in input: Any?) -> String? {
        guard let input = input as? [String: Any] else { return nil }
        return (input["file_path"] ?? input["path"] ?? input["target_file"] ?? input["notebook_path"]) as? String
    }

    /// Last assistant text in a Claude Code transcript (JSONL). Reads only the tail of the file.
    static func lastAssistantText(transcript path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 256_000 ? size - 256_000 : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        for line in tail.split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            if !text.isEmpty { return text }
        }
        return nil
    }

    private static func snippet(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 80 ? String(line.prefix(77)) + "…" : line
    }
}
