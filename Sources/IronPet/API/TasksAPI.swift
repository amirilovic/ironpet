import Combine
import Foundation

struct TaskListRequest: Codable, Equatable {
    /// Only tasks in these statuses. Nil lists every open task.
    var statuses: [TaskStatus]?
    /// Adds done tasks when `statuses` is nil.
    var includeDone = false
}

struct TaskWithHistory: Codable, Equatable {
    var task: TaskItem
    var history: [TaskEvent]
}

struct CreateTaskRequest: Codable, Equatable {
    var title: String
    var notes = ""
    var status: TaskStatus = .backlog
    var source: TaskSource
    var due: Date?
    var links: [TaskLink] = []
    var waitingOn: String?
    var sourceRef: String?
    /// Who is asking: `user`, `agent:mcp`, `agent:cli`. It goes to the task's history.
    var by = "user"
}

/// A nil field keeps the task's value.
struct UpdateTaskRequest: Codable, Equatable {
    var id: String
    var title: String?
    var notes: String?
    var status: TaskStatus?
    var due: Date?
    /// Removes the due date. `due` is ignored when this is set.
    var clearDue = false
    var links: [TaskLink]?
    /// A blank name clears who the task waits on.
    var waitingOn: String?
    /// Goes to the history only, to say why something changed.
    var note: String?
    var by = "user"
}

struct CloseTaskRequest: Codable, Equatable {
    var id: String
    var note: String?
    var by = "user"
}

struct DeleteTaskRequest: Codable, Equatable {
    var id: String
    var by = "user"
}

/// A task an agent proposes. It waits as a suggestion for the user to add or skip.
struct SuggestTaskRequest: Codable, Equatable {
    var draft: TaskSuggestion.Draft
    var kind: TaskSource
    var sourceRef: String
}

struct AcceptSuggestionRequest: Codable, Equatable {
    var id: String
    var title: String?
    var due: Date?
    var notes: String?
    var status: TaskStatus?
    var note: String?
    var by = "user"
}

struct RejectSuggestionRequest: Codable, Equatable {
    var id: String
    var note: String?
    var by = "user"
}

/// Tasks and the suggestions waiting for review. The one way a client reads or changes them.
///
/// This is an `ObservableObject` so a SwiftUI view can redraw when the list changes. The list itself is read through the
/// properties and calls below, never from the store.
@MainActor
final class TasksAPI: ObservableObject {
    private let store: TaskStore
    private var forwarding: AnyCancellable?

    init(store: TaskStore) {
        self.store = store
        forwarding = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: Reading

    /// Every task in the store's order: open ones first (needs you, in progress, backlog), then done.
    var all: [TaskItem] { store.ordered }
    /// Every task in storage order, for readers that sort for themselves.
    var items: [TaskItem] { store.tasks }
    var suggestions: [TaskSuggestion] { store.suggestions }
    /// What the Tasks section counts: tasks that need the user or are moving, not ones waiting on someone else.
    var activeCount: Int { store.activeCount }
    /// Why tasks are only in memory, when the database could not be opened.
    var unavailable: String? { store.unavailable }

    func task(_ id: String) -> TaskItem? { store.task(id) }
    func history(_ id: String) -> [TaskEvent] { store.history(id) }

    func list(_ request: TaskListRequest = TaskListRequest()) -> [TaskItem] {
        if let statuses = request.statuses { return store.ordered.filter { statuses.contains($0.status) } }
        return request.includeDone ? store.ordered : store.ordered.filter { $0.status != .done }
    }

    func get(_ id: String) throws -> TaskWithHistory {
        guard let task = store.task(id) else { throw APIError.notFound("no task with id \"\(id)\"") }
        return TaskWithHistory(task: task, history: store.history(id))
    }

    // MARK: Changing

    @discardableResult
    func create(_ request: CreateTaskRequest) throws -> TaskItem {
        try run {
            try store.create(title: request.title, notes: request.notes, status: request.status, source: request.source, due: request.due,
                             links: request.links, waitingOn: request.waitingOn, sourceRef: request.sourceRef, by: request.by)
        }
    }

    @discardableResult
    func update(_ request: UpdateTaskRequest) throws -> TaskItem {
        try run {
            try store.update(request.id, title: request.title, notes: request.notes, status: request.status,
                             due: request.clearDue ? .some(nil) : request.due.map { .some($0) },
                             links: request.links, waitingOn: request.waitingOn.map { .some($0) }, note: request.note, by: request.by)
        }
    }

    @discardableResult
    func close(_ request: CloseTaskRequest) throws -> TaskItem {
        try run { try store.close(request.id, note: request.note, by: request.by) }
    }

    func delete(_ request: DeleteTaskRequest) throws {
        try run { try store.delete(request.id, by: request.by) }
    }

    // MARK: Suggestions

    /// The suggestion that was added, or none when it was a repeat or the title is already a task or a suggestion.
    @discardableResult
    func suggest(_ request: SuggestTaskRequest) -> [TaskSuggestion] {
        store.suggest(request.draft, agent: request.kind, sourceRef: request.sourceRef)
    }

    @discardableResult
    func accept(_ request: AcceptSuggestionRequest) throws -> TaskItem {
        try run {
            var overrides = TaskStore.Overrides(title: request.title, due: nil, notes: request.notes, status: request.status?.rawValue)
            overrides.due = request.due.map { ISO8601DateFormatter().string(from: $0) }
            return try store.accept(request.id, overrides: overrides, note: request.note, by: request.by)
        }
    }

    /// Adds every suggestion as a task.
    func acceptAll() { store.acceptAll() }

    func reject(_ request: RejectSuggestionRequest) throws {
        try run { try store.reject(request.id, note: request.note, by: request.by) }
    }

    /// Drops a suggestion without a reason, as the Skip button does.
    func skip(_ id: String) { store.skip(id) }

    // MARK: Errors

    private func run<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as TaskError {
            let missing = error.message.hasPrefix("no task") || error.message.hasPrefix("no suggestion")
            throw missing ? APIError.notFound(error.message) : APIError.invalid(error.message)
        } catch {
            throw APIError.wrap(error)
        }
    }
}
