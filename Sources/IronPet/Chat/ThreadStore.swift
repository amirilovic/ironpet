import Foundation

/// A saved quick-chat thread. `id` is the agent's ACP session id and `workspace` its cwd, so a thread reopens with
/// `session/load`. Threads saved before ACP have no `agent` and are skipped.
struct ChatThread: Codable, Identifiable {
    let id: String
    var title: String
    var workspace: String
    var updatedAt: Date
    var items: [ChatSession.Item]
    /// The catalog id of the agent that owns the session.
    var agent: String
}

extension ChatThread {
    /// A thread reopened after the app quit: steps that were still running when it quit can't finish
    /// any more, so they show as failed instead of spinning forever.
    func restoredAfterQuit() -> ChatThread {
        var thread = self
        thread.items = items.map { item in
            guard case .tool(let summary, ok: nil) = item.kind else { return item }
            var item = item
            item.kind = .tool(summary, ok: false)
            return item
        }
        return thread
    }
}

/// Persists threads as JSON files in `~/.ironpet/threads/`.
enum ThreadStore {
    static let directory = Paths.root.appendingPathComponent("threads")

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func save(_ thread: ChatThread) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(thread).write(to: file(thread.id), options: .atomic)
        } catch {
            NSLog("ironpet: could not save thread \(thread.id): \(error)")
        }
    }

    static func load(_ id: String) -> ChatThread? {
        (try? Data(contentsOf: file(id))).flatMap { try? decoder.decode(ChatThread.self, from: $0) }
    }

    /// Most recent first.
    static func recent(limit: Int = 15) -> [ChatThread] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(ChatThread.self, from: $0) } }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { $0 }
    }

    private static func file(_ id: String) -> URL {
        directory.appendingPathComponent("\(id.replacingOccurrences(of: "/", with: "_")).json")
    }
}
