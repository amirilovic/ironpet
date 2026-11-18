import Foundation

/// One unit of content in a window: a chat message, a mail row, a list entry. Found from the shape of the tree alone, so no app is
/// named here: an element is a block when it is a web article (role Group, subrole DocumentArticle), a list item or a row.
struct CaptureBlock: Equatable {
    /// The node's subtree hash. A ref for `screen_window`.
    var ref: String
    /// What the app calls it: the block's accessible name when that name holds text from inside the block, else a line built from the
    /// block's own text.
    var label: String
    /// The longest text in the block that contains a four-digit year, such as a full message date.
    var when: String?
    /// The page id of the block when it has one (`d:<id>`), else a hash of its text without controls (`t:<hash>`).
    var identity: String
    /// The block's text without controls and without text that every sibling repeats, one line per element.
    var text: String
    /// The name of the nearest named list or log around the block.
    var container: String?
    /// Whether `identity` came from a page id. Only such a block can be edited: a hash of changed text is a different block.
    var stable: Bool { identity.hasPrefix("d:") }
}

enum CaptureBlocks {
    private static let blockRoles: Set<String> = ["ListItem", "Row"]
    private static let blockSubroles: Set<String> = ["DocumentArticle", "ListItem"]
    private static let listRoles: Set<String> = ["List", "Table", "Outline", "Grid", "Browser"]
    private static let listSubroles: Set<String> = ["Log", "ContentList", "Feed", "ListBox"]
    private static let textRoles: Set<String> = ["StaticText", "TextArea", "TextField", "SearchField", "ComboBox"]

    /// A text that most of a block's siblings repeat is a control label, not content. It needs this many siblings to be judged.
    static let minSiblings = 3
    static let repeatShare = 0.6
    static let maxLabelCharacters = 160
    static let maxTextCharacters = 2_000

    static func isBlock(_ node: AXNode) -> Bool {
        blockRoles.contains(node.role) || (node.subrole.map(blockSubroles.contains) ?? false)
    }

    private static func isControl(_ node: AXNode) -> Bool {
        CaptureText.chromeRoles.contains(node.role) || (node.subrole.map(CaptureText.chromeSubroles.contains) ?? false)
    }

    private struct Raw {
        var node: AXNode
        var container: String?
        /// Document order. `control` marks the name of a button or similar, which is kept for the label but not for the text.
        var texts: [(text: String, control: Bool)] = []
        var strings: [String] = []
        var names: [String] = []
        var domId: String?
    }

    /// The blocks of a tree, outermost first, in document order.
    static func extract(_ root: AXNode) -> [CaptureBlock] {
        var groups: [[Raw]] = []
        var indexOfParent: [Int: Int] = [:]
        var counter = 0
        func walk(_ node: AXNode, parent: Int, container: String?, wrapperId: String? = nil) {
            counter += 1
            let me = counter
            if node.isSecure { return }
            if isBlock(node) {
                let slot = indexOfParent[parent] ?? { groups.append([]); indexOfParent[parent] = groups.count - 1; return groups.count - 1 }()
                groups[slot].append(raw(node, container: container, wrapperId: wrapperId))
                return
            }
            var inner = container
            if listRoles.contains(node.role) || (node.subrole.map(listSubroles.contains) ?? false), let name = node.name { inner = clip(name) }
            // An id on a wrapper whose only child is the block names the block.
            let id = node.children.count == 1 ? node.domId : nil
            // A chain of single-child wrappers around each block does not make the blocks strangers: they still share the list above.
            let group = node.children.count == 1 ? parent : me
            for child in node.children { walk(child, parent: group, container: inner, wrapperId: id) }
        }
        walk(root, parent: 0, container: nil)
        return groups.flatMap(finish)
    }

    private static func raw(_ node: AXNode, container: String?, wrapperId: String?) -> Raw {
        var raw = Raw(node: node, container: container)
        raw.domId = node.domId ?? wrapperId
        func collect(_ n: AXNode, isRoot: Bool) {
            if n.isSecure { return }
            for text in [n.title, n.value, n.description] { if let text, !text.isEmpty { raw.strings.append(text) } }
            if !isRoot, isBlock(n) {
                if let name = n.name { raw.names.append(name) }
                if raw.domId == nil { raw.domId = n.domId }
            }
            if CaptureTree.isInput(n) { return }
            if isControl(n) {
                if let name = n.name ?? n.value, !name.isEmpty { raw.texts.append((name, true)) }
                n.children.forEach { collect($0, isRoot: false) }
                return
            }
            if n.role == "Heading", let name = n.name {
                raw.texts.append((name, false))
                // The children of a heading repeat its name. Their strings still count for the date.
                collectStrings(n, into: &raw.strings, skipSelf: true)
                return
            }
            if textRoles.contains(n.role) {
                if let text = n.value ?? n.title ?? n.description, !text.isEmpty { raw.texts.append((text, false)) }
            } else if n.role == "Link", n.children.isEmpty, let name = n.name ?? n.value {
                raw.texts.append((name, false))
            }
            n.children.forEach { collect($0, isRoot: false) }
        }
        if let name = node.name { raw.names.insert(name, at: 0) }
        collect(node, isRoot: true)
        return raw
    }

    private static func collectStrings(_ node: AXNode, into out: inout [String], skipSelf: Bool) {
        if !skipSelf { for text in [node.title, node.value, node.description] { if let text, !text.isEmpty { out.append(text) } } }
        for child in node.children where !child.isSecure { collectStrings(child, into: &out, skipSelf: false) }
    }

    /// The texts that at least `repeatShare` of at least `minSiblings` siblings have.
    static func repeated(among sets: [Set<String>]) -> Set<String> {
        guard sets.count >= minSiblings else { return [] }
        var counts: [String: Int] = [:]
        for set in sets { for text in set { counts[text, default: 0] += 1 } }
        let needed = Double(sets.count) * repeatShare
        return Set(counts.filter { Double($0.value) >= needed }.keys)
    }

    private static func finish(_ group: [Raw]) -> [CaptureBlock] {
        let common = repeated(among: group.map { Set($0.texts.map { normalize($0.text) }) })
        return group.compactMap { raw in
            let kept = raw.texts.filter { !common.contains(normalize($0.text)) }
            var lines: [String] = []
            for item in kept where !item.control {
                for piece in item.text.split(whereSeparator: \.isNewline) {
                    let line = piece.trimmingCharacters(in: .whitespaces)
                    if !line.isEmpty, line != lines.last { lines.append(line) }
                }
            }
            let text = clip(lines.joined(separator: "\n"), max: maxTextCharacters)
            let all = kept.map(\.text)
            // A name counts when it holds text that is inside the block. "Message Actions" names a control group, not a message.
            let named = raw.names.first { name in all.contains { $0.count >= 2 && name.contains($0) } }
            let fallback = all.joined(separator: " , ")
            let label = clip((named ?? fallback).split(whereSeparator: \.isNewline).joined(separator: " "), max: maxLabelCharacters)
            guard !label.isEmpty || !text.isEmpty else { return nil }
            let identity = raw.domId.map { "d:" + $0 } ?? "t:" + CaptureTree.hash(text.isEmpty ? label : text)
            return CaptureBlock(ref: raw.node.ref, label: label, when: when(in: raw.strings), identity: identity, text: text, container: raw.container)
        }
    }

    private static let year = try! NSRegularExpression(pattern: #"\b(?:19|20)\d{2}\b"#)

    private static func when(in strings: [String]) -> String? {
        var best: String?
        for text in strings {
            let range = NSRange(text.startIndex..., in: text)
            guard year.firstMatch(in: text, range: range) != nil else { continue }
            let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            if line.count > (best?.count ?? 0) { best = line }
        }
        return best.map { clip($0, max: 80) }
    }

    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func clip(_ text: String, max limit: Int = maxLabelCharacters) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }
}
