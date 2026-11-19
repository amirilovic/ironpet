import Foundation

/// The task list Ghost keeps, in `ironpet.db`. The agent owns it: it creates, updates and closes tasks through `call`
/// (MCP tools and the CLI). The UI can only mark a task done, delete it, and add or skip suggestions from meetings and
/// watcher automations.
/// Every change is a row in `task_events`, so nothing an agent rewrites is lost.
@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var suggestions: [TaskSuggestion] = []

    nonisolated static let migrations: [Database.Migration] = [
        .init(200, "tasks: items, links, events, suggestions", sql: """
            CREATE TABLE task_items(id TEXT PRIMARY KEY, title TEXT NOT NULL, notes TEXT NOT NULL, status TEXT NOT NULL,
                                    source TEXT NOT NULL, due REAL, created REAL NOT NULL, updated REAL NOT NULL, closed REAL) WITHOUT ROWID;
            CREATE TABLE task_links(task TEXT NOT NULL, position INTEGER NOT NULL, kind TEXT NOT NULL, ref TEXT NOT NULL, label TEXT,
                                    PRIMARY KEY(task, position)) WITHOUT ROWID;
            CREATE TABLE task_events(id INTEGER PRIMARY KEY AUTOINCREMENT, task TEXT NOT NULL, at REAL NOT NULL, by TEXT NOT NULL,
                                     kind TEXT NOT NULL, detail TEXT NOT NULL);
            CREATE INDEX task_events_by_task ON task_events(task, id);
            CREATE TABLE task_suggestions(id TEXT PRIMARY KEY, title TEXT NOT NULL, due TEXT, meeting TEXT NOT NULL,
                                          created REAL NOT NULL) WITHOUT ROWID;
            """),
        // Versions after 300 because they came after screen capture's. A development build numbered them 201 to 203, so a
        // database may already have these changes: each step checks before it runs.
        .init(303, "tasks: suggestions from automations") { db in
            if try !TaskStore.columns(db, "task_suggestions").contains("automation") {
                try db.script("""
                    CREATE TABLE task_suggestions_303(id TEXT PRIMARY KEY, title TEXT NOT NULL, due TEXT, notes TEXT NOT NULL DEFAULT '', url TEXT,
                                                      meeting TEXT, automation TEXT, automation_name TEXT, created REAL NOT NULL,
                                                      CHECK ((meeting IS NULL) <> (automation IS NULL))) WITHOUT ROWID;
                    INSERT INTO task_suggestions_303(id, title, due, meeting, created) SELECT id, title, due, meeting, created FROM task_suggestions;
                    DROP TABLE task_suggestions;
                    ALTER TABLE task_suggestions_303 RENAME TO task_suggestions;
                    """)
            }
            try db.script("""
                CREATE TABLE IF NOT EXISTS task_suggestion_keys(automation TEXT NOT NULL, key TEXT NOT NULL, at REAL NOT NULL,
                                                                PRIMARY KEY(automation, key)) WITHOUT ROWID;
                """)
        },
        .init(304, "tasks: waiting on someone else") { db in
            for table in ["task_items", "task_suggestions"] where try !TaskStore.columns(db, table).contains("waiting_on") {
                try db.execute("ALTER TABLE \(table) ADD COLUMN waiting_on TEXT")
            }
        },
        .init(305, "tasks: due reminders", sql: """
            CREATE TABLE IF NOT EXISTS task_due_marks(task TEXT PRIMARY KEY, due REAL NOT NULL, snoozed_until REAL) WITHOUT ROWID;
            """),
        // A table's CHECK cannot change in place, so the table is rebuilt with every row copied. `capture` holds the
        // fingerprint of a screen capture proposal, and exactly one of the three origin columns is set.
        .init(421, "tasks: suggestions from screen capture") { db in
            if try !TaskStore.columns(db, "task_suggestions").contains("capture") {
                try db.script("""
                    CREATE TABLE task_suggestions_421(id TEXT PRIMARY KEY, title TEXT NOT NULL, due TEXT, notes TEXT NOT NULL DEFAULT '', url TEXT,
                                                      meeting TEXT, automation TEXT, automation_name TEXT, created REAL NOT NULL, waiting_on TEXT,
                                                      capture TEXT, kind TEXT, target TEXT, changes TEXT, diff TEXT, quote TEXT, evidence TEXT,
                                                      CHECK ((meeting IS NOT NULL) + (automation IS NOT NULL) + (capture IS NOT NULL) = 1)) WITHOUT ROWID;
                    INSERT INTO task_suggestions_421(id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on)
                        SELECT id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on FROM task_suggestions;
                    DROP TABLE task_suggestions;
                    ALTER TABLE task_suggestions_421 RENAME TO task_suggestions;
                    """)
            }
        },
        .init(422, "tasks: where a task or suggestion came from") { db in
            for table in ["task_items", "task_suggestions"] where try !TaskStore.columns(db, table).contains("source_ref") {
                try db.execute("ALTER TABLE \(table) ADD COLUMN source_ref TEXT")
            }
        },
        // Numbered above every migration in the app (usage's 430 is the highest), so a database already past 430 still runs it.
        // A resolved suggestion leaves task_suggestions, so this keeps what happened to each one for the batch that produced it.
        .init(431, "tasks: what became of each screen capture suggestion", sql: """
            CREATE TABLE IF NOT EXISTS task_suggestion_outcomes(id INTEGER PRIMARY KEY AUTOINCREMENT, send_log INTEGER NOT NULL,
                suggestion TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, quote TEXT NOT NULL DEFAULT '', outcome TEXT NOT NULL,
                task TEXT, note TEXT, at REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS task_suggestion_outcomes_by_log ON task_suggestion_outcomes(send_log, id);
            """),
        // The in-app screen capture analysis is gone, so its proposals, their columns and the outcome log go with it. Suggestions from
        // meetings and automations are copied over unchanged. A table's CHECK cannot change in place, so the table is rebuilt.
        .init(441, "tasks: drop screen capture suggestions and outcomes") { db in
            try db.script("""
                CREATE TABLE task_suggestions_441(id TEXT PRIMARY KEY, title TEXT NOT NULL, due TEXT, notes TEXT NOT NULL DEFAULT '', url TEXT,
                                                  meeting TEXT, automation TEXT, automation_name TEXT, created REAL NOT NULL, waiting_on TEXT,
                                                  source_ref TEXT, CHECK ((meeting IS NULL) <> (automation IS NULL))) WITHOUT ROWID;
                INSERT INTO task_suggestions_441(id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on, source_ref)
                    SELECT id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on, source_ref
                    FROM task_suggestions WHERE meeting IS NOT NULL OR automation IS NOT NULL;
                DROP TABLE task_suggestions;
                ALTER TABLE task_suggestions_441 RENAME TO task_suggestions;
                DROP TABLE IF EXISTS task_suggestion_outcomes;
                """)
        },
    ]

    /// A source reference as stored: a JSON object, keys sorted.
    nonisolated static func refText(_ object: [String: Any]) -> String? { TaskRef.text(object) }

    /// The column names of `table`, empty when it does not exist.
    nonisolated static func columns(_ db: Database.Connection, _ table: String) throws -> Set<String> {
        Set(try db.rows("SELECT name FROM pragma_table_info(?)", [table]).compactMap { $0[0] as? String })
    }

    /// Suggestions one automation can have waiting. More wait in the watcher until the user adds or skips some.
    static let maxPendingPerAutomation = 50
    /// How long an automation's suggested keys are remembered, so a skipped one does not come back.
    static let keepSuggestedKeysDays = 365

    /// Called after any change, with the task's id (nil for suggestions).
    var onChange: ((String?) -> Void)?
    /// Where changes are published for API clients: `tasks.changed` with the task's id, `suggestions.changed` without one.
    weak var events: APIEventBus?

    private func didChange(_ id: String?) {
        events?.publish(id == nil ? .suggestionsChanged : .tasksChanged, id: id)
        onChange?(id)
    }

    private let database: Database
    private let now: () -> Date
    private let keepDoneDays: @MainActor () -> Int
    private var lastPrune = Date.distantPast

    init(database: Database, now: @escaping () -> Date = Date.init,
         keepDoneDays: @escaping @MainActor () -> Int = { ConfigStore.shared.config.tasks.keepDoneDays }) {
        self.database = database
        self.now = now
        self.keepDoneDays = keepDoneDays
        prune()
        reload()
    }

    // MARK: Reading

    /// Why the database is unavailable, when tasks are only in memory.
    var unavailable: String? { database.unavailableReason }

    func task(_ id: String) -> TaskItem? { tasks.first { $0.id == id } }

    /// Open tasks first (needs you, in progress, backlog), then done, newest first within each.
    var ordered: [TaskItem] {
        let rank: [TaskStatus: Int] = [.needsYou: 0, .inProgress: 1, .backlog: 2, .done: 3]
        return tasks.sorted { a, b in
            if rank[a.status]! != rank[b.status]! { return rank[a.status]! < rank[b.status]! }
            return (a.closed ?? a.updated) > (b.closed ?? b.updated)
        }
    }

    /// What the Tasks section counts: the user's own work that is moving or waiting on them. Tasks waiting on someone else
    /// are left out.
    var activeCount: Int { tasks.filter { $0.waitingOn == nil && ($0.status == .needsYou || $0.status == .inProgress) }.count }

    func history(_ id: String) -> [TaskEvent] {
        (try? database.read { db in
            try db.rows("SELECT at, by, kind, detail FROM task_events WHERE task = ? ORDER BY id", [id]).compactMap { row in
                guard let at = row[0] as? Double, let by = row[1] as? String,
                      let kind = (row[2] as? String).flatMap(TaskEvent.Kind.init(rawValue:)) else { return nil }
                return TaskEvent(at: Date(timeIntervalSince1970: at), by: by, kind: kind, detail: row[3] as? String ?? "")
            }
        }) ?? []
    }

    // MARK: Changing

    @discardableResult
    func create(title: String, notes: String = "", status: TaskStatus = .backlog, source: TaskSource, due: Date? = nil,
                links: [TaskLink] = [], waitingOn: String? = nil, sourceRef: String? = nil, by: String) throws -> TaskItem {
        let title = try TaskValidator.title(title)
        let notes = try TaskValidator.notes(notes)
        let waitingOn = try TaskValidator.waitingOn(waitingOn)
        let id = AutomationValidator.slug(title, taken: Set(tasks.map(\.id)).union(deletedIDs()))
        let time = now()
        let item = TaskItem(id: id, title: title, notes: notes, status: status, source: source, due: due, links: links,
                            created: time, updated: time, closed: status == .done ? time : nil, waitingOn: waitingOn, sourceRef: sourceRef)
        try database.write { db in
            try Self.save(item, db)
            try Self.log(db, id, time, by, .created, "\(status.rawValue): \(title)" + (waitingOn.map { " (waiting on \($0))" } ?? "")
                         + (sourceRef.map { " [source: \(source.rawValue) \($0)]" } ?? ""))
        }
        reload()
        didChange(id)
        return task(id) ?? item
    }

    /// Applies the fields that are present. `note` goes to history only, so the agent can say why it changed something.
    @discardableResult
    func update(_ id: String, title: String? = nil, notes: String? = nil, status: TaskStatus? = nil, due: Date?? = nil,
                links: [TaskLink]? = nil, waitingOn: String?? = nil, note: String? = nil, by: String) throws -> TaskItem {
        guard var item = task(id) else { throw TaskError(message: "no task with id \"\(id)\"") }
        let time = now()
        var events: [(TaskEvent.Kind, String)] = []
        if let title {
            let title = try TaskValidator.title(title)
            if title != item.title { events.append((.edited, "title: \(title)")); item.title = title }
        }
        if let notes {
            let notes = try TaskValidator.notes(notes)
            if notes != item.notes { events.append((.edited, "notes")); item.notes = notes }
        }
        if let due, due != item.due {
            item.due = due
            events.append((.edited, "due: \(due.map { ISO8601DateFormatter().string(from: $0) } ?? "none")"))
        }
        if let links, links != item.links { item.links = links; events.append((.edited, "links: \(links.count)")) }
        if let waitingOn {
            let waitingOn = try TaskValidator.waitingOn(waitingOn)
            if waitingOn != item.waitingOn { item.waitingOn = waitingOn; events.append((.edited, "waiting on: \(waitingOn ?? "none")")) }
        }
        if let status, status != item.status {
            events.append((status == .done ? .closed : .status, "\(item.status.rawValue) → \(status.rawValue)"))
            item.status = status
            item.closed = status == .done ? time : nil
        }
        if let note {
            let note = try TaskValidator.notes(note)
            if !note.isEmpty { events.append((.note, note)) }
        }
        guard !events.isEmpty else { return item }
        item.updated = time
        let changed = item
        try database.write { db in
            try Self.save(changed, db)
            for (kind, detail) in events { try Self.log(db, id, time, by, kind, detail) }
        }
        reload()
        didChange(id)
        return task(id) ?? changed
    }

    @discardableResult
    func close(_ id: String, note: String? = nil, by: String) throws -> TaskItem {
        try update(id, status: .done, note: note, by: by)
    }

    func delete(_ id: String, by: String) throws {
        guard let item = task(id) else { throw TaskError(message: "no task with id \"\(id)\"") }
        let time = now()
        try database.write { db in
            try db.execute("DELETE FROM task_items WHERE id = ?", [id])
            try db.execute("DELETE FROM task_links WHERE task = ?", [id])
            try db.execute("DELETE FROM task_due_marks WHERE task = ?", [id])
            // The history stays until prune, so a deleted task can still be explained.
            try Self.log(db, id, time, by, .deleted, item.title)
        }
        reload()
        didChange(id)
    }

    // MARK: Suggestions

    /// Stores meeting action items as suggestions. Items already suggested or already a task with the same title are skipped.
    @discardableResult
    func suggest(_ items: [(title: String, due: String?, waitingOn: String?)], meeting: URL) -> [TaskSuggestion] {
        store(items.map { TaskSuggestion.Draft(key: "", title: $0.title, due: $0.due, waitingOn: $0.waitingOn) }, origin: .meeting(meeting))
    }

    /// Stores what a watcher automation proposed. Besides the title check, a key this automation suggested before is
    /// left out, even after it was added or skipped.
    @discardableResult
    func suggest(_ drafts: [TaskSuggestion.Draft], automation id: String, name: String) -> [TaskSuggestion] {
        let seen = suggestedKeys(id)
        var keys = Set<String>()
        let fresh = drafts.filter { !seen.contains($0.key) && keys.insert($0.key).inserted }
        let waiting = suggestions.filter { if case .automation(let other, _) = $0.origin { return other == id } else { return false } }.count
        let name = TaskSuggestion.Draft.clean(name, limit: 100, newlines: false)
        return store(fresh, origin: .automation(id: id, name: name.isEmpty ? id : name), limit: Self.maxPendingPerAutomation - waiting)
    }

    /// Stores what an agent proposed through `tasks_suggest`. It goes through the same path as a watcher's `suggest_task`, so the
    /// same dedupe and limits apply. Agent suggestions share one source per origin kind (`agent:email`, `agent:pr`), so an id from
    /// mail never collides with an automation's id or with an id from another kind. `sourceRef` is the origin the agent gave.
    @discardableResult
    func suggest(_ draft: TaskSuggestion.Draft, agent kind: TaskSource, sourceRef: String) -> [TaskSuggestion] {
        let id = "agent:\(kind.rawValue)"
        guard !suggestedKeys(id).contains(draft.key) else { return [] }
        let waiting = suggestions.filter { if case .automation(let other, _) = $0.origin { return other == id } else { return false } }.count
        return store([draft], origin: .automation(id: id, name: "\(kind.rawValue) agent"), limit: Self.maxPendingPerAutomation - waiting,
                     sourceRef: sourceRef)
    }

    private func store(_ drafts: [TaskSuggestion.Draft], origin: TaskSuggestion.Origin, limit: Int = .max,
                       sourceRef: String? = nil) -> [TaskSuggestion] {
        // Compared by `ActionItems.normalized`, so a regenerated summary that words an item with another case, spacing or
        // closing full stop does not offer it a second time.
        let existing = Set(tasks.map { ActionItems.normalized($0.title) } + suggestions.map { ActionItems.normalized($0.title) })
        let time = now()
        var added: [(key: String, suggestion: TaskSuggestion)] = []
        var taken = Set(suggestions.map(\.id))
        for draft in drafts where added.count < limit {
            guard let title = try? TaskValidator.title(draft.title), !existing.contains(ActionItems.normalized(title)),
                  !added.contains(where: { ActionItems.normalized($0.suggestion.title) == ActionItems.normalized(title) }) else { continue }
            let id = AutomationValidator.slug(title, taken: taken)
            taken.insert(id)
            let waitingOn = draft.waitingOn.flatMap { try? TaskValidator.waitingOn(String($0.prefix(TaskValidator.maxWaitingOn))) }
            let ref: [String: Any]
            switch origin {
            case .meeting(let folder):
                ref = ["ref": folder.path, "reason": "Action item from the meeting summary", "meeting": folder.path]
            case .automation(let automation, let name):
                ref = ["ref": automation, "reason": "Suggested by the \(name) watcher", "automation": automation,
                       "at": ISO8601DateFormatter().string(from: time)]
            }
            added.append((draft.key, TaskSuggestion(id: id, title: title, due: draft.due, notes: draft.notes, url: draft.url,
                                                    origin: origin, created: time, waitingOn: waitingOn, sourceRef: sourceRef ?? Self.refText(ref))))
        }
        guard !added.isEmpty else { return [] }
        do {
            try database.write { db in
                for (key, s) in added {
                    var meeting: String?, automation: String?, name: String?
                    switch s.origin {
                    case .meeting(let folder): meeting = folder.path
                    case .automation(let id, let n):
                        (automation, name) = (id, n)
                        try db.execute("INSERT OR REPLACE INTO task_suggestion_keys(automation, key, at) VALUES(?, ?, ?)",
                                       [id, key, time.timeIntervalSince1970])
                    }
                    try db.execute("""
                        INSERT INTO task_suggestions(id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on, source_ref)
                        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, [s.id, s.title, s.due, s.notes, s.url?.absoluteString, meeting, automation, name,
                              s.created.timeIntervalSince1970, s.waitingOn, s.sourceRef])
                }
            }
        } catch {
            NSLog("ironpet: could not store task suggestions: \(error.localizedDescription)")
            return []
        }
        reload()
        didChange(nil)
        return added.map(\.suggestion)
    }

    private func suggestedKeys(_ automation: String) -> Set<String> {
        Set((try? database.read { db in
            try db.rows("SELECT key FROM task_suggestion_keys WHERE automation = ?", [automation]).compactMap { $0[0] as? String }
        }) ?? [])
    }

    /// What a reviewer may change before accepting. Nil fields keep the suggestion's own value.
    struct Overrides {
        var title: String?
        var due: String?
        var notes: String?
        var status: String?
    }

    /// Turns a suggestion into a backlog task, linked to its meeting folder or to the url the automation gave, and waiting
    /// on the suggestion's owner if it has one. `note` goes to the new task's history.
    @discardableResult
    func accept(_ suggestionID: String, overrides: Overrides = Overrides(), note: String? = nil, by: String = "user") throws -> TaskItem {
        guard let s = suggestions.first(where: { $0.id == suggestionID }) else { throw TaskError(message: "no suggestion \"\(suggestionID)\"") }
        let note = try note.map { try TaskValidator.notes($0) }
        let due = try? TaskValidator.due(overrides.due ?? s.due)
        var notes = overrides.notes ?? s.notes
        var links: [TaskLink] = []
        if let folder = s.meeting {
            links.append(TaskLink(kind: .file, ref: folder.path, label: "Meeting"))
            if due == nil, let text = s.due { notes = "Due (from the meeting): \(text)" }
        }
        if let url = s.url { links.append(TaskLink(kind: .url, ref: url.absoluteString, label: nil)) }
        let status = try overrides.status.map { try TaskValidator.status($0) } ?? .backlog
        var item = try create(title: overrides.title ?? s.title, notes: notes, status: status, source: s.source, due: due, links: links,
                              waitingOn: s.waitingOn, sourceRef: s.sourceRef, by: by)
        if let note, !note.isEmpty { item = try update(item.id, note: note, by: by) }
        removeSuggestion(suggestionID)
        return item
    }

    /// Adds every suggestion as a new task.
    func acceptAll() {
        for s in suggestions { _ = try? accept(s.id) }
    }

    /// Removes a suggestion.
    func skip(_ suggestionID: String) {
        removeSuggestion(suggestionID)
    }

    /// `skip` with a reason, for a reviewer.
    func reject(_ suggestionID: String, note: String? = nil, by: String) throws {
        guard suggestions.contains(where: { $0.id == suggestionID }) else { throw TaskError(message: "no suggestion \"\(suggestionID)\"") }
        _ = try note.map { try TaskValidator.notes($0) }
        skip(suggestionID)
    }

    // MARK: Due reminders

    /// Which tasks were announced as due, by id. Read from the database so a relaunch does not announce them again.
    func dueMarks() -> [String: TaskDueMark] {
        let rows = (try? database.read { try $0.rows("SELECT task, due, snoozed_until FROM task_due_marks") }) ?? []
        var marks: [String: TaskDueMark] = [:]
        for row in rows {
            guard let task = row[0] as? String, let due = row[1] as? Double else { continue }
            marks[task] = TaskDueMark(due: Date(timeIntervalSince1970: due),
                                      snoozedUntil: (row[2] as? Double).map(Date.init(timeIntervalSince1970:)))
        }
        return marks
    }

    /// Records that these tasks were announced for their current due date, and when to announce them again (nil: never).
    func markDue(_ items: [TaskItem], snoozedUntil: Date?) {
        let items = items.filter { $0.due != nil }
        guard !items.isEmpty else { return }
        do {
            try database.write { db in
                for item in items {
                    try db.execute("INSERT OR REPLACE INTO task_due_marks(task, due, snoozed_until) VALUES(?, ?, ?)",
                                   [item.id, item.due!.timeIntervalSince1970, snoozedUntil?.timeIntervalSince1970])
                }
            }
        } catch {
            NSLog("ironpet: could not store task reminders: \(error.localizedDescription)")
        }
    }

    private func removeSuggestion(_ id: String) {
        try? database.write { try $0.execute("DELETE FROM task_suggestions WHERE id = ?", [id]) }
        reload()
        didChange(nil)
    }

    // MARK: Storage

    /// Done tasks past `tasks.keepDoneDays`, and history of tasks that no longer exist, at launch and at most daily.
    func prune() {
        let time = now()
        guard time.timeIntervalSince(lastPrune) > 86_400 else { return }
        lastPrune = time
        let cutoff = time.addingTimeInterval(-Double(keepDoneDays()) * 86_400).timeIntervalSince1970
        do {
            try database.write { db in
                try db.execute("DELETE FROM task_links WHERE task IN (SELECT id FROM task_items WHERE status = 'done' AND closed < ?)", [cutoff])
                try db.execute("DELETE FROM task_items WHERE status = 'done' AND closed < ?", [cutoff])
                try db.execute("DELETE FROM task_due_marks WHERE task NOT IN (SELECT id FROM task_items)")
                try db.execute("DELETE FROM task_events WHERE at < ? AND task NOT IN (SELECT id FROM task_items)", [cutoff])
                try db.execute("DELETE FROM task_suggestion_keys WHERE at < ?",
                               [time.addingTimeInterval(-Double(Self.keepSuggestedKeysDays) * 86_400).timeIntervalSince1970])
            }
        } catch {
            NSLog("ironpet: could not prune tasks: \(error.localizedDescription)")
        }
    }

    /// Ids whose history is still kept, so a new task never inherits a deleted task's events.
    private func deletedIDs() -> Set<String> {
        Set((try? database.read { db in
            try db.rows("SELECT DISTINCT task FROM task_events").compactMap { $0[0] as? String }
        }) ?? [])
    }

    func reload() {
        prune()
        do {
            let (items, suggested) = try database.read { db -> ([TaskItem], [TaskSuggestion]) in
                var links: [String: [TaskLink]] = [:]
                for row in try db.rows("SELECT task, kind, ref, label FROM task_links ORDER BY task, position") {
                    guard let task = row[0] as? String, let kind = (row[1] as? String).flatMap(TaskLink.Kind.init(rawValue:)),
                          let ref = row[2] as? String else { continue }
                    links[task, default: []].append(TaskLink(kind: kind, ref: ref, label: row[3] as? String))
                }
                let items = try db.rows("SELECT id, title, notes, status, source, due, created, updated, closed, waiting_on, source_ref FROM task_items").compactMap { row -> TaskItem? in
                    guard let id = row[0] as? String, let title = row[1] as? String,
                          let status = (row[3] as? String).flatMap(TaskStatus.init(rawValue:)),
                          let created = row[6] as? Double, let updated = row[7] as? Double else { return nil }
                    return TaskItem(id: id, title: title, notes: row[2] as? String ?? "", status: status,
                                    source: (row[4] as? String).flatMap(TaskSource.init(rawValue:)) ?? .agent,
                                    due: (row[5] as? Double).map(Date.init(timeIntervalSince1970:)), links: links[id] ?? [],
                                    created: Date(timeIntervalSince1970: created), updated: Date(timeIntervalSince1970: updated),
                                    closed: (row[8] as? Double).map(Date.init(timeIntervalSince1970:)), waitingOn: row[9] as? String,
                                    sourceRef: row[10] as? String)
                }
                let suggested = try db.rows("""
                    SELECT id, title, due, notes, url, meeting, automation, automation_name, created, waiting_on, source_ref
                    FROM task_suggestions ORDER BY created, id
                    """).compactMap { row -> TaskSuggestion? in
                    guard let id = row[0] as? String, let title = row[1] as? String, let created = row[8] as? Double else { return nil }
                    let origin: TaskSuggestion.Origin
                    if let meeting = row[5] as? String {
                        origin = .meeting(URL(fileURLWithPath: meeting))
                    } else if let automation = row[6] as? String {
                        origin = .automation(id: automation, name: row[7] as? String ?? automation)
                    } else {
                        return nil
                    }
                    return TaskSuggestion(id: id, title: title, due: row[2] as? String, notes: row[3] as? String ?? "",
                                          url: (row[4] as? String).flatMap(URL.init(string:)), origin: origin,
                                          created: Date(timeIntervalSince1970: created), waitingOn: row[9] as? String,
                                          sourceRef: row[10] as? String)
                }
                return (items, suggested)
            }
            if items != tasks { tasks = items }
            if suggested != suggestions { suggestions = suggested }
        } catch {
            NSLog("ironpet: could not read tasks: \(error.localizedDescription)")
        }
    }

    private static func save(_ item: TaskItem, _ db: Database.Connection) throws {
        try db.execute("""
            INSERT OR REPLACE INTO task_items(id, title, notes, status, source, due, created, updated, closed, waiting_on, source_ref)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [item.id, item.title, item.notes, item.status.rawValue, item.source.rawValue, item.due?.timeIntervalSince1970,
                  item.created.timeIntervalSince1970, item.updated.timeIntervalSince1970, item.closed?.timeIntervalSince1970,
                  item.waitingOn, item.sourceRef])
        try db.execute("DELETE FROM task_links WHERE task = ?", [item.id])
        for (position, link) in item.links.enumerated() {
            try db.execute("INSERT INTO task_links(task, position, kind, ref, label) VALUES(?, ?, ?, ?, ?)",
                           [item.id, position, link.kind.rawValue, link.ref, link.label])
        }
    }

    private static func log(_ db: Database.Connection, _ task: String, _ at: Date, _ by: String, _ kind: TaskEvent.Kind, _ detail: String) throws {
        try db.execute("INSERT INTO task_events(task, at, by, kind, detail) VALUES(?, ?, ?, ?, ?)",
                       [task, at.timeIntervalSince1970, by, kind.rawValue, detail])
    }
}
