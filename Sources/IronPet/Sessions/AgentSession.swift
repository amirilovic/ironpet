import Foundation

enum AgentSource: String, Codable {
    case cursor, claude, codex, gemini, copilot, pi
    /// A background job ironpet runs itself (`JobService`), not a session a hook reported.
    case job

    var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .copilot: return "GitHub Copilot"
        case .pi: return "Pi"
        case .job: return "Background job"
        }
    }
}

/// Ordered by how urgently the pet should surface it.
enum AgentStatus: Int, Comparable, Codable {
    case idle, running, done, failed, needsInput

    static func < (a: AgentStatus, b: AgentStatus) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .done: return "Done"
        case .failed: return "Failed"
        case .needsInput: return "Needs input"
        }
    }

    var mood: PetMood {
        switch self {
        case .idle: return .idle
        case .running: return .working
        case .done: return .done
        case .failed: return .failed
        case .needsInput: return .needsInput
        }
    }
}

/// Where the hook ran, used to jump back to the session.
struct SessionOrigin: Codable {
    var workspace: String?
    var termProgram: String?
    var itermSessionID: String?
    /// The agent's process id as the hook saw it.
    var pid: Int32?
    /// Bundle id of the app that started the agent, resolved from `pid` when the first event arrived.
    var ownerBundleID: String?
    /// Ids the hosting app put in the agent's environment, used to open the exact tab or thread. Only these
    /// variables are kept; see `AppIDs`.
    var cmuxWorkspaceID: String?
    var cmuxSurfaceID: String?
    var t3ThreadID: String?
    var herdrTerminalID: String?
}

/// The only environment variables the hook forwards besides the terminal ones. Everything else stays out.
enum AppIDs {
    /// Environment variable and the header the hook script sends it in.
    static let headers: [(env: String, header: String)] = [
        ("CMUX_WORKSPACE_ID", "x-ironpet-cmux-workspace"),
        ("CMUX_SURFACE_ID", "x-ironpet-cmux-surface"),
        ("T3CODE_THREAD_ID", "x-ironpet-t3-thread"),
        ("HC_TERMINAL_ID", "x-ironpet-herdr-terminal"),
    ]

    /// An id is kept when it is non-empty, short and has no control characters. Other characters are fine: the
    /// openers percent-encode ids in URLs and pass them as one argument to commands.
    static func clean(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 200,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return raw
    }

    /// Reads the four ids from an environment, ignoring every other variable.
    static func capture(env: [String: String]) -> SessionOrigin {
        var origin = SessionOrigin()
        origin.cmuxWorkspaceID = clean(env["CMUX_WORKSPACE_ID"])
        origin.cmuxSurfaceID = clean(env["CMUX_SURFACE_ID"])
        origin.t3ThreadID = clean(env["T3CODE_THREAD_ID"])
        origin.herdrTerminalID = clean(env["HC_TERMINAL_ID"])
        return origin
    }
}

struct AgentSession: Identifiable, Codable {
    let id: String
    let source: AgentSource
    var status: AgentStatus = .idle
    var prompt: String?
    var detail: String?
    var origin = SessionOrigin()
    var ended = false
    var updatedAt = Date()
    var turnStartedAt = Date()
    /// Files edited during the current turn, in order.
    var editedFiles: [String] = []
    /// The agent's last reply in the current turn.
    var lastResponse: String?

    var workspaceName: String {
        guard let path = origin.workspace, !path.isEmpty else { return "Unknown workspace" }
        if path == "/" { return "No project" }
        if path == NSHomeDirectory() { return "Home" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// One line about what the turn did, e.g. "Edited 3 files · Fixed the flaky login test."
    var summary: String? {
        var parts: [String] = []
        if let only = editedFiles.first, editedFiles.count == 1 {
            parts.append("Edited \(URL(fileURLWithPath: only).lastPathComponent)")
        } else if !editedFiles.isEmpty {
            parts.append("Edited \(editedFiles.count) files")
        }
        if let sentence = lastResponse.flatMap(Self.firstSentence) { parts.append(sentence) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    mutating func startTurn() {
        turnStartedAt = Date()
        editedFiles = []
        lastResponse = nil
    }

    mutating func noteEdit(_ path: String?) {
        guard let path, !path.isEmpty, !editedFiles.contains(path) else { return }
        editedFiles.append(path)
    }

    static func firstSentence(_ text: String) -> String? {
        let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        guard let line = plain.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "#-* ").union(.whitespaces)) })
            .first(where: { !$0.isEmpty }) else { return nil }
        var sentence = line
        if let end = line.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            sentence = String(line[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        return sentence.count > 140 ? String(sentence.prefix(137)) + "…" : sentence
    }

    /// The agent's own session id, without the `<source>:` prefix of the store key.
    var agentSessionID: String? {
        let prefix = source.rawValue + ":"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        return rest.isEmpty ? nil : rest
    }

    var isInIterm: Bool { origin.itermSessionID?.isEmpty == false }
}
