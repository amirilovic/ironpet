import Foundation

enum AgentSource: String {
    case cursor, claude

    var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .claude: return "Claude Code"
        }
    }
}

/// Ordered by how urgently the pet should surface it.
enum AgentStatus: Int, Comparable {
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
struct SessionOrigin {
    var workspace: String?
    var termProgram: String?
    var itermSessionID: String?
    /// The agent's process id as the hook saw it.
    var pid: Int32?
    /// Bundle id of the app that started the agent, resolved from `pid` when the first event arrived.
    var ownerBundleID: String?
}

struct AgentSession: Identifiable {
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

    var isInIterm: Bool { origin.itermSessionID?.isEmpty == false }
}
