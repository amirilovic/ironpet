import Foundation

/// What an agent reads of a stored tree: a short outline instead of every element. Three rules apply to any app. A heading reads by its
/// name, because its value is its level. An unnamed wrapper group is skipped. A text that most sibling blocks repeat (a control label
/// such as "Reply" that the page prints in every message) is dropped.
enum CaptureView {
    static let maxLines = 200
    static let maxTextCharacters = 100

    /// The text an element shows, by role.
    static func displayText(_ node: AXNode) -> String? {
        func clean(_ text: String?) -> String? {
            guard let text else { return nil }
            let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
        switch node.role {
        case "Heading": return clean(node.title) ?? clean(node.description) ?? clean(node.value).flatMap { Int($0) == nil ? $0 : nil }
        case "StaticText", "TextArea", "TextField", "SearchField", "ComboBox": return clean(node.value) ?? clean(node.title) ?? clean(node.description)
        default:
            return clean(node.title) ?? clean(node.description) ?? clean(node.value)
        }
    }

    // MARK: Cleaning

    /// The tree without text that most sibling blocks repeat, and without the wrappers that held only that text. Refs stay as they were.
    static func cleaned(_ root: AXNode) -> AXNode {
        func walk(_ node: AXNode) -> AXNode {
            var copy = node
            let blocks = node.children.compactMap(soleBlock)
            var common = Set<String>()
            if blocks.count >= CaptureBlocks.minSiblings {
                common = CaptureBlocks.repeated(among: blocks.map { Set(texts(in: $0).map(CaptureBlocks.normalize)) })
            }
            copy.children = node.children.map { common.isEmpty ? walk($0) : walk(strip($0, common: common)) }
            return copy
        }
        return walk(root)
    }

    /// The block a child is, or the block inside a chain of single-child wrappers around it.
    private static func soleBlock(_ node: AXNode) -> AXNode? {
        if CaptureBlocks.isBlock(node) { return node }
        return node.children.count == 1 ? soleBlock(node.children[0]) : nil
    }

    private static func strip(_ node: AXNode, common: Set<String>) -> AXNode {
        if CaptureBlocks.isBlock(node) { return prune(node, common: common, isRoot: true) ?? node }
        guard node.children.count == 1, soleBlock(node) != nil else { return node }
        var copy = node
        copy.children = [strip(node.children[0], common: common)]
        return copy
    }

    private static func texts(in node: AXNode) -> [String] {
        var out: [String] = []
        func walk(_ n: AXNode) {
            if let text = displayText(n) { out.append(text) }
            n.children.forEach(walk)
        }
        walk(node)
        return out
    }

    private static func prune(_ node: AXNode, common: Set<String>, isRoot: Bool) -> AXNode? {
        var copy = node
        copy.children = node.children.compactMap { prune($0, common: common, isRoot: false) }
        if isRoot { return copy }
        let own = displayText(node)
        let isCommon = own.map { common.contains(CaptureBlocks.normalize($0)) } ?? false
        if isCommon && copy.children.isEmpty { return nil }
        // A wrapper emptied by the rule goes too.
        if copy.children.isEmpty, own == nil, !node.children.isEmpty { return nil }
        if isCommon { copy.title = nil; copy.value = nil; copy.description = nil }
        return copy
    }

    // MARK: Rendering

    /// A node that only groups: no name, no text, not a block.
    private static func isWrapper(_ node: AXNode) -> Bool {
        (node.role == "Group" || node.role == "Unknown" || node.role == "ScrollArea" || node.role == "SplitGroup")
            && node.subrole == nil && displayText(node) == nil && !CaptureBlocks.isBlock(node)
    }

    /// An outline, one element per line, indented by depth (wrappers do not count). Each line has the role, its text, the number of
    /// children and the ref to read that subtree with. At the depth limit a line shows how many children it hides.
    static func outline(_ root: AXNode, depth: Int, maxLines: Int = maxLines, maxChildren: Int = 12) -> (lines: [String], omitted: Int) {
        var lines: [String] = []
        var omitted = 0
        func walk(_ node: AXNode, level: Int) {
            if isWrapper(node) { node.children.forEach { walk($0, level: level) }; return }
            guard lines.count < maxLines else { omitted += 1 + count(node.children); return }
            var line = String(repeating: "  ", count: level) + node.role.lowercased()
            if let subrole = node.subrole { line += "." + subrole.lowercased() }
            if let text = displayText(node) { line += " \"" + clip(text) + "\"" }
            let kids = visibleChildren(node)
            if !kids.isEmpty { line += " [\(kids.count)]" }
            if !kids.isEmpty || CaptureBlocks.isBlock(node) { line += " #" + node.ref }
            lines.append(line)
            if level + 1 >= depth { return }
            // A list of 60 messages shows its first few and counts the rest, so the outline stays short. Read the list with its ref.
            for child in kids.prefix(maxChildren) { walk(child, level: level + 1) }
            if kids.count > maxChildren {
                lines.append(String(repeating: "  ", count: level + 1) + "… \(kids.count - maxChildren) more under #" + node.ref)
            }
        }
        walk(root, level: 0)
        return (lines, omitted)
    }

    /// Children that would print as lines, with wrappers replaced by what is inside them.
    private static func visibleChildren(_ node: AXNode) -> [AXNode] {
        node.children.flatMap { isWrapper($0) ? visibleChildren($0) : [$0] }
    }

    private static func count(_ nodes: [AXNode]) -> Int { nodes.reduce(0) { $0 + 1 + count($1.children) } }

    private static func clip(_ text: String) -> String {
        text.count > maxTextCharacters ? String(text.prefix(maxTextCharacters - 1)) + "…" : text
    }

    // MARK: Lookup

    /// The first node whose ref starts with `ref`.
    static func find(_ root: AXNode, ref: String) -> AXNode? {
        let wanted = ref.hasPrefix("#") ? String(ref.dropFirst()) : ref
        guard wanted.count >= 6 else { return nil }
        if root.ref.hasPrefix(wanted) { return root }
        for child in root.children { if let found = find(child, ref: wanted) { return found } }
        return nil
    }

    /// Elements with a role (`AX` prefix and case ignored), optionally whose text contains `text`, with the nearest named list around each.
    static func search(_ root: AXNode, role: String, text: String? = nil, limit: Int = 50) -> (lines: [String], omitted: Int) {
        let wanted = (role.hasPrefix("AX") ? String(role.dropFirst(2)) : role).lowercased()
        let needle = text?.lowercased()
        var lines: [String] = [], omitted = 0
        func walk(_ node: AXNode, container: String?) {
            var inner = container
            if let name = node.name, ["List", "Table", "Outline", "Grid"].contains(node.role) { inner = name }
            if node.role.lowercased() == wanted || node.subrole?.lowercased() == wanted {
                let shown = displayText(node)
                if needle == nil || shown?.lowercased().contains(needle!) == true {
                    if lines.count < limit {
                        var line = node.role.lowercased()
                        if let shown { line += " \"" + clip(shown) + "\"" }
                        if let inner { line += " in " + clip(inner) }
                        lines.append(line + " #" + node.ref)
                    } else { omitted += 1 }
                }
            }
            node.children.forEach { walk($0, container: inner) }
        }
        walk(root, container: nil)
        return (lines, omitted)
    }
}
