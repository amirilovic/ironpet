import Foundation

/// An open task as screen capture sees it: enough to show the models, to match a suggestion against, and to update.
struct CaptureTask: Equatable {
    var id: String
    var title: String
    var notes: String
    /// A date or date and time as the task has it, such as `2026-11-20`.
    var due: String?
    /// A finished task. The analysis agent can find these, so it does not suggest finished work again.
    var isDone = false
}

/// The user's task list. ironpet has one, the Tasks section's `TaskStore`; screen capture reads its open tasks and, after a click on Add,
/// creates or updates tasks in it. Nothing here writes to an external task or calendar app.
protocol CaptureTaskList {
    /// Open tasks only. The local decision model gets these.
    func open() async -> [CaptureTask]
    /// Every task, done ones too. Suggestions from the agent are checked against these.
    func all() async -> [CaptureTask]
    func create(title: String, notes: String, due: String?) async -> CaptureTask?
    /// `note` goes to the task's history, so it says where the change came from.
    func update(id: String, title: String?, notes: String?, due: String?, done: Bool, note: String?) async -> CaptureTask?
}

/// The real list: the app's shared `TaskStore`, reached on the main actor.
struct SharedTaskList: CaptureTaskList {
    /// The agent that makes the change, as shown in the task's history.
    static let by = "capture"

    static func dueString(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private static func item(_ task: TaskItem) -> CaptureTask {
        CaptureTask(id: task.id, title: task.title, notes: task.notes, due: task.due.map(dueString),
                    isDone: task.status == .done)
    }

    func open() async -> [CaptureTask] {
        await MainActor.run { (TaskStore.shared?.ordered ?? []).filter { $0.status != .done }.map(Self.item) }
    }

    func all() async -> [CaptureTask] {
        await MainActor.run { (TaskStore.shared?.ordered ?? []).map(Self.item) }
    }

    func create(title: String, notes: String, due: String?) async -> CaptureTask? {
        await MainActor.run {
            guard let store = TaskStore.shared else { return nil }
            var notes = notes
            var date: Date?
            if let due, !due.isEmpty {
                // A date the task store cannot read stays visible in the notes instead of being lost.
                if let parsed = try? TaskValidator.due(due) { date = parsed } else { notes += (notes.isEmpty ? "" : "\n") + "Due: \(due)" }
            }
            return (try? store.create(title: title, notes: notes, source: .capture, due: date, by: Self.by)).map(Self.item)
        }
    }

    func update(id: String, title: String?, notes: String?, due: String?, done: Bool, note: String?) async -> CaptureTask? {
        await MainActor.run {
            guard let store = TaskStore.shared else { return nil }
            var date: Date??
            var extra = ""
            if let due, !due.isEmpty {
                if let parsed = try? TaskValidator.due(due) { date = .some(parsed) } else { extra = "Due: \(due)" }
            }
            let notes = notes.map { $0 + (extra.isEmpty ? "" : ($0.isEmpty ? "" : "\n") + extra) }
            return (try? store.update(id, title: title, notes: notes, status: done ? .done : nil, due: date, note: note, by: Self.by)).map(Self.item)
        }
    }
}
