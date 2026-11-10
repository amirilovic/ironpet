import Foundation

/// Thread-safe copy of the pet's state for the server's `GET /status` debug endpoint.
final class StatusSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Data("{}".utf8)

    var data: Data { lock.withLock { current } }

    @MainActor
    func update(store: SessionStore, mood: PetMood) {
        let sessions = store.sessions.values.map { s in
            ["id": s.id, "source": s.source.rawValue, "status": s.status.label, "workspace": s.workspaceName,
             "prompt": s.prompt ?? "", "detail": s.detail ?? "", "iterm": s.origin.itermSessionID ?? "",
             "summary": s.summary ?? ""]
        }
        let object: [String: Any] = ["mood": mood.rawValue, "sessions": sessions]
        let encoded = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        lock.withLock { current = encoded }
    }
}
