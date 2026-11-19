import Foundation

/// Turns a background run's agent events into the items of a saved thread: reply text joined into one item, one row per
/// tool call that is updated in place. Automation sessions and background jobs both record their runs with it, so their
/// threads read like a chat the user had.
struct TranscriptRecorder {
    private(set) var items: [ChatSession.Item]
    /// The reply text of the current turn.
    private(set) var answer = ""
    /// The summary of the newest tool call, such as "Run swift test".
    private(set) var lastStep: String?
    private var toolRows: [String: Int] = [:]

    init(items: [ChatSession.Item] = []) {
        self.items = items
    }

    mutating func append(_ item: ChatSession.Item) {
        items.append(item)
    }

    /// A new prompt: its reply starts a new item.
    mutating func beginTurn(_ prompt: ChatSession.Item) {
        items.append(prompt)
        answer = ""
    }

    /// Records a transcript event. Other events (session, models, finished) are left to the caller.
    mutating func record(_ event: AgentEvent) {
        switch event {
        case .assistant(let chunk):
            answer += chunk
            if let last = items.last, case .assistant(let text) = last.kind { items[items.count - 1].kind = .assistant(text + chunk) }
            else { items.append(.init(kind: .assistant(chunk))) }
        case .toolStarted(let id, let summary):
            toolRows[id] = items.count
            items.append(.init(kind: .tool(summary, ok: nil)))
            lastStep = summary
        case .toolUpdated(let id, let summary):
            if let row = toolRows[id], case .tool(_, let ok) = items[row].kind { items[row].kind = .tool(summary, ok: ok) }
            lastStep = summary
        case .toolFinished(let id, let ok):
            if let row = toolRows[id], case .tool(let summary, _) = items[row].kind { items[row].kind = .tool(summary, ok: ok) }
        default:
            break
        }
    }
}
