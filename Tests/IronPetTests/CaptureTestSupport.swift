import Foundation
@testable import IronPet

extension CaptureStore {
    /// A private in-memory store.
    static func inMemory() -> CaptureStore {
        CaptureStore(database: Database.open(path: nil, migrations: migrations).database)
    }
}

/// A task list in memory, standing in for the app's `TaskStore`.
final class MemoryTaskList: CaptureTaskList {
    private let lock = NSLock()
    private var items: [CaptureTask]
    private var closed: Set<String> = []
    private var counter = 0

    init(_ titles: [String] = []) {
        items = titles.enumerated().map { CaptureTask(id: "t\($0.offset + 1)", title: $0.element, notes: "", due: nil) }
        counter = titles.count
    }

    var all: [CaptureTask] { lock.withLock { items } }
    var isClosed: (String) -> Bool { { id in self.lock.withLock { self.closed.contains(id) } } }

    func open() async -> [CaptureTask] { lock.withLock { items.filter { !closed.contains($0.id) } } }

    func all() async -> [CaptureTask] {
        lock.withLock { items.map { var task = $0; task.isDone = closed.contains($0.id); return task } }
    }

    func create(title: String, notes: String, due: String?) async -> CaptureTask? {
        lock.withLock {
            counter += 1
            let task = CaptureTask(id: "t\(counter)", title: title, notes: notes, due: due)
            items.append(task)
            return task
        }
    }

    func update(id: String, title: String?, notes: String?, due: String?, done: Bool, note: String?) async -> CaptureTask? {
        lock.withLock {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
            if let title { items[index].title = title }
            if let notes { items[index].notes = notes }
            if let due { items[index].due = due }
            if done { closed.insert(id) }
            return items[index]
        }
    }
}
