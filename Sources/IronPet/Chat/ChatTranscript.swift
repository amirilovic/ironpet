import Foundation

/// Folds an agent's text and tool events into chat items. Shared by the chat and by task runs, so a run's thread
/// reads the same as a chat.
struct ChatTranscript {
    struct Outcome: Equatable {
        /// The new status line, or nil to leave it.
        var activity: String?
        /// True when an update outside a turn changed a saved item.
        var save = false
        /// False when the event changed no item, e.g. an update for a tool row that is not in the transcript.
        var changed = false
    }

    private var toolItems: [String: UUID] = [:]
    /// A tool row's own summary, before the count of its subagent's tool calls is added.
    private var toolBase: [String: String] = [:]
    /// The tool calls each subagent has made, by the subagent's tool-use id, in the order they started.
    private var subagentCalls: [String: [(id: String, ok: Bool?)]] = [:]
    /// The reply item that late updates extend, so a later result starts its own item.
    private var backgroundReply: UUID?

    /// Text and tool items. Outside a running turn, text opens a new item instead of extending the last reply.
    mutating func apply(_ event: AgentEvent, to items: inout [ChatSession.Item], running: Bool) -> Outcome {
        var outcome = Outcome()
        switch event {
        case .assistant(let text):
            if running { outcome.activity = "Writing" }
            outcome.changed = true
            if case .assistant(let previous) = items.last?.kind, running || items.last?.id == backgroundReply {
                items[items.count - 1].kind = .assistant(previous + text)
            } else {
                let item = ChatSession.Item(kind: .assistant(text))
                backgroundReply = running ? nil : item.id
                items.append(item)
            }
        case .toolStarted(let id, let summary):
            if running { outcome.activity = Self.presentTense(summary) }
            let item = ChatSession.Item(kind: .tool(summary, ok: nil))
            toolBase[id] = summary
            toolItems[id] = item.id
            items.append(item)
            outcome.changed = true
        case .toolUpdated(let id, let summary):
            if let itemID = toolItems[id], let index = items.firstIndex(where: { $0.id == itemID }),
               case .tool(_, let ok) = items[index].kind {
                toolBase[id] = summary
                items[index].kind = .tool(composedSummary(id), ok: ok)
                outcome.changed = true
            }
        case .subagentTool(let parent, let id, let summary, let ok):
            // A subagent's calls count on its own row. They never open an item, so the reply's text keeps one message.
            if running, ok == nil { outcome.activity = Self.presentTense(summary) }
            var calls = subagentCalls[parent] ?? []
            if let index = calls.firstIndex(where: { $0.id == id }) { calls[index].ok = ok } else { calls.append((id, ok)) }
            subagentCalls[parent] = calls
            if let itemID = toolItems[parent], let index = items.firstIndex(where: { $0.id == itemID }),
               case .tool(_, let parentOK) = items[index].kind {
                items[index].kind = .tool(composedSummary(parent), ok: parentOK)
                outcome.changed = true
            }
            outcome.save = !running
        case .toolFinished(let id, let ok):
            if running { outcome.activity = "Thinking" }
            if let itemID = toolItems[id], let index = items.firstIndex(where: { $0.id == itemID }),
               case .tool(let summary, _) = items[index].kind {
                items[index].kind = .tool(summary, ok: ok)
                outcome.changed = true
            }
            outcome.save = !running
        default:
            break
        }
        return outcome
    }

    static func presentTense(_ summary: String) -> String {
        for (past, present) in [("Ran ", "Running "), ("Edited ", "Editing "), ("Read ", "Reading "),
                                ("Deleted ", "Deleting "), ("Searched ", "Searching ")] where summary.hasPrefix(past) {
            return present + summary.dropFirst(past.count)
        }
        return summary
    }

    /// A tool row's summary with its subagent's tool-call count, e.g. "Run research · 3 tool calls".
    private func composedSummary(_ id: String) -> String {
        let base = toolBase[id] ?? ""
        let count = subagentCalls[id]?.count ?? 0
        guard count > 0 else { return base }
        return "\(base) · \(count) tool call\(count == 1 ? "" : "s")"
    }
}
