import Foundation

/// Finds the form around an edited field and renders it as `Label: value` lines. Pure functions over the normalized tree, so tests
/// feed fake trees and no accessibility call is made here.
enum CaptureForm {
    enum Kind: Equatable {
        /// A sheet, a dialog, or a web form or dialog landmark.
        case dialog
        /// The nearest group that holds at least two inputs and stays inside `groupBudget` nodes.
        case group
        /// No usable container. The field and its label are all there is.
        case field
    }

    struct Container {
        var kind: Kind
        var node: CaptureNode
    }

    /// The largest subtree, in nodes, that counts as a form when it has no dialog or form role. Keeps a whole window or web area out.
    static let groupBudget = 150
    /// Nodes read when rendering one container.
    static let renderBudget = 600
    static let maxBodyCharacters = 4000
    static let maxLineCharacters = 300

    static let editable: Set<String> = ["TextField", "TextArea", "ComboBox", "SearchField"]
    static let inputs: Set<String> = editable.union(["PopUpButton", "DatePicker", "DateField", "TimeField", "CheckBox", "RadioButton", "Slider", "Stepper"])
    private static let containerRoles: Set<String> = ["Sheet", "Dialog", "Form"]

    // MARK: Container

    /// The node chain from `root` down to the focused editable field, or nil when none is focused. A secure field is never one.
    static func editedChain(in root: CaptureNode) -> [CaptureNode]? {
        func walk(_ node: CaptureNode, _ chain: [CaptureNode]) -> [CaptureNode]? {
            if node.isSecure || node.hidden { return nil }
            let here = chain + [node]
            if node.focused, editable.contains(node.role) { return here }
            for child in node.children { if let found = walk(child, here) { return found } }
            return nil
        }
        return walk(root, [])
    }

    private static func isFormLike(_ node: CaptureNode) -> Bool {
        if containerRoles.contains(node.role) { return true }
        let subrole = node.attrs["subrole"] ?? ""
        return subrole.contains("Dialog") || subrole.contains("Form")
    }

    private static func inputCount(_ node: CaptureNode) -> Int {
        (inputs.contains(node.role) && !node.isSecure ? 1 : 0) + node.children.reduce(0) { $0 + inputCount($1) }
    }

    /// The container of the field at the end of `chain`: the nearest sheet, dialog or form, else the nearest group with two or more
    /// inputs inside the size budget, else the field with its label.
    static func container(of chain: [CaptureNode]) -> Container {
        guard let field = chain.last else { return Container(kind: .field, node: CaptureNode(role: "Group")) }
        let ancestors = Array(chain.dropLast().enumerated().reversed())
        // A sheet, dialog or form wins over any group inside it, so a date and time row never stands in for the whole dialog.
        for (index, node) in ancestors {
            // The window itself is a container only when it is a dialog. A web area never is.
            if index == 0 || node.role == "WebArea" {
                if index == 0, node.role == "Window", isFormLike(node) { return Container(kind: .dialog, node: node) }
                break
            }
            if isFormLike(node) { return Container(kind: .dialog, node: node) }
        }
        for (index, node) in ancestors {
            if index == 0 || node.role == "WebArea" { break }
            if node.role == "Group" {
                if node.count > groupBudget { break }
                if inputCount(node) >= 2 { return Container(kind: .group, node: node) }
            }
        }
        // Only the field and the static text just before it.
        var kept: [CaptureNode] = []
        if chain.count >= 2, let at = chain[chain.count - 2].children.firstIndex(of: field) {
            let siblings = chain[chain.count - 2].children
            if let label = siblings[..<at].last(where: { $0.role == "StaticText" && !($0.value ?? "").isEmpty }) { kept.append(label) }
        }
        kept.append(field)
        return Container(kind: .field, node: CaptureNode(role: "Group", children: kept))
    }

    // MARK: Identity

    /// What makes a container the same one across reads: role, name, first heading and size, never a value.
    static func key(_ node: CaptureNode) -> String {
        let size = node.frame.map { "\(Int($0.width))x\(Int($0.height))" } ?? ""
        return [node.role, node.attrs["subrole"] ?? "", node.name ?? "", heading(of: node) ?? "", size].joined(separator: "|")
    }

    static func heading(of node: CaptureNode) -> String? {
        var found: String?
        func walk(_ n: CaptureNode) {
            guard found == nil, !n.hidden else { return }
            if n.role == "Heading" || n.role == "StaticText", let text = (n.value ?? n.name)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                found = text
                return
            }
            if !inputs.contains(n.role) { n.children.forEach(walk) }
        }
        walk(node)
        return found
    }

    /// The container with this key anywhere in `root`.
    static func find(key wanted: String, in root: CaptureNode) -> CaptureNode? {
        if key(root) == wanted { return root }
        for child in root.children { if let found = find(key: wanted, in: child) { return found } }
        return nil
    }

    // MARK: Body

    private enum Entry {
        case text(String)
        case field(CaptureNode)
    }

    private static func clean(_ text: String?) -> String {
        (text ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func collect(_ node: CaptureNode, into entries: inout [Entry], budget: inout Int) {
        guard budget > 0, !node.hidden, !node.isSecure else { return }
        budget -= 1
        if inputs.contains(node.role) {
            entries.append(.field(node))
            return
        }
        if node.role == "StaticText" || node.role == "Heading" {
            let text = clean(node.value ?? node.name)
            if !text.isEmpty { entries.append(.text(text)) }
            return
        }
        for child in node.children { collect(child, into: &entries, budget: &budget) }
    }

    private static func fieldValue(_ node: CaptureNode) -> String {
        let raw = clean(node.value)
        if node.role == "CheckBox" || node.role == "RadioButton" { return raw == "1" ? "on" : raw == "0" ? "off" : raw }
        return raw.isEmpty ? clean(node.name) : raw
    }

    /// One `Label: value` line per field and one line per static text that is not a label. A field with no usable label gives its
    /// visible text alone.
    static func body(of container: CaptureNode) -> String {
        var entries: [Entry] = []
        var budget = renderBudget
        collect(container, into: &entries, budget: &budget)
        var consumed = Set<Int>()
        var labels: [Int: String] = [:]
        for (index, entry) in entries.enumerated() {
            guard case .field(let node) = entry else { continue }
            let own = [node.name, node.attrs["label"], node.attrs["title_ui"], node.attrs["placeholder"]].map(clean).first { !$0.isEmpty }
            if let own {
                labels[index] = own
            } else if index > 0, case .text(let before) = entries[index - 1], before.count <= 60, !consumed.contains(index - 1) {
                labels[index] = before
                consumed.insert(index - 1)
            }
        }
        let labelSet = Set(labels.values.map { $0.lowercased() })
        let valueSet = Set(entries.compactMap { entry -> String? in
            if case .field(let node) = entry { return fieldValue(node).lowercased() }
            return nil
        })
        var lines: [String] = []
        for (index, entry) in entries.enumerated() {
            switch entry {
            case .text(let text):
                if consumed.contains(index) || labelSet.contains(text.lowercased()) || valueSet.contains(text.lowercased()) { continue }
                lines.append(text)
            case .field(let node):
                let value = fieldValue(node)
                if value.isEmpty { continue }
                if let label = labels[index], label.lowercased() != value.lowercased() { lines.append("\(label): \(value)") } else { lines.append(value) }
            }
        }
        var seen = Set<String>()
        let unique = lines.map { String($0.prefix(maxLineCharacters)) }.filter { seen.insert($0).inserted }
        return String(unique.joined(separator: "\n").prefix(maxBodyCharacters))
    }

    static func title(of container: CaptureNode, windowTitle: String?) -> String {
        if let name = container.name, !name.isEmpty { return name }
        return heading(of: container) ?? windowTitle ?? "Form"
    }
}

/// An item the tracker wants stored, with the window it was read from so the pipeline can apply its gate and floor.
struct CaptureFormEmission: Equatable {
    var snapshot: CaptureSnapshot
    var threadKey: String
    var title: String
    var body: String

    /// A form is one message: the whole body. A changed body is a new message, an unchanged one is stored once.
    var item: CaptureItem {
        CaptureItem(app: snapshot.app, url: snapshot.url, windowTitle: snapshot.windowTitle, threadKey: threadKey, threadTitle: title,
                    content: .conversation(title: title, isGroup: false, messages: [CaptureMessage(text: body, isMe: true)]), parser: "form")
    }
}

/// Holds back the reads of a window while the user types in a form, and emits the form once the field is done: focus left it, the form
/// closed, or `settle` passed without a change. It works on the snapshots the reader already takes, so it adds no accessibility reads.
final class CaptureFormTracker {
    /// How long a field may sit unchanged before its form is emitted.
    static let settleInterval: TimeInterval = 4
    /// How long after a button press the form may disappear and still count as submitted.
    static let submitWindow: TimeInterval = 10
    /// A form untouched for this long is forgotten.
    static let forgetAfter: TimeInterval = 600

    private struct Pending {
        var pid: Int32
        var key: String
        var snapshot: CaptureSnapshot
        var title: String
        var body: String
        var emitted: String?
        var editing = true
        var changedAt: TimeInterval
        var seenAt: TimeInterval
        var button: (title: String, at: TimeInterval)?
    }

    private var pending: [String: Pending] = [:]
    private var ready: [CaptureFormEmission] = []
    private let settle: TimeInterval

    init(settle: TimeInterval = CaptureFormTracker.settleInterval) { self.settle = settle }

    var isIdle: Bool { pending.isEmpty && ready.isEmpty }

    /// When the next unsettled form is due, for sleeping until then.
    var nextWake: TimeInterval? {
        pending.values.filter { $0.editing && $0.body != $0.emitted }.map { $0.changedAt + settle }.min()
    }

    func reset() {
        pending = [:]
        ready = []
    }

    /// Records a press on a button. If the form it belongs to then disappears, it was submitted.
    func notePress(app: CaptureApp, title: String, now: TimeInterval) {
        guard !title.isEmpty else { return }
        for key in pending.keys where pending[key]?.pid == app.pid { pending[key]?.button = (title, now) }
    }

    /// Sees one read. Returns true when the read shows a form being edited, so the caller does not store it as page text.
    @discardableResult
    func observe(_ snapshot: CaptureSnapshot, now: TimeInterval) -> Bool {
        let pid = snapshot.app.pid
        var editingKey: String?
        if let chain = CaptureForm.editedChain(in: snapshot.root) {
            let container = CaptureForm.container(of: chain)
            if container.kind != .field {
                let key = CaptureForm.key(container.node)
                editingKey = key
                let body = CaptureForm.body(of: container.node)
                var state = pending[key] ?? Pending(pid: pid, key: key, snapshot: snapshot, title: "", body: "", changedAt: now, seenAt: now)
                if state.body != body { state.changedAt = now }
                state.snapshot = snapshot
                state.title = CaptureForm.title(of: container.node, windowTitle: snapshot.windowTitle)
                state.body = body
                state.editing = true
                state.seenAt = now
                pending[key] = state
            }
        }
        for key in pending.keys.sorted() where pending[key]?.pid == pid && key != editingKey {
            guard var state = pending[key] else { continue }
            if let node = CaptureForm.find(key: key, in: snapshot.root) {
                state.seenAt = now
                if state.editing {
                    // Focus left the field. Read the form again, since another field may have changed with it.
                    state.editing = false
                    state.snapshot = snapshot
                    state.body = CaptureForm.body(of: node)
                    if state.body != state.emitted { emit(state, marker: nil) }
                    state.emitted = state.body
                }
                pending[key] = state
            } else {
                close(state, now: now)
                pending[key] = nil
            }
        }
        for key in pending.keys where now - (pending[key]?.seenAt ?? now) > Self.forgetAfter { pending[key] = nil }
        return editingKey != nil
    }

    /// Forms whose field has been still for the settle interval, plus what `observe` queued.
    func takeReady(now: TimeInterval) -> [CaptureFormEmission] {
        for key in pending.keys.sorted() {
            guard var state = pending[key], state.editing, state.body != state.emitted, now - state.changedAt >= settle else { continue }
            emit(state, marker: nil)
            state.emitted = state.body
            pending[key] = state
        }
        defer { ready = [] }
        return ready
    }

    private func close(_ state: Pending, now: TimeInterval) {
        if let button = state.button, now - button.at <= Self.submitWindow {
            emit(state, marker: "Submitted: \(button.title)")
        } else {
            emit(state, marker: "Closed without submit")
        }
    }

    private func emit(_ state: Pending, marker: String?) {
        let body = marker.map { "\($0)\n\(state.body)" } ?? state.body
        guard !state.body.isEmpty else { return }
        ready.append(CaptureFormEmission(snapshot: state.snapshot, threadKey: "form:\(state.key)", title: state.title, body: body))
    }
}
