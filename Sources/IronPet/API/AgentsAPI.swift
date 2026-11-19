import Combine
import Foundation

/// The agent sessions Ghost watches (Cursor, Claude Code, Codex and others), folded from their hook events.
@MainActor
final class AgentsAPI: ObservableObject {
    private let store: SessionStore
    private var forwarding: AnyCancellable?

    /// Brings the session's terminal or editor to the front. Only the Mac can do this, so the app owner sets it.
    var focusHandler: ((AgentSession) -> Void)?
    /// Starts a conversation about a session: shows the chat with a prompt about it in the input. The app owner sets it.
    var askHandler: ((String) -> Void)?

    init(store: SessionStore) {
        self.store = store
        forwarding = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Sessions that are not idle, most urgent first.
    var sessions: [AgentSession] { store.ordered }
    /// The most urgent status and how many sessions share it.
    var summary: (status: AgentStatus, count: Int) { store.summary }

    func list() -> [AgentSession] { store.ordered }

    func get(_ id: String) throws -> AgentSession {
        guard let session = store.sessions[id] else { throw APIError.notFound("no session with id \"\(id)\"") }
        return session
    }

    /// Marks a finished or failed session as seen.
    func acknowledge(_ id: String) throws {
        _ = try get(id)
        store.acknowledge(id)
    }

    func acknowledgeAll() { store.acknowledgeAll() }

    /// Jumps to the session's terminal or editor, and marks it seen.
    func focus(_ id: String) throws {
        let session = try get(id)
        guard let focusHandler else { throw APIError.unavailable("this device cannot open the session's window") }
        focusHandler(session)
    }

    /// Asks Ghost about a session: what it did, or why it needs input.
    func ask(_ id: String) throws {
        let session = try get(id)
        guard let askHandler else { throw APIError.unavailable("the chat is not available") }
        askHandler(Self.prompt(for: session))
    }

    static func prompt(for session: AgentSession) -> String {
        "What is going on with the \(session.source.displayName) session in \(session.workspaceName)? It is \(session.status.label.lowercased())."
    }
}
