import Foundation

/// The `screen_*` tools' work over the capture store. They sit in the API layer because they read the store; `ScreenMCP`
/// keeps only the tool definitions and the text helpers.
extension ScreenMCP {
    static func call(_ name: String, _ args: [String: Any], store: CaptureStore, now: Date = Date(), calendar: Calendar = .current) -> Result<Any, Failure> {
        func text(_ key: String) -> String? { (args[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        func time(_ key: String) -> Result<Date?, Failure> {
            guard let raw = text(key) else { return .success(nil) }
            guard let date = parse(raw, now: now, calendar: calendar) else {
                return .failure(Failure(message: "\(key) is not a time: \(raw). Use today, yesterday, now, 2026-11-18, an ISO 8601 time or an age such as 2h."))
            }
            return .success(date)
        }
        let since: Date?, until: Date?
        switch (time("since"), time("until")) {
        case (.failure(let error), _), (_, .failure(let error)): return .failure(error)
        case (.success(let a), .success(let b)): (since, until) = (a, b)
        }
        switch name {
        case "screen_search":
            guard let query = text("query") else { return .failure(Failure(message: "query is required")) }
            let limit = (args["limit"] as? Int) ?? 20
            let hits = store.search(query, app: text("app"), since: since, until: until, limit: limit)
            return .success(["count": hits.count, "hits": hits.map { hit -> [String: Any] in
                var row: [String: Any] = ["id": hit.id, "time": format(hit.at, calendar), "app": hit.appName, "bundle_id": hit.app,
                                          "window": hit.window, "snippet": hit.snippet]
                if let url = hit.url { row["url"] = url }
                return row
            }])
        case "screen_window":
            if let id = (args["id"] as? Int) ?? (args["id"] as? Double).map(Int.init) {
                return inside(Int64(id), args: args, text: text, store: store, calendar: calendar)
            }
            guard let since else { return .failure(Failure(message: "give an id, or since to list a time range")) }
            let end = until ?? now
            var result: [String: Any] = ["changes": []]
            let windows = changeList(store.changes(app: text("app"), window: text("window"), since: since, until: end), calendar)
            result["changes"] = windows
            return .success(result)
        default:
            return .failure(Failure(message: "unknown tool \(name)"))
        }
    }

    /// A capture's window: its outline, a subtree of it, or the elements with a role. A capture of text only returns its text.
    private static func inside(_ id: Int64, args: [String: Any], text: (String) -> String?, store: CaptureStore, calendar: Calendar) -> Result<Any, Failure> {
        guard let capture = store.capture(id: id) else { return .failure(Failure(message: "no capture \(id). It may have been deleted by the retention setting.")) }
        guard capture.root != nil else { return .success(["capture": row(capture, calendar)]) }
        guard let stored = store.tree(ofCapture: id) else { return .failure(Failure(message: "the tree of capture \(id) is no longer stored.")) }
        var out = row(capture, calendar)
        out.removeValue(forKey: "text")
        let tree = CaptureView.cleaned(stored)
        func lines(_ result: (lines: [String], omitted: Int)) -> String {
            result.lines.joined(separator: "\n") + (result.omitted > 0 ? "\n… \(result.omitted) more" : "")
        }
        let depth = (args["depth"] as? Int).map { max(1, min($0, 20)) }
        if let role = text("role") {
            out["role"] = role
            out["elements"] = lines(CaptureView.search(tree, role: role, text: text("text")))
        } else if let ref = text("root") {
            guard let node = CaptureView.find(tree, ref: ref) else { return .failure(Failure(message: "no element \(ref) in capture \(id). Refs come from the outline or the change list of that capture.")) }
            out["root"] = ref
            out["outline"] = lines(CaptureView.outline(node, depth: depth ?? 8, maxChildren: 40))
        } else {
            out["outline"] = lines(CaptureView.outline(tree, depth: depth ?? 4))
        }
        return .success(["capture": out])
    }

    /// The change list as the tool returns it: per window, newest changes kept, one string per change.
    static func changeList(_ changes: [CaptureStore.Change], _ calendar: Calendar) -> [[String: Any]] {
        var order: [Int64] = [], byWindow: [Int64: [CaptureStore.Change]] = [:]
        for change in changes {
            if byWindow[change.windowId] == nil { order.append(change.windowId) }
            byWindow[change.windowId, default: []].append(change)
        }
        return order.map { windowId in
            let all = byWindow[windowId] ?? []
            // Newest first, and among changes seen at the same moment (a first capture) the ones with a date first: a message or a mail
            // has one, a navigation entry rarely does.
            let ranked = all.enumerated().sorted { a, b in
                if a.element.seen != b.element.seen { return a.element.seen > b.element.seen }
                if (a.element.when != nil) != (b.element.when != nil) { return a.element.when != nil }
                return a.offset > b.offset
            }.prefix(maxChangesPerWindow).map(\.offset).sorted()
            let shown = ranked.map { all[$0] }
            var window: [String: Any] = ["app": all[0].appName, "window": all[0].window]
            // One list around all of them is said once.
            let containers = Set(shown.compactMap(\.container))
            let shared = containers.count == 1 && shown.allSatisfy { $0.container != nil } ? containers.first : nil
            if let shared { window["in"] = shared }
            window["changes"] = shown.map { line($0, calendar, hideContainer: shared != nil) }
            if let url = all[0].url { window["url"] = url }
            if all.count > ranked.count { window["more"] = all.count - ranked.count }
            return window
        }
    }

    private static func line(_ change: CaptureStore.Change, _ calendar: Calendar, hideContainer: Bool) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mmxxx"
        var parts = [formatter.string(from: change.seen) + " " + change.kind.rawValue]
        if let container = change.container, !hideContainer { parts[0] += " in " + container }
        parts.append(change.label)
        if let when = change.when, !change.label.contains(when) { parts.append(when) }
        var ids: [String] = []
        if let capture = change.capture { ids.append("c\(capture)") }
        if let ref = change.ref { ids.append("#" + ref) }
        if !ids.isEmpty { parts.append(ids.joined(separator: " ")) }
        return parts.joined(separator: " | ")
    }
}
