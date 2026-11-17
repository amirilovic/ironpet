import Foundation

/// What one send to the agent contained and what it produced, for the batch view in the Screen section.
struct ScreenBatch: Equatable {
    struct Item: Equatable, Identifiable {
        var id: Int64
        /// Nil when the item has been pruned since the send.
        var app: String?
        var title: String?
        var at: Date?
        var state: String?
        /// The stored text, which is the redacted text that was sent. Empty when the filter dropped it.
        var body: String
        var redactions: CaptureRedactor.Report
    }

    struct Suggestion: Equatable, Identifiable {
        enum Outcome: Equatable {
            case pending(id: String)
            case accepted(task: String?, title: String?)
            case rejected(note: String?)
        }

        var id: String
        var kind: String
        var title: String
        var quote: String
        var outcome: Outcome
    }

    var record: CaptureSendRecord
    var items: [Item]
    var suggestions: [Suggestion]
    var redactions: CaptureRedactor.Report
}

@MainActor
enum ScreenBatchLoader {
    /// The kind as the batch view names it.
    static func label(_ kind: String) -> String {
        ["new_task": "New task", "follow_up": "New task", "calendar": "Calendar", "update": "Update or close"][kind] ?? kind
    }

    /// Every suggestion a send produced: those still waiting, those resolved after this build recorded their outcome, and tasks
    /// accepted before that which still name the send in their source reference.
    static func suggestions(of log: Int64, tasks: TaskStore) -> [ScreenBatch.Suggestion] {
        var result: [ScreenBatch.Suggestion] = []
        var knownTasks = Set<String>()
        for row in tasks.captureOutcomes(sendLog: log) {
            guard let id = row[0] as? String, let kind = row[1] as? String, let title = row[2] as? String, let quote = row[3] as? String,
                  let outcome = row[4] as? String else { continue }
            let task = row[5] as? String
            if let task { knownTasks.insert(task) }
            result.append(.init(id: id, kind: kind, title: title, quote: quote,
                                outcome: outcome == "accepted" ? .accepted(task: task, title: task.flatMap { tasks.task($0)?.title })
                                                               : .rejected(note: row[6] as? String)))
        }
        for item in tasks.ordered where item.source == .capture && TaskStore.sendLog(of: item.sourceRef) == log && !knownTasks.contains(item.id) {
            result.append(.init(id: item.id, kind: "new_task", title: item.title, quote: "", outcome: .accepted(task: item.id, title: item.title)))
        }
        for s in tasks.suggestions where TaskStore.sendLog(of: s.sourceRef) == log {
            result.append(.init(id: s.id, kind: s.kind.rawValue, title: s.title, quote: s.quote, outcome: .pending(id: s.id)))
        }
        return result
    }

    static func load(_ log: Int64, capture: CaptureStore, tasks: TaskStore) -> ScreenBatch? {
        guard let record = capture.sendLog(limit: 1_000).first(where: { $0.id == log }) else { return nil }
        let items = record.items.map { id -> ScreenBatch.Item in
            guard let item = capture.item(id: id) else {
                return .init(id: id, app: nil, title: nil, at: nil, state: nil, body: "", redactions: CaptureRedactor.Report())
            }
            return .init(id: id, app: item.appName, title: item.threadTitle, at: item.at, state: item.state, body: item.body, redactions: item.redactions)
        }
        var report = CaptureRedactor.Report()
        for item in items { report.merge(item.redactions) }
        return ScreenBatch(record: record, items: items, suggestions: suggestions(of: log, tasks: tasks), redactions: report)
    }

    /// How many suggestions each send produced, for the count on its row.
    static func counts(_ logs: [Int64], tasks: TaskStore) -> [Int64: Int] {
        Dictionary(uniqueKeysWithValues: logs.map { ($0, suggestions(of: $0, tasks: tasks).count) })
    }
}
