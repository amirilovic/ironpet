import Foundation

/// What a desktop tool returns: JSON, or an image with a line of text.
enum DesktopOutput {
    case value(Any)
    case image(Data, caption: String)
}

/// The desktop tools: read any Mac app through Accessibility and operate it with AX actions. Reads use the capture code's live tree
/// reader, so they share its node and time budgets and its rule that a secure field is read for its role only. Actions go through
/// the same privacy checks as capture and through the approval gate in `DesktopSafety`. The only synthetic input is `desktop_key`,
/// which posts key events to one app's process and never to the system-wide stream. No mouse events are sent.
final class DesktopService: @unchecked Sendable {
    typealias Failure = ScreenMCP.Failure

    struct Dependencies {
        var ax: DesktopAX = LiveDesktopAX()
        var opener: DesktopOpener = LiveDesktopOpener()
        var privacy: CapturePrivacy
        var enabled: () -> Bool = { false }
        /// Asks the user to approve an action. Nothing runs unless this returns true.
        var approve: (DesktopApproval) async -> Bool = { _ in false }
        var record: (DesktopActionRecord) -> Void = { _ in }
        var now: () -> Date = { Date() }
        /// Redaction of every text that leaves ironpet, the same as for capture.
        var clean: (String) -> String = { CaptureRedactor.redact($0).text }
        /// Seconds. An agent asked for this read, so it may take longer than the background capture, which uses 0.2.
        var budget = CaptureReadBudget(maxNodes: 6_000, maxTime: 1.0)
        var ownBundleId = AXCaptureSource.ownBundleId
    }

    /// An element of the last read of a window.
    private struct Entry {
        var element: DesktopElement
        var window: DesktopWindowInfo
        var app: CaptureApp
        var windowTitle: String
        var role: String
        var name: String
        /// The element's own cleaned fields, hashed. A changed element has another key, so its ref is stale.
        var key: String
        var isInput: Bool
        var shown: [String]
    }

    private struct Snapshot {
        var app: CaptureApp
        var window: DesktopWindowInfo
        var windows: [DesktopWindowInfo]
        var tree: AXNode
        var elements: Int
    }

    private let deps: Dependencies
    private let queue = DispatchQueue(label: "ironpet.desktop", qos: .userInitiated)
    private var entries: [String: Entry] = [:]
    private static let maxEntries = 20_000

    init(_ dependencies: Dependencies) { deps = dependencies }

    // MARK: Entry point

    func call(_ name: String, _ args: [String: Any]) async -> Result<DesktopOutput, Failure> {
        func text(_ key: String) -> String? { (args[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        guard deps.enabled() else {
            return .failure(Failure(message: "Desktop control is off. The user turns it on in ironpet Settings under Screen."))
        }
        switch name {
        case "desktop_snapshot":
            return await onQueue { self.snapshot(app: text("app"), window: text("window"), root: text("root"), role: text("role"), text: text("text"),
                                                 depth: (args["depth"] as? Int).map { max(1, min($0, 20)) }) }
        case "desktop_find":
            return await onQueue { self.find(app: text("app"), window: text("window"), role: text("role"), name: text("name"), value: text("value")) }
        case "desktop_screenshot":
            return await onQueue { self.screenshot(app: text("app"), window: text("window")) }
        case "desktop_key":
            guard let app = text("app") else { return .failure(Failure(message: "app is required")) }
            guard let key = text("key") else { return .failure(Failure(message: "key is required, such as \"return\" or \"cmd+l\".")) }
            return await pressKey(app: app, window: text("window"), key: key)
        case "desktop_open_url":
            return await onQueue { self.openURL(text("url"), browser: text("browser")) }
        case "desktop_press", "desktop_focus", "desktop_set_value", "desktop_type", "desktop_select", "desktop_check", "desktop_expand":
            guard let ref = text("ref") else { return .failure(Failure(message: "ref is required. Take it from desktop_snapshot or desktop_find.")) }
            let action: Action
            switch name {
            case "desktop_press": action = .press
            case "desktop_focus": action = .focus
            case "desktop_set_value": action = .setValue(args["text"] as? String ?? "")
            case "desktop_select": action = .select(text("text"))
            case "desktop_check":
                guard let checked = args["checked"] as? Bool else { return .failure(Failure(message: "checked is required: true or false")) }
                action = .check(checked)
            case "desktop_expand":
                guard let expand = args["expand"] as? Bool else { return .failure(Failure(message: "expand is required: true or false")) }
                action = .expand(expand)
            default: action = .type(args["text"] as? String ?? "")
            }
            if case .setValue = action, args["text"] as? String == nil { return .failure(Failure(message: "text is required")) }
            if case .type = action, args["text"] as? String == nil { return .failure(Failure(message: "text is required")) }
            return await act(action, ref: ref)
        default:
            return .failure(Failure(message: "unknown tool \(name)"))
        }
    }

    private func onQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: work()) } }
    }

    // MARK: Reading

    private func ready() -> Failure? {
        guard deps.ax.isTrusted else {
            return Failure(message: "ironpet has no Accessibility access. The user allows it in System Settings > Privacy & Security > Accessibility.")
        }
        return nil
    }

    private func checkApp(_ app: CaptureApp) -> Failure? {
        if app.bundleId == deps.ownBundleId { return Failure(message: "ironpet does not operate its own windows.") }
        if let skip = deps.privacy.checkApp(app, now: deps.now()) {
            return Failure(message: "ironpet does not read or act on \(app.name): \(skip).")
        }
        return nil
    }

    /// Reads one window and registers its elements. `window` is a part of its title; without it the focused window is read.
    private func capture(app query: String, window wanted: String?) -> Result<Snapshot, Failure> {
        if let failure = ready() { return .failure(failure) }
        guard let app = deps.ax.runningApp(matching: query) else {
            return .failure(Failure(message: "no running app matches \(query). Use its name or bundle id."))
        }
        if let failure = checkApp(app) { return .failure(failure) }
        let windows = deps.ax.windows(of: app)
        let chosen: DesktopWindowInfo?
        if let wanted {
            chosen = windows.first { $0.title?.range(of: wanted, options: .caseInsensitive) != nil }
        } else {
            chosen = windows.first { $0.focused } ?? windows.first
        }
        guard let chosen else {
            let titles = windows.compactMap(\.title).map { "\"\($0)\"" }.joined(separator: ", ")
            return .failure(Failure(message: wanted.map { "\(app.name) has no window with \"\($0)\" in its title." + (titles.isEmpty ? "" : " Windows: \(titles).") }
                ?? "\(app.name) has no window."))
        }
        return read(app: app, window: chosen, windows: windows)
    }

    private func read(app: CaptureApp, window: DesktopWindowInfo, windows: [DesktopWindowInfo]) -> Result<Snapshot, Failure> {
        if deps.privacy.isPrivateWindow(app: app, title: window.title) {
            return .failure(Failure(message: "ironpet does not read or act on a private browser window."))
        }
        guard let live = deps.ax.read(app: app, window: window, budget: deps.budget) else {
            return .failure(Failure(message: "could not read \(app.name)'s window. It may have closed, or it answers too slowly."))
        }
        let prepared = CaptureTree.prepare(live.root, clean: deps.clean, cleanURL: CaptureURL.redact)
        // The same address and host rules as capture, so a denied page is never read or operated.
        let url = CaptureText.pageURL(in: prepared.tree)
        let probe = WindowRead(app: app, title: window.title, url: url, root: prepared.tree, windowID: window.windowID)
        if let skip = deps.privacy.check(probe, now: deps.now()) {
            return .failure(Failure(message: "ironpet does not read or act on this window: \(skip)."))
        }
        let title = deps.clean(window.title ?? "")
        // The windows of this app that were read before are replaced, so the table holds one read of each.
        entries = entries.filter { $0.value.app.pid != app.pid || $0.value.windowTitle != title }
        if entries.count > Self.maxEntries { entries.removeAll() }
        var counts: [String: Int] = [:]
        func walk(_ raw: AXNode, _ node: AXNode, index: Int) -> AXNode {
            var out = node
            let hash = node.ref
            let seen = counts[hash, default: 0]
            counts[hash] = seen + 1
            out.ref = seen == 0 ? hash : "\(hash)~\(seen + 1)"
            if index < live.elements.count {
                var shown = [node.title, node.description].compactMap { $0 }
                if !CaptureTree.isInput(node) { shown += [node.value].compactMap { $0 } }
                entries[out.ref] = Entry(element: live.elements[index], window: window, app: app, windowTitle: title, role: node.role,
                                         name: node.name ?? "", key: Self.key(node), isInput: CaptureTree.isInput(node), shown: shown)
            }
            var next = index + 1
            var kept = 0
            var children: [AXNode] = []
            for child in raw.children {
                if !child.hidden, kept < node.children.count {
                    children.append(walk(child, node.children[kept], index: next))
                    kept += 1
                }
                next += Self.size(child)
            }
            out.children = children
            return out
        }
        let tree = walk(live.root, prepared.tree, index: 0)
        return .success(Snapshot(app: app, window: window, windows: windows, tree: tree, elements: prepared.elements))
    }

    private static func size(_ node: AXNode) -> Int { 1 + node.children.reduce(0) { $0 + size($1) } }

    /// The hash of an element's own cleaned fields. A value typed into an input does not count, so typing does not stale the ref.
    private static func key(_ node: AXNode) -> String {
        let fields = [node.role, node.subrole ?? "", node.title ?? "", CaptureTree.isInput(node) ? "" : (node.value ?? ""), node.description ?? ""]
        return CaptureTree.hash(fields.joined(separator: "\u{1}"))
    }

    private func snapshot(app: String?, window: String?, root: String?, role: String?, text: String?, depth: Int?) -> Result<DesktopOutput, Failure> {
        let result: Result<Snapshot, Failure>
        if let root, app == nil {
            guard let entry = lookup(root) else { return .failure(staleRef(root)) }
            if let failure = ready() ?? checkApp(entry.app) { return .failure(failure) }
            result = read(app: entry.app, window: entry.window, windows: deps.ax.windows(of: entry.app))
        } else if let app {
            result = capture(app: app, window: window)
        } else {
            return .failure(Failure(message: "give app, or root (a ref from an earlier snapshot)"))
        }
        let shot: Snapshot
        switch result {
        case .failure(let failure): return .failure(failure)
        case .success(let value): shot = value
        }
        var out: [String: Any] = ["app": shot.app.name, "bundle_id": shot.app.bundleId, "window": shot.window.title ?? "", "elements": shot.elements,
                                  "windows": shot.windows.map { ["title": $0.title ?? "", "focused": $0.focused] as [String: Any] }]
        func lines(_ result: (lines: [String], omitted: Int)) -> String {
            result.lines.joined(separator: "\n") + (result.omitted > 0 ? "\n… \(result.omitted) more" : "")
        }
        if let role {
            out["role"] = role
            out["elements_found"] = lines(CaptureView.search(shot.tree, role: role, text: text))
        } else if let root {
            guard let node = CaptureView.find(shot.tree, ref: root) else { return .failure(staleRef(root)) }
            out["root"] = root
            out["outline"] = lines(CaptureView.outline(node, depth: depth ?? 8, maxChildren: 40, allRefs: true))
        } else {
            out["outline"] = lines(CaptureView.outline(shot.tree, depth: depth ?? 4, allRefs: true))
        }
        return .success(.value(out))
    }

    private func find(app: String?, window: String?, role: String?, name: String?, value: String?) -> Result<DesktopOutput, Failure> {
        guard let app else { return .failure(Failure(message: "app is required")) }
        guard role != nil || name != nil || value != nil else { return .failure(Failure(message: "give at least one of role, name, value")) }
        switch capture(app: app, window: window) {
        case .failure(let failure): return .failure(failure)
        case .success(let shot):
            let found = DesktopView.find(shot.tree, role: role, name: name, value: value)
            var out: [String: Any] = ["app": shot.app.name, "window": shot.window.title ?? "", "count": found.lines.count + found.omitted,
                                      "elements": found.lines.joined(separator: "\n")]
            if found.omitted > 0 { out["more"] = found.omitted }
            return .success(.value(out))
        }
    }

    private func screenshot(app: String?, window: String?) -> Result<DesktopOutput, Failure> {
        guard let app else { return .failure(Failure(message: "app is required")) }
        // A read comes first, so the address and window rules apply to a picture as they do to text.
        switch capture(app: app, window: window) {
        case .failure(let failure): return .failure(failure)
        case .success(let shot):
            guard deps.ax.screenRecordingGranted else {
                return .failure(Failure(message: "ironpet has no Screen Recording access. The user allows it in System Settings > Privacy & Security > Screen Recording."))
            }
            guard shot.window.windowID != nil, let png = deps.ax.screenshot(of: shot.window, app: shot.app) else {
                return .failure(Failure(message: "could not take a picture of that window. It may be off screen or minimized."))
            }
            return .success(.image(png, caption: "\(shot.app.name): \(shot.window.title ?? "window")"))
        }
    }

    // MARK: Actions

    enum Action {
        case press, focus
        case setValue(String)
        case type(String)
        /// Pick the option with this text inside the element, or select the element itself when there is no text.
        case select(String?)
        case check(Bool)
        case expand(Bool)

        var label: String {
            switch self {
            case .press: return "press"
            case .focus: return "focus"
            case .setValue: return "set_value"
            case .type: return "type"
            case .select: return "select"
            case .check: return "check"
            case .expand: return "expand"
            }
        }

        /// Text the agent supplied that decides what the action touches, so it counts for approval like the element's own text.
        var approvalTexts: [String] {
            if case .select(let text?) = self { return [text] }
            return []
        }
    }

    private func lookup(_ ref: String) -> Entry? {
        let wanted = ref.hasPrefix("#") ? String(ref.dropFirst()) : ref
        if let exact = entries[wanted] { return exact }
        guard wanted.count >= 6 else { return nil }
        let matches = entries.filter { $0.key.hasPrefix(wanted) }
        return matches.count == 1 ? matches.first?.value : nil
    }

    private func staleRef(_ ref: String) -> Failure {
        Failure(message: "ref \(ref) is not known or its element changed. Take a new desktop_snapshot or desktop_find and use the refs from it.")
    }

    private enum Check {
        case go(Entry, reason: String?)
        case stop(Failure)
    }

    /// Everything that must hold before an action runs, checked again after the user approves: the app and window may be used, the
    /// element is still there and unchanged, and it is not a secure field.
    private func check(_ ref: String) -> Check {
        if let failure = ready() { return .stop(failure) }
        guard let entry = lookup(ref) else { return .stop(staleRef(ref)) }
        if let failure = checkApp(entry.app) { return .stop(failure) }
        if deps.privacy.isPrivateWindow(app: entry.app, title: entry.windowTitle) {
            return .stop(Failure(message: "ironpet does not read or act on a private browser window."))
        }
        guard let live = deps.ax.attributes(of: entry.element) else { return .stop(staleRef(ref)) }
        if live.isSecure || entry.role == "SecureTextField" { return .stop(Failure(message: "ironpet never acts on a password field.")) }
        let cleaned = CaptureTree.prepare(live, clean: deps.clean).tree
        guard Self.key(cleaned) == entry.key else { return .stop(staleRef(ref)) }
        return .go(entry, reason: DesktopSafety.approvalReason(element: entry.shown, window: entry.windowTitle))
    }

    private func act(_ action: Action, ref: String) async -> Result<DesktopOutput, Failure> {
        // A refused attempt on a known element is logged too, so the list shows every try, not only the ones that ran.
        let first = await onQueue { () -> Check in
            let result = self.check(ref)
            if case .stop(let failure) = result, let known = self.lookup(ref) { self.log(known, action, .refused, note: failure.message) }
            return result
        }
        let entry: Entry
        var asked = false
        switch first {
        case .stop(let failure): return .failure(failure)
        case .go(let found, let elementReason):
            entry = found
            if let reason = elementReason ?? DesktopSafety.approvalReason(element: action.approvalTexts, window: nil) {
                asked = true
                let approval = DesktopApproval(title: "\(action.label) \(entry.role.lowercased()) \"\(clip(entry.name))\" in \(entry.app.name)",
                                               detail: "\(entry.windowTitle.isEmpty ? "" : "Window: \(clip(entry.windowTitle)). ")Approval needed because \(reason).")
                guard await deps.approve(approval) else {
                    log(entry, action, .declined, note: reason)
                    return .failure(Failure(message: "the user declined this action."))
                }
            }
        }
        return await onQueue { [asked] in self.run(action, ref: ref, expected: entry, asked: asked) }
    }

    /// `asked` is whether the user approved this action, which lets a select pick an option whose own label says send, pay or delete.
    private func run(_ action: Action, ref: String, expected: Entry, asked: Bool) -> Result<DesktopOutput, Failure> {
        // Time passed while the user decided, so the element is checked again, and it must be the one that was approved.
        let entry: Entry
        switch check(ref) {
        case .stop(let failure):
            log(expected, action, .refused, note: failure.message)
            return .failure(failure)
        case .go(let found, _):
            guard found.key == expected.key else {
                log(expected, action, .refused, note: "the element changed")
                return .failure(staleRef(ref))
            }
            entry = found
        }
        func fail(_ message: String) -> Result<DesktopOutput, Failure> {
            log(entry, action, .failed, note: message)
            return .failure(Failure(message: message))
        }
        let ax = deps.ax
        var done: String
        switch action {
        case .press:
            let available = ax.actions(of: entry.element)
            guard let name = ["AXPress", "AXConfirm", "AXPick", "AXOpen"].first(where: available.contains) else {
                return fail("this element has no press action (it has \(available.isEmpty ? "none" : available.joined(separator: ", "))). Try desktop_focus or desktop_set_value.")
            }
            guard ax.perform(name, on: entry.element) else { return fail("the app refused \(name).") }
            done = name
        case .focus:
            guard ax.focus(entry.element) else { return fail("the element could not be focused.") }
            done = "focus"
        case .setValue(let text):
            guard ax.isSettable("AXValue", on: entry.element) else {
                return fail("this element's value cannot be set. Try desktop_type for a text field, or desktop_press for a control.")
            }
            guard ax.set("AXValue", to: text, on: entry.element) else { return fail("the app refused the new value.") }
            done = "set AXValue"
        case .type(let text):
            _ = ax.focus(entry.element)
            if ax.isSettable("AXSelectedText", on: entry.element), ax.set("AXSelectedText", to: text, on: entry.element) {
                done = "insert AXSelectedText"
            } else if ax.isSettable("AXValue", on: entry.element), let live = ax.attributes(of: entry.element),
                      ax.set("AXValue", to: (live.value ?? "") + text, on: entry.element) {
                done = "append AXValue"
            } else {
                return fail("this element does not take text through Accessibility.")
            }
        case .select(let wanted):
            switch select(entry, wanted: wanted, asked: asked) {
            case .success(let note): done = note
            case .failure(let message): return fail(message.text)
            }
        case .check(let wanted):
            switch setChecked(entry, wanted) {
            case .success(let note): done = note
            case .failure(let message): return fail(message.text)
            }
        case .expand(let wanted):
            switch setExpanded(entry, wanted) {
            case .success(let note): done = note
            case .failure(let message): return fail(message.text)
            }
        }
        log(entry, action, .done, note: done)
        return .success(.value(["ok": true, "action": done, "element": "\(entry.role.lowercased())" + (entry.name.isEmpty ? "" : " \"\(clip(entry.name))\""),
                                "app": entry.app.name]))
    }

    private func log(_ entry: Entry, _ action: Action, _ outcome: DesktopActionRecord.Outcome, note: String) {
        deps.record(DesktopActionRecord(at: deps.now(), app: entry.app.name, window: entry.windowTitle, role: entry.role, name: entry.name,
                                        action: action.label, outcome: outcome, note: note))
    }

    private func clip(_ text: String) -> String { text.count > 60 ? String(text.prefix(59)) + "…" : text }
}

// MARK: Select, check and expand

/// A reason an element action could not be done, in words an agent can act on.
private struct Problem: Error {
    var text: String
    init(_ text: String) { self.text = text }
}

private extension DesktopService {
    static let popupRoles: Set<String> = ["PopUpButton", "MenuButton", "ComboBox", "MenuBarItem"]
    /// Roles whose own text, or the text under them, names an option.
    static let optionRoles: Set<String> = ["MenuItem", "Row", "RadioButton", "Tab", "Cell", "MenuBarItem"]

    /// "1", "true", "on" and the like. A mixed checkbox ("2") counts as not checked, because pressing it checks it.
    static func truth(_ text: String?) -> Bool? {
        switch text?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "2", "false", "no", "off": return false
        default: return nil
        }
    }

    struct Option {
        var element: DesktopElement
        var role: String
        /// Every text the option shows: its own title, and for a row the texts of its cells.
        var labels: [String]
    }

    /// The options under `root`, found live: menu items, rows, radio buttons and tabs, up to a depth and a count.
    func options(under root: DesktopElement, depth: Int = 6, limit: Int = 500) -> [Option] {
        var found: [Option] = []
        var visited = 0
        // The texts under an option. A nested row is another option, so its texts are not this one's.
        func texts(_ element: DesktopElement, depth: Int, root: Bool = true) -> [String] {
            guard let node = deps.ax.attributes(of: element), !node.isSecure, root || node.role != "Row" else { return [] }
            var out = [node.title, node.description, node.value].compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if depth > 0 {
                for child in deps.ax.children(of: element) { out += texts(child, depth: depth - 1, root: false) }
            }
            return out
        }
        func walk(_ element: DesktopElement, depth: Int) {
            guard depth >= 0, visited < limit else { return }
            visited += 1
            for child in deps.ax.children(of: element) {
                guard visited < limit, let node = deps.ax.attributes(of: child) else { continue }
                if Self.optionRoles.contains(node.role) {
                    let labels = node.role == "MenuItem" ? [node.title, node.description].compactMap { $0 } : texts(child, depth: 3)
                    if !labels.isEmpty { found.append(Option(element: child, role: node.role, labels: labels.map { deps.clean($0) })) }
                }
                walk(child, depth: depth - 1)
            }
        }
        walk(root, depth: depth)
        return found
    }

    /// Opens a popup so its options exist. Returns whether it did.
    func openPopup(_ element: DesktopElement) -> Bool {
        let available = deps.ax.actions(of: element)
        guard let name = ["AXPress", "AXShowMenu"].first(where: available.contains) else { return false }
        return deps.ax.perform(name, on: element)
    }

    private func select(_ entry: Entry, wanted: String?, asked: Bool) -> Result<String, Problem> {
        let ax = deps.ax
        guard let wanted else {
            return choose(Option(element: entry.element, role: entry.role, labels: [entry.name].filter { !$0.isEmpty }))
        }
        let opened = Self.popupRoles.contains(entry.role) && openPopup(entry.element)
        func close() { if opened, ax.actions(of: entry.element).contains("AXCancel") { _ = ax.perform("AXCancel", on: entry.element) } }
        // A menu appears a moment after the press.
        var all = options(under: entry.element)
        for _ in 0..<5 where all.isEmpty && opened {
            Thread.sleep(forTimeInterval: 0.05)
            all = options(under: entry.element)
        }
        let needle = wanted.trimmingCharacters(in: .whitespaces).lowercased()
        var hits = all.filter { $0.labels.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == needle } }
        if hits.isEmpty { hits = all.filter { $0.labels.contains { $0.lowercased().contains(needle) } } }
        guard hits.count == 1, let hit = hits.first else {
            close()
            if hits.isEmpty {
                let names = all.prefix(12).compactMap { $0.labels.first }.map { "\"\($0)\"" }.joined(separator: ", ")
                return .failure(Problem("no option matches \"\(wanted)\"." + (names.isEmpty ? " The element lists no options. Open it first with desktop_expand." : " Options: \(names).")))
            }
            return .failure(Problem("\(hits.count) options match \"\(wanted)\". Give more of the text."))
        }
        // The user approved what the agent asked for. An option whose label says more than that still needs an answer.
        if !asked, let verb = hit.labels.lazy.compactMap({ DesktopSafety.riskyVerb(in: $0) }).first {
            close()
            return .failure(Problem("the option \"\(hit.labels[0])\" says \"\(verb)\". Ask again with its full text so the user can approve it."))
        }
        let result = choose(hit)
        if case .failure = result { close() }
        return result
    }

    /// Selects one option or row: AXSelected when it can be set, else its press action.
    func choose(_ option: Option) -> Result<String, Problem> {
        let ax = deps.ax
        let label = option.labels.first ?? option.role.lowercased()
        let isItem = option.role == "MenuItem" || option.role == "RadioButton" || option.role == "Tab"
        if !isItem {
            if ax.boolean("AXSelected", of: option.element) == true { return .success("already selected") }
            if ax.isSettable("AXSelected", on: option.element), ax.setBoolean("AXSelected", to: true, on: option.element) { return .success("select \"\(label)\"") }
        }
        let available = ax.actions(of: option.element)
        if let name = ["AXPress", "AXPick", "AXOpen"].first(where: available.contains), ax.perform(name, on: option.element) { return .success("\(name) \"\(label)\"") }
        return .failure(Problem("\"\(label)\" cannot be selected through Accessibility."))
    }

    func checkState(_ element: DesktopElement) -> Bool? {
        Self.truth(deps.ax.attributes(of: element)?.value)
    }

    private func setChecked(_ entry: Entry, _ wanted: Bool) -> Result<String, Problem> {
        let ax = deps.ax
        guard let current = checkState(entry.element) else {
            return .failure(Problem("this element has no checked state. desktop_check works on checkboxes, switches and radio buttons."))
        }
        if current == wanted { return .success(wanted ? "already checked" : "already unchecked") }
        if entry.role == "RadioButton" && !wanted { return .failure(Problem("a radio button cannot be unchecked. Check another one in its group.")) }
        guard ax.actions(of: entry.element).contains("AXPress") else { return .failure(Problem("this element has no press action to change it.")) }
        guard ax.perform("AXPress", on: entry.element) else { return .failure(Problem("the app refused AXPress.")) }
        Thread.sleep(forTimeInterval: 0.05)
        if let after = checkState(entry.element), after != wanted {
            return .failure(Problem("the app accepted the press but the element is still \(after ? "checked" : "unchecked")."))
        }
        return .success(wanted ? "check (AXPress)" : "uncheck (AXPress)")
    }

    private func setExpanded(_ entry: Entry, _ wanted: Bool) -> Result<String, Problem> {
        let ax = deps.ax
        let word = wanted ? "expanded" : "collapsed"
        var attribute: String?
        var current: Bool?
        for name in ["AXDisclosing", "AXExpanded"] {
            if let value = ax.boolean(name, of: entry.element) { attribute = name; current = value; break }
        }
        if current == nil && entry.role == "DisclosureTriangle" { current = checkState(entry.element) }
        if current == wanted { return .success("already \(word)") }
        func verified(_ note: String) -> Result<String, Problem> {
            if let attribute, let after = ax.boolean(attribute, of: entry.element), after != wanted {
                return .failure(Problem("the app accepted it but the element is still \(after ? "expanded" : "collapsed")."))
            }
            return .success(note)
        }
        if let attribute, ax.isSettable(attribute, on: entry.element), ax.setBoolean(attribute, to: wanted, on: entry.element) {
            return verified("set \(attribute)")
        }
        let available = ax.actions(of: entry.element)
        if entry.role == "DisclosureTriangle" || (attribute != nil && !Self.popupRoles.contains(entry.role)) {
            guard available.contains("AXPress"), ax.perform("AXPress", on: entry.element) else {
                return .failure(Problem("this element could not be made \(word)."))
            }
            return verified("AXPress")
        }
        if Self.popupRoles.contains(entry.role) {
            if wanted {
                guard let name = ["AXPress", "AXShowMenu"].first(where: available.contains), ax.perform(name, on: entry.element) else {
                    return .failure(Problem("this element could not be opened."))
                }
                return .success(name)
            }
            guard available.contains("AXCancel"), ax.perform("AXCancel", on: entry.element) else { return .failure(Problem("this element could not be closed.")) }
            return .success("AXCancel")
        }
        return .failure(Problem("this element cannot be expanded or collapsed. It needs to be a disclosure triangle, an outline row or a popup."))
    }
}

// MARK: Keys

private extension DesktopService {
    struct KeyPlan {
        var app: CaptureApp
        var window: DesktopWindowInfo
        var windowTitle: String
        var stroke: DesktopKeyStroke
        var focus: Focus
        var reason: String?
    }

    /// The element that has the keyboard focus, as far as approval and the log need it.
    struct Focus: Equatable {
        var role = ""
        var name = ""
        var shown: [String] = []
        var secure = false
    }

    func focus(of app: CaptureApp) -> Focus {
        guard let element = deps.ax.focusedElement(of: app), let live = deps.ax.attributes(of: element) else { return Focus() }
        if live.isSecure { return Focus(role: live.role, secure: true) }
        let node = CaptureTree.prepare(live, clean: deps.clean).tree
        var shown = [node.title, node.description].compactMap { $0 }
        if !CaptureTree.isInput(node) { shown += [node.value].compactMap { $0 } }
        return Focus(role: node.role, name: node.name ?? "", shown: shown)
    }

    func keyLog(_ app: CaptureApp, _ window: String, _ stroke: DesktopKeyStroke, _ focus: Focus, _ outcome: DesktopActionRecord.Outcome, note: String) {
        deps.record(DesktopActionRecord(at: deps.now(), app: app.name, window: window, role: focus.role, name: focus.name,
                                        action: "key \(stroke.label)", outcome: outcome, note: note))
    }

    /// Everything that must hold before a key is posted: the app and window may be used and the focus is not a password field.
    func prepareKey(_ query: String, window wanted: String?, _ stroke: DesktopKeyStroke) -> Result<KeyPlan, Failure> {
        if let failure = ready() { return .failure(failure) }
        guard let app = deps.ax.runningApp(matching: query) else {
            return .failure(Failure(message: "no running app matches \(query). Use its name or bundle id."))
        }
        func refuse(_ failure: Failure, window: String = "") -> Result<KeyPlan, Failure> {
            keyLog(app, window, stroke, Focus(), .refused, note: failure.message)
            return .failure(failure)
        }
        // The same read as every other tool, so the app list, private windows and denied addresses apply to keys too.
        let shot: Snapshot
        switch capture(app: query, window: wanted) {
        case .failure(let failure): return refuse(failure)
        case .success(let value): shot = value
        }
        let title = deps.clean(shot.window.title ?? "")
        // The key goes to the app's key window, so the window that was checked is raised unless it already is that window.
        if !deps.ax.isFrontmost(app) || !shot.window.focused {
            deps.ax.activate(app)
            _ = deps.ax.focus(shot.window.element)
        }
        let current = focus(of: app)
        if current.secure { return refuse(Failure(message: "ironpet never acts on a password field."), window: title) }
        let reason = DesktopSafety.keyApprovalReason(stroke, element: current.shown, window: title)
        return .success(KeyPlan(app: app, window: shot.window, windowTitle: title, stroke: stroke, focus: current, reason: reason))
    }

    func pressKey(app query: String, window: String?, key: String) async -> Result<DesktopOutput, Failure> {
        let stroke: DesktopKeyStroke
        switch DesktopKeys.parse(key) {
        case .failure(let error): return .failure(Failure(message: error.message))
        case .success(let value): stroke = value
        }
        let prepared = await onQueue { self.prepareKey(query, window: window, stroke) }
        let plan: KeyPlan
        switch prepared {
        case .failure(let failure): return .failure(failure)
        case .success(let value): plan = value
        }
        if let reason = plan.reason {
            let approval = DesktopApproval(title: "press \(stroke.label) in \(plan.app.name)",
                                           detail: "\(plan.windowTitle.isEmpty ? "" : "Window: \(clip(plan.windowTitle)). ")Approval needed because \(reason).")
            guard await deps.approve(approval) else {
                keyLog(plan.app, plan.windowTitle, stroke, plan.focus, .declined, note: reason)
                return .failure(Failure(message: "the user declined this action."))
            }
        }
        return await onQueue { self.sendKey(plan) }
    }

    func sendKey(_ plan: KeyPlan) -> Result<DesktopOutput, Failure> {
        func stop(_ message: String) -> Result<DesktopOutput, Failure> {
            keyLog(plan.app, plan.windowTitle, plan.stroke, plan.focus, .refused, note: message)
            return .failure(Failure(message: message))
        }
        // Time passed while the user decided, so the app, the window and the focus are checked again.
        if let failure = ready() ?? checkApp(plan.app) { return stop(failure.message) }
        if deps.privacy.isPrivateWindow(app: plan.app, title: plan.windowTitle) { return stop("ironpet does not read or act on a private browser window.") }
        // The key lands in the app's focused window. If that is another window than the one checked, it is checked too.
        if let keyWindow = deps.ax.windows(of: plan.app).first(where: \.focused),
           deps.privacy.isPrivateWindow(app: plan.app, title: keyWindow.title) {
            return stop("ironpet does not read or act on a private browser window.")
        }
        let now = focus(of: plan.app)
        if now.secure { return stop("ironpet never acts on a password field.") }
        if plan.reason == nil, DesktopSafety.keyApprovalReason(plan.stroke, element: now.shown, window: plan.windowTitle) != nil {
            return stop("the focus changed while the key was prepared. Try again.")
        }
        guard deps.ax.post(plan.stroke, to: plan.app) else {
            keyLog(plan.app, plan.windowTitle, plan.stroke, plan.focus, .failed, note: "the key could not be posted")
            return .failure(Failure(message: "the key could not be posted to \(plan.app.name)."))
        }
        keyLog(plan.app, plan.windowTitle, plan.stroke, plan.focus, .done, note: "posted to \(plan.app.name)")
        return .success(.value(["ok": true, "action": "key \(plan.stroke.label)", "app": plan.app.name]))
    }
}

// MARK: Open a URL

private extension DesktopService {
    static let maxURLLength = 8_192

    /// An http(s) address with a host and no user name or password. The host goes through the same deny list as capture.
    static func validate(_ raw: String) -> Result<URL, Failure> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= maxURLLength, !text.contains(where: { $0.isWhitespace || $0.isNewline }),
              let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(), let url = components.url else {
            return .failure(Failure(message: "that is not a web address. Give a full address such as https://example.com/path."))
        }
        guard scheme == "http" || scheme == "https" else {
            return .failure(Failure(message: "ironpet opens only http and https addresses, not \(scheme):."))
        }
        guard components.user == nil, components.password == nil else {
            return .failure(Failure(message: "ironpet does not open addresses that carry a user name or password."))
        }
        if let skip = CaptureFloor.checkURL(bundleId: "", raw: text) { return .failure(Failure(message: "ironpet does not open this address: \(skip).")) }
        return .success(url)
    }

    func openURL(_ raw: String?, browser query: String?) -> Result<DesktopOutput, Failure> {
        guard let raw else { return .failure(Failure(message: "url is required")) }
        let url: URL
        switch Self.validate(raw) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): url = value
        }
        let shownURL = deps.clean(CaptureURL.redact(url.absoluteString))
        var target: (bundleId: String, name: String)?
        if let query {
            guard let found = deps.opener.browser(matching: query) else {
                return .failure(Failure(message: "no browser matches \(query). Use the name or bundle id of an installed browser."))
            }
            target = found
        } else if let front = deps.opener.frontmostBrowser() {
            target = deps.opener.browser(matching: front) ?? (front, front)
        }
        let name = target?.name ?? "default browser"
        func log(_ outcome: DesktopActionRecord.Outcome, _ note: String) {
            deps.record(DesktopActionRecord(at: deps.now(), app: name, window: "", role: "Link", name: shownURL, action: "open_url", outcome: outcome, note: note))
        }
        // Pause, the screen lock and the app deny list apply to opening a page as to reading one.
        let probe = CaptureApp(bundleId: target?.bundleId ?? "", name: name, pid: 0)
        if let skip = deps.privacy.checkApp(probe, now: deps.now()) {
            log(.refused, "\(skip)")
            return .failure(Failure(message: "ironpet does not open pages in \(name): \(skip)."))
        }
        guard deps.opener.open(url, inBrowser: target?.bundleId) else {
            log(.failed, "the browser did not open it")
            return .failure(Failure(message: "\(name) did not open the address."))
        }
        log(.done, "new tab")
        return .success(.value(["ok": true, "action": "open_url", "url": shownURL, "browser": name]))
    }
}

/// Searching a tree for the elements an agent asks about.
enum DesktopView {
    /// Elements whose role, name and value match, each with the nearest named list around it and the ref to act on it with.
    static func find(_ root: AXNode, role: String?, name: String?, value: String?, limit: Int = 50) -> (lines: [String], omitted: Int) {
        let wantedRole = role.map { ($0.hasPrefix("AX") ? String($0.dropFirst(2)) : $0).lowercased() }
        var lines: [String] = [], omitted = 0
        func contains(_ text: String?, _ needle: String) -> Bool { text?.range(of: needle, options: .caseInsensitive) != nil }
        func walk(_ node: AXNode, container: String?) {
            var inner = container
            if let label = node.name, ["List", "Table", "Outline", "Grid"].contains(node.role) { inner = label }
            let roleHit = wantedRole.map { node.role.lowercased() == $0 || node.subrole?.lowercased() == $0 } ?? true
            let nameHit = name.map { contains(node.title, $0) || contains(node.description, $0) } ?? true
            let valueHit = value.map { contains(node.value, $0) } ?? true
            if roleHit && nameHit && valueHit {
                if lines.count < limit {
                    var line = node.role.lowercased()
                    if let subrole = node.subrole { line += "." + subrole.lowercased() }
                    if let label = node.name { line += " \"" + clip(label) + "\"" }
                    if let text = node.value, !node.isSecure { line += " value=\"" + clip(text) + "\"" }
                    if let inner { line += " in " + clip(inner) }
                    lines.append(line + " #" + node.ref)
                } else { omitted += 1 }
            }
            node.children.forEach { walk($0, container: inner) }
        }
        walk(root, container: nil)
        return (lines, omitted)
    }

    private static func clip(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > CaptureView.maxTextCharacters ? String(line.prefix(CaptureView.maxTextCharacters - 1)) + "…" : line
    }
}
