import Foundation

enum JobState: String, CaseIterable {
    /// Waiting for a free slot (`jobs.maxRunning`).
    case queued
    case running
    /// A command or tool call waits for Allow or Deny.
    case needsApproval = "needs_approval"
    case done
    case failed
    /// The user stopped it.
    case stopped
    /// ironpet quit while it was queued or running.
    case interrupted

    /// Queued or running: it holds, or waits for, an agent process.
    var isActive: Bool { self == .queued || self == .running || self == .needsApproval }
}

/// Work an agent handed off to its own agent session (`jobs_start`). It runs in the background in one folder, with the
/// chat's agent and model, and is tracked by a task. Its transcript is saved as a thread, so the user can read it or
/// carry on in the chat.
struct Job: Identifiable, Equatable {
    let id: String
    var title: String
    var prompt: String
    var folder: String
    /// Catalog id of the agent that runs it.
    var agent: String
    var model: String?
    /// The agent's session id, which is also the saved thread's id. Nil until the session starts.
    var thread: String?
    /// The task that tracks it in the Tasks section.
    var task: String?
    var state: JobState = .queued
    /// What the agent did last, such as "Run swift test".
    var lastStep: String?
    /// The first sentence of the final reply.
    var summary: String?
    var error: String?
    /// The approval it waits for, while `needsApproval`.
    var waitingFor: String?
    var created: Date
    var started: Date?
    var ended: Date?

    static let titleLimit = 120
    static let promptLimit = 20_000

    static func makeID() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return "job-" + String((0..<6).map { _ in alphabet.randomElement()! })
    }

    /// The row in the Agents section and the attention bubbles. Stopped and interrupted jobs are not listed.
    var agentSession: AgentSession? {
        let status: AgentStatus
        switch state {
        case .queued, .running: status = .running
        case .needsApproval: status = .needsInput
        case .done: status = .done
        case .failed: status = .failed
        case .stopped, .interrupted: return nil
        }
        var session = AgentSession(id: Self.sessionKey(id), source: .job, status: status, prompt: title)
        session.origin.workspace = folder
        session.detail = waitingFor.map { "Wants to: \($0)" } ?? (state == .queued ? "Waiting to start" : error ?? lastStep)
        session.lastResponse = summary
        session.updatedAt = ended ?? started ?? created
        session.turnStartedAt = started ?? created
        return session
    }

    /// `job:<id>`, the key of the job's row in `SessionStore`.
    static func sessionKey(_ id: String) -> String { "\(AgentSource.job.rawValue):\(id)" }

    /// The job id in a `SessionStore` key, or nil for a session that is not a job.
    static func id(fromSessionKey key: String) -> String? {
        let prefix = AgentSource.job.rawValue + ":"
        return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
    }

    var json: [String: Any] {
        let iso = ISO8601DateFormatter()
        var object: [String: Any] = ["id": id, "title": title, "state": state.rawValue, "folder": folder, "agent": agent,
                                     "created": iso.string(from: created)]
        object["model"] = model
        object["thread"] = thread
        object["task"] = task
        object["last_step"] = lastStep
        object["summary"] = summary
        object["error"] = error
        object["waiting_for"] = waitingFor
        object["started"] = started.map(iso.string(from:))
        object["ended"] = ended.map(iso.string(from:))
        return object
    }
}
