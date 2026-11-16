import Foundation

/// Tells the user when open tasks are due, once per task and due date, in one bubble that lists all of them. Runs on the
/// app's minute timer and after task changes; what was announced or snoozed is in `task_due_marks`.
@MainActor
final class TaskDueReminders {
    struct Settings: Equatable {
        var enabled: Bool
        var paused: Bool
    }

    /// Shows the bubble for these tasks. `isNew` is false when it only drops tasks that were closed or moved.
    var show: (_ tasks: [TaskItem], _ isNew: Bool) -> Void = { _, _ in }
    var hide: () -> Void = {}
    /// Whether the bubble is still up; once the user closes it, the next due task gets a fresh one.
    var isShowing: () -> Bool = { false }

    /// The tasks in the bubble now, in order.
    private(set) var listed: [String] = []

    private let store: TaskStore
    private let now: () -> Date
    private let calendar: Calendar
    private let settings: @MainActor () -> Settings

    init(store: TaskStore, now: @escaping () -> Date = Date.init, calendar: Calendar = .current,
         settings: @escaping @MainActor () -> Settings = {
             let config = ConfigStore.shared.config
             return Settings(enabled: config.tasks.dueReminders, paused: config.reminders.paused)
         }) {
        self.store = store
        self.now = now
        self.calendar = calendar
        self.settings = settings
    }

    func check() {
        let settings = settings()
        guard settings.enabled else {
            if !listed.isEmpty { hide() }
            listed = []
            return
        }
        guard !settings.paused else { return }
        if !listed.isEmpty, !isShowing() { listed = [] }
        let time = now()
        let marks = store.dueMarks()
        let pending = TaskDue.pending(store.tasks, marks: marks, now: time)
        let kept = listed.compactMap(store.task).filter { task in
            task.status != .done && task.due != nil && marks[task.id]?.due == task.due && !pending.contains { $0.id == task.id }
        }
        let tasks = kept + pending
        store.markDue(pending, snoozedUntil: nil)
        let ids = tasks.map(\.id)
        guard ids != listed else { return }
        listed = ids
        if tasks.isEmpty { hide() } else { show(tasks, !pending.isEmpty) }
    }

    /// Done in the bubble: closes every task it listed.
    func done(_ ids: [String]) {
        for id in ids { _ = try? store.close(id, by: "user") }
        listed.removeAll { ids.contains($0) }
    }

    func snooze(_ ids: [String]) {
        let tasks = ids.compactMap(store.task)
        store.markDue(tasks, snoozedUntil: TaskDue.snoozeEnd(for: tasks, now: now(), calendar: calendar))
        listed.removeAll { ids.contains($0) }
    }
}
