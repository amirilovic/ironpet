import Foundation

/// The tree half of `CaptureStore`: nodes, the blocks seen in a window, and drafts.
extension CaptureStore {
    /// A block seen in the last 7 days with the same text is not new. Older than that it is new again.
    static let blockMemoryDays = 7.0

    /// A draft whose field emptied and that no new block matched within this many seconds was discarded, not sent.
    static let sentWindow = 120.0

    struct TreeContext {
        var windowId: Int64
        var at: Double
        var trigger: CaptureTrigger
        var app: CaptureApp
        var title: String
        var url: String?
    }

    /// One thing that changed on screen, as the change list shows it.
    struct Change: Equatable {
        enum Kind: String { case new, edited, sent, draft }
        var seen: Date
        var kind: Kind
        var container: String?
        var label: String
        var when: String?
        var capture: Int64?
        var ref: String?
        var windowId: Int64
        var app: String
        var appName: String
        var window: String
        var url: String?
    }

    // MARK: Write

    /// Stores a capture of a window that has blocks: the blocks that are new, edited or sent become change rows, and one capture points
    /// at the tree. `ingest` has already dealt with a tree that differs only in typed text.
    func ingestBlocks(_ db: Database.Connection, _ context: TreeContext, _ prepared: CaptureTree.Prepared, _ blocks: [CaptureBlock]) throws -> IngestResult {
        let windowId = context.windowId, at = context.at
        var pending = try db.rows("SELECT key, text FROM capture_draft WHERE window_id = ? AND status = 'draft' AND cleared IS NOT NULL", [windowId])
            .map { (key: $0[0] as? String ?? "", text: CaptureBlocks.normalize($0[1] as? String ?? "")) }
        let memory = at - Self.blockMemoryDays * 86_400
        var changes: [(block: CaptureBlock, kind: Change.Kind)] = []
        var seenNow = Set<String>()
        for block in blocks {
            let textHash = CaptureTree.hash(block.text.isEmpty ? block.label : block.text)
            guard seenNow.insert(block.identity + textHash).inserted else { continue }
            let known = try db.rows("SELECT text_hash FROM capture_block_seen WHERE window_id = ? AND identity = ? AND seen >= ?",
                                    [windowId, block.identity, memory]).compactMap { $0[0] as? String }
            if known.contains(textHash) { continue }
            var kind: Change.Kind = known.isEmpty || !block.stable ? .new : .edited
            if kind == .new, let match = pending.firstIndex(where: { Self.matches(block, draft: $0.text) }) {
                try db.execute("UPDATE capture_draft SET status = 'sent', updated = ? WHERE window_id = ? AND key = ?", [at, windowId, pending[match].key])
                pending.remove(at: match)
                kind = .sent
            }
            changes.append((block, kind))
        }
        try settleDrafts(db, windowId: windowId, at: at)
        guard !changes.isEmpty else { return .unchanged }

        var text: [String] = []
        for change in changes {
            text.append(change.block.label)
            let body = change.block.text
            if !body.isEmpty, !change.block.label.contains(body.replacingOccurrences(of: "\n", with: " ")) { text.append(body) }
        }
        try db.execute("INSERT INTO capture(window_id, at, app, app_name, title, url, trigger, text, root) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)",
                       [windowId, at, context.app.bundleId, context.app.name, context.title, context.url, context.trigger.rawValue,
                        text.joined(separator: "\n"), prepared.root])
        let id = (try db.rows("SELECT last_insert_rowid()")[0][0] as? Int64) ?? 0
        lastNodeWrites = try writeNodes(db, prepared.entries)
        for change in changes {
            let block = change.block
            try db.execute("""
                INSERT INTO capture_block_seen(window_id, identity, text_hash, kind, seen, label, "when", container, capture_id, ref)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [windowId, block.identity, CaptureTree.hash(block.text.isEmpty ? block.label : block.text), change.kind.rawValue, at,
                      block.label, block.when, block.container, id, block.ref])
        }
        return .stored(id: id)
    }

    /// A draft whose field emptied can match a message that showed up a moment earlier, while the field still held the text. Such a
    /// message becomes `sent`. A draft that nothing matched within `sentWindow` seconds was discarded.
    func settleDrafts(_ db: Database.Connection, windowId: Int64, at: Double) throws {
        let pending = try db.rows("SELECT key, text, cleared FROM capture_draft WHERE window_id = ? AND status = 'draft' AND cleared IS NOT NULL", [windowId])
        guard !pending.isEmpty else { return }
        let recent = try db.rows("SELECT id, label FROM capture_block_seen WHERE window_id = ? AND kind = 'new' AND seen >= ?", [windowId, at - Self.sentWindow])
        for row in pending {
            let key = row[0] as? String ?? "", draft = CaptureBlocks.normalize(row[1] as? String ?? ""), cleared = row[2] as? Double ?? at
            if draft.count >= 3, let hit = recent.first(where: { CaptureBlocks.normalize($0[1] as? String ?? "").contains(draft) }) {
                try db.execute("UPDATE capture_block_seen SET kind = 'sent' WHERE id = ?", [hit[0]])
                try db.execute("UPDATE capture_draft SET status = 'sent', updated = ? WHERE window_id = ? AND key = ?", [at, windowId, key])
            } else if cleared < at - Self.sentWindow {
                try db.execute("UPDATE capture_draft SET status = 'discarded' WHERE window_id = ? AND key = ?", [windowId, key])
            }
        }
    }

    /// A window with no blocks (a document, a page, a screenshot read) is one block: the page. Its text is the lines that are new, with
    /// two lines of context. Nothing is stored when no line is new.
    func ingestPage(_ db: Database.Connection, _ context: TreeContext, _ prepared: CaptureTree.Prepared?, _ current: [String], previous: Set<String>) throws -> IngestResult {
        guard let fresh = CaptureDiff.fresh(current: current, isKnown: { previous.contains(Self.digest($0)) }) else { return .unchanged }
        let first = fresh.split(separator: "\n").first { $0 != "…" }.map(String.init) ?? ""
        let name = context.title.isEmpty ? (context.url ?? "") : context.title
        let label = String((name.isEmpty ? first : name + ": " + first).prefix(CaptureBlocks.maxLabelCharacters))
        try db.execute("INSERT INTO capture(window_id, at, app, app_name, title, url, trigger, text, root) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)",
                       [context.windowId, context.at, context.app.bundleId, context.app.name, context.title, context.url, context.trigger.rawValue, fresh, prepared?.root])
        let id = (try db.rows("SELECT last_insert_rowid()")[0][0] as? Int64) ?? 0
        if let prepared { lastNodeWrites = try writeNodes(db, prepared.entries) }
        let seen = try db.rows("SELECT 1 FROM capture_block_seen WHERE window_id = ? AND identity = 'page' AND seen >= ? LIMIT 1",
                               [context.windowId, context.at - Self.blockMemoryDays * 86_400]).isEmpty
        try db.execute("""
            INSERT INTO capture_block_seen(window_id, identity, text_hash, kind, seen, label, capture_id, ref) VALUES(?, 'page', ?, ?, ?, ?, ?, ?)
            """, [context.windowId, CaptureTree.hash(fresh), seen ? "new" : "edited", context.at, label, id, prepared?.root])
        return .stored(id: id)
    }

    private static func matches(_ block: CaptureBlock, draft: String) -> Bool {
        guard !draft.isEmpty else { return false }
        let body = CaptureBlocks.normalize(block.text)
        if draft.count >= 3 { return body.contains(draft) }
        return block.text.split(whereSeparator: \.isNewline).contains { CaptureBlocks.normalize(String($0)) == draft }
    }

    /// Writes the nodes a tree needs that are not stored yet, and returns how many it wrote.
    func writeNodes(_ db: Database.Connection, _ entries: [CaptureTree.Entry]) throws -> Int {
        var written = 0
        for start in stride(from: 0, to: entries.count, by: 400) {
            let chunk = Array(entries[start..<min(start + 400, entries.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let have = Set(try db.rows("SELECT hash FROM capture_node WHERE hash IN (\(marks))", chunk.map(\.hash)).compactMap { $0[0] as? String })
            for entry in chunk where !have.contains(entry.hash) {
                try db.execute("INSERT INTO capture_node(hash, data) VALUES(?, ?)", [entry.hash, entry.data])
                written += 1
            }
        }
        return written
    }

    /// Deletes every node that no capture's root reaches.
    func sweepNodes(_ db: Database.Connection) throws {
        var reached = Set(try db.rows("SELECT DISTINCT root FROM capture WHERE root IS NOT NULL").compactMap { $0[0] as? String })
        var frontier = Array(reached)
        while !frontier.isEmpty {
            var next: [String] = []
            for start in stride(from: 0, to: frontier.count, by: 400) {
                let chunk = Array(frontier[start..<min(start + 400, frontier.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for row in try db.rows("SELECT data FROM capture_node WHERE hash IN (\(marks))", chunk) {
                    for child in CaptureTree.children(of: row[0] as? String ?? "") where reached.insert(child).inserted { next.append(child) }
                }
            }
            frontier = next
        }
        try db.script("CREATE TEMP TABLE IF NOT EXISTS capture_reached(hash TEXT PRIMARY KEY) WITHOUT ROWID; DELETE FROM capture_reached;")
        for hash in reached { try db.execute("INSERT INTO capture_reached(hash) VALUES(?)", [hash]) }
        try db.execute("DELETE FROM capture_node WHERE hash NOT IN (SELECT hash FROM capture_reached)")
        try db.script("DROP TABLE capture_reached")
    }

    // MARK: Drafts

    struct InputField: Equatable {
        var key: String
        var name: String?
        var text: String
    }

    /// The input fields of a tree that hold text. A field is keyed by its page id, else by its name, else by where it is in the tree.
    static func inputs(in root: AXNode) -> [InputField] {
        var out: [InputField] = []
        func walk(_ node: AXNode, path: String) {
            if node.isSecure { return }
            if CaptureTree.isInput(node) {
                if let text = node.value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    out.append(InputField(key: node.domId.map { "d:" + $0 } ?? node.name.map { "n:" + $0 } ?? "p:" + path, name: node.name, text: text))
                }
                return
            }
            for (index, child) in node.children.enumerated() { walk(child, path: path + "." + String(index)) }
        }
        walk(root, path: "0")
        return out
    }

    /// One row per input field, updated in place while the person types. A field that goes empty keeps its row until a block shows up
    /// that holds its text (sent) or the time runs out (discarded).
    func updateDrafts(_ db: Database.Connection, windowId: Int64, at: Double, fields: [InputField]) throws {
        let existing = Dictionary(uniqueKeysWithValues: try db.rows("SELECT key, text, status FROM capture_draft WHERE window_id = ?", [windowId])
            .map { ($0[0] as? String ?? "", (text: $0[1] as? String ?? "", status: $0[2] as? String ?? "")) })
        for field in fields {
            if let row = existing[field.key] {
                if row.status == "draft", row.text == field.text {
                    try db.execute("UPDATE capture_draft SET cleared = NULL WHERE window_id = ? AND key = ?", [windowId, field.key])
                } else {
                    try db.execute("UPDATE capture_draft SET text = ?, field = ?, status = 'draft', updated = ?, cleared = NULL WHERE window_id = ? AND key = ?",
                                   [field.text, field.name, at, windowId, field.key])
                }
            } else {
                try db.execute("INSERT INTO capture_draft(window_id, key, field, text, status, first_seen, updated) VALUES(?, ?, ?, ?, 'draft', ?, ?)",
                               [windowId, field.key, field.name, field.text, at, at])
            }
        }
        let live = Set(fields.map(\.key))
        for (key, row) in existing where row.status == "draft" && !live.contains(key) {
            try db.execute("UPDATE capture_draft SET cleared = COALESCE(cleared, ?) WHERE window_id = ? AND key = ?", [at, windowId, key])
        }
    }

    // MARK: Read the tree

    /// Rebuilds a stored tree from its root hash, one level of nodes per query. Nil when a node is missing.
    func tree(root: String) -> AXNode? {
        (try? database.read { db -> AXNode? in
            var loaded: [String: (node: AXNode, children: [String])] = [:]
            var frontier = [root]
            while !frontier.isEmpty {
                var next: [String] = []
                for start in stride(from: 0, to: frontier.count, by: 400) {
                    let chunk = Array(frontier[start..<min(start + 400, frontier.count)])
                    let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    for row in try db.rows("SELECT hash, data FROM capture_node WHERE hash IN (\(marks))", chunk) {
                        guard let hash = row[0] as? String, let data = row[1] as? String, let decoded = CaptureTree.decode(hash: hash, data: data) else { continue }
                        loaded[hash] = decoded
                        next += decoded.children.filter { loaded[$0] == nil }
                    }
                }
                frontier = Array(Set(next))
            }
            func build(_ hash: String, depth: Int) -> AXNode? {
                guard depth <= 80, let entry = loaded[hash] else { return nil }
                var node = entry.node
                for child in entry.children {
                    guard let built = build(child, depth: depth + 1) else { return nil }
                    node.children.append(built)
                }
                return node
            }
            return build(root, depth: 0)
        }) ?? nil
    }

    /// The tree of a stored capture, with the read filter applied to its text.
    func tree(ofCapture id: Int64) -> AXNode? {
        guard let capture = capture(id: id), let root = capture.root, let tree = tree(root: root) else { return nil }
        return Self.mapText(tree) { [filter] in filter.filterOnRead($0, app: capture.app) }
    }

    private static func mapText(_ node: AXNode, _ transform: (String) -> String) -> AXNode {
        var copy = node
        copy.title = node.title.map(transform)
        copy.value = node.value.map(transform)
        copy.description = node.description.map(transform)
        copy.children = node.children.map { mapText($0, transform) }
        return copy
    }

    // MARK: Read the change list

    /// What changed on screen in a range, oldest first: blocks that were new, edited or sent, and drafts being typed.
    func changes(app: String? = nil, window: String? = nil, since: Date? = nil, until: Date? = nil) -> [Change] {
        var clauses: [String] = [], args: [Database.Value] = []
        if let app, !app.isEmpty { clauses.append("(w.app = ? COLLATE NOCASE OR w.app_name = ? COLLATE NOCASE)"); args += [app, app] }
        if let window, !window.isEmpty {
            clauses.append("(w.title LIKE ? ESCAPE '\\' OR w.url LIKE ? ESCAPE '\\')")
            let pattern = "%" + Self.likeEscaped(window) + "%"
            args += [pattern, pattern]
        }
        var blockArgs = args, draftArgs = args
        var blockClauses = clauses, draftClauses = clauses + ["d.status = 'draft'"]
        if let since { blockClauses.append("b.seen >= ?"); blockArgs.append(since.timeIntervalSince1970); draftClauses.append("d.updated >= ?"); draftArgs.append(since.timeIntervalSince1970) }
        if let until { blockClauses.append("b.seen < ?"); blockArgs.append(until.timeIntervalSince1970); draftClauses.append("d.updated < ?"); draftArgs.append(until.timeIntervalSince1970) }
        let blockWhere = blockClauses.isEmpty ? "" : "WHERE " + blockClauses.joined(separator: " AND ")
        let draftWhere = "WHERE " + draftClauses.joined(separator: " AND ")
        let blocks = (try? database.read {
            try $0.rows("""
                SELECT b.seen, b.kind, b.container, b.label, b."when", b.capture_id, b.ref, w.id, w.app, w.app_name, w.title, w.url
                FROM capture_block_seen b JOIN capture_window w ON w.id = b.window_id \(blockWhere) ORDER BY b.seen, b.id
                """, blockArgs)
        }) ?? []
        let drafts = (try? database.read {
            try $0.rows("""
                SELECT d.updated, 'draft', d.field, d.text, NULL, NULL, NULL, w.id, w.app, w.app_name, w.title, w.url
                FROM capture_draft d JOIN capture_window w ON w.id = d.window_id \(draftWhere) ORDER BY d.updated
                """, draftArgs)
        }) ?? []
        return (blocks + drafts).compactMap { row -> Change? in
            guard let kind = Change.Kind(rawValue: row[1] as? String ?? "") else { return nil }
            let app = row[8] as? String ?? ""
            func read(_ value: Database.Value) -> String? { (value as? String).map { filter.filterOnRead($0, app: app) } }
            return Change(seen: Date(timeIntervalSince1970: row[0] as? Double ?? 0), kind: kind, container: read(row[2]), label: read(row[3]) ?? "",
                          when: read(row[4]), capture: row[5] as? Int64, ref: row[6] as? String, windowId: row[7] as? Int64 ?? 0, app: app,
                          appName: row[9] as? String ?? app, window: row[10] as? String ?? "", url: row[11] as? String)
        }.sorted { $0.seen < $1.seen }
    }
}
