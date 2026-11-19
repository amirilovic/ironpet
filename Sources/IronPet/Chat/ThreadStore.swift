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
    /// The id of the automation whose run this thread holds. Nil for a thread the user started.
    var automation: String? = nil
    /// The automation's name when the run was recorded, shown in the thread list.
    var automationName: String? = nil
    /// How many automation runs this thread holds. An `own` session starts a fresh thread after a limit.
    var runs: Int? = nil
    /// The id of the background job whose transcript this thread holds (`JobService`).
    var job: String? = nil
    /// True for a voice-mode conversation (`FrontDesk`).
    var voice: Bool? = nil

    var isAutomationRun: Bool { automation != nil }
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
    /// A variable so tests can point it at a temp folder.
    nonisolated(unsafe) static var directory = Paths.root.appendingPathComponent("threads")
    /// Called after each save, for the memory index. Set once at launch on the main thread, before any thread is saved.
    nonisolated(unsafe) static var didSave: ((ChatThread) -> Void)?

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
            didSave?(thread)
        } catch {
            NSLog("ironpet: could not save thread \(thread.id): \(error)")
        }
    }

    static func load(_ id: String) -> ChatThread? {
        (try? Data(contentsOf: file(id))).flatMap { try? decoder.decode(ChatThread.self, from: $0) }
    }

    /// Most recent first. Automation runs are capped at `automationLimit`, so an hourly job does not push the user's own
    /// threads out of the list.
    static func recent(limit: Int = 15, automationLimit: Int = 5) -> [ChatThread] {
        var automations = 0
        return all()
            .filter { thread in
                guard thread.isAutomationRun else { return true }
                automations += 1
                return automations <= automationLimit
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Voice-mode conversations, most recent first.
    static func voice(limit: Int = 20) -> [ChatThread] {
        Array(all().filter { $0.voice == true }.prefix(limit))
    }

    private static func all() -> [ChatThread] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(ChatThread.self, from: $0) } }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Deletes this automation's oldest threads beyond the newest `keep`.
    static func prune(automation id: String, keep: Int) {
        for thread in all().filter({ $0.automation == id }).dropFirst(keep) {
            try? FileManager.default.removeItem(at: file(thread.id))
        }
    }

    /// The newest thread that holds runs of this automation.
    static func latest(automation id: String) -> ChatThread? {
        all().first { $0.automation == id }
    }

    private static func file(_ id: String) -> URL {
        directory.appendingPathComponent("\(id.replacingOccurrences(of: "/", with: "_")).json")
    }
}
