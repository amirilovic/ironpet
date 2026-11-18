import CryptoKit
import Foundation

/// A window's accessibility tree as a Merkle tree. Each node is one row keyed by the hash of its own fields and its children's
/// hashes, so a subtree that did not change between captures is the same row and is stored once. A capture row holds only the root
/// hash, and a new capture writes the nodes on the path from a changed element up to the root.
///
/// Node data is a JSON array `[children, role, subrole, title, value, description, url, domId]`, with trailing nulls dropped. `children`
/// comes first and is one string: the children's hashes, `hashLength` characters each, in order. Reading it needs no JSON parse, which
/// keeps the sweep that deletes unreferenced nodes cheap.
enum CaptureTree {
    /// 9 bytes of SHA-256, base64url: 12 characters. A collision needs about 2^36 nodes, far above what a retention window holds.
    static let hashLength = 12

    /// A text field longer than this is cut. A window with more is a log or a document, and the start says enough.
    static let maxFieldCharacters = 8_000

    struct Entry: Equatable {
        let hash: String
        let data: String
    }

    struct Prepared {
        /// Unique entries, every child before its parent.
        var entries: [Entry]
        var root: String
        /// The hash of the same tree with the text of input fields blanked. It stays equal while the user types.
        var contentRoot: String
        /// Elements kept, after hidden ones were dropped.
        var elements: Int
        /// The cleaned tree, with `ref` set on every node.
        var tree: AXNode
    }

    /// Cleans a tree and hashes it. Hidden elements are dropped. A secure field keeps its role and subrole only. Every text goes through
    /// `clean` (the redactor and the privacy filter), and a page address through `cleanURL`.
    static func prepare(_ root: AXNode, clean: (String) -> String, cleanURL: (String) -> String = { $0 }) -> Prepared {
        var entries: [Entry] = []
        var seen = Set<String>()
        var count = 0
        var cache: [String: String] = [:]
        func cleaned(_ text: String?) -> String? {
            guard var text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if text.count > maxFieldCharacters { text = String(text.prefix(maxFieldCharacters)) }
            if let known = cache[text] { return known.isEmpty ? nil : known }
            let result = clean(text)
            cache[text] = result
            return result.isEmpty ? nil : result
        }
        func build(_ node: AXNode) -> AXNode {
            count += 1
            var out = AXNode(role: node.role, subrole: node.subrole)
            if !node.isSecure {
                out.title = cleaned(node.title)
                out.value = cleaned(node.value)
                out.description = cleaned(node.description)
                out.url = node.url.flatMap { $0.isEmpty ? nil : cleanURL($0) }
                out.domId = node.domId.flatMap { $0.isEmpty ? nil : $0 }
                out.children = node.children.filter { !$0.hidden }.map(build)
            }
            let data = encode(out)
            out.ref = hash(data)
            if seen.insert(out.ref).inserted { entries.append(Entry(hash: out.ref, data: data)) }
            return out
        }
        var top = root
        top.hidden = false
        let tree = build(top)
        return Prepared(entries: entries, root: tree.ref, contentRoot: contentHash(tree), elements: count, tree: tree)
    }

    private static let inputRoles: Set<String> = ["TextArea", "TextField", "SearchField", "ComboBox"]

    /// True for an element the user types into.
    static func isInput(_ node: AXNode) -> Bool { inputRoles.contains(node.role) }

    /// The root hash of `tree` with input values blanked, computed without storing anything.
    static func contentHash(_ tree: AXNode) -> String {
        func walk(_ node: AXNode) -> String {
            var copy = node
            if isInput(node) { copy.value = nil }
            copy.children = []
            return hash(encode(copy, children: node.children.map(walk)))
        }
        return walk(tree)
    }

    // MARK: Encoding

    static func hash(_ data: String) -> String {
        Data(SHA256.hash(data: Data(data.utf8)).prefix(9)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    static func encode(_ node: AXNode) -> String { encode(node, children: node.children.map(\.ref)) }

    private static func encode(_ node: AXNode, children: [String]) -> String {
        var fields: [String?] = [children.joined(), node.role, node.subrole, node.title, node.value, node.description, node.url, node.domId]
        while let last = fields.last, last == nil { fields.removeLast() }
        return "[" + fields.map { $0.map(quote) ?? "null" }.joined(separator: ",") + "]"
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        out.reserveCapacity(text.utf8.count + 2)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    /// One node's fields and its children's hashes. Nil for data this code did not write.
    static func decode(hash: String, data: String) -> (node: AXNode, children: [String])? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [Any], json.count > 1, let role = json[1] as? String else { return nil }
        func field(_ index: Int) -> String? { index < json.count ? json[index] as? String : nil }
        var node = AXNode(role: role, subrole: field(2), title: field(3), value: field(4), description: field(5), url: field(6), domId: field(7))
        node.ref = hash
        return (node, children(of: data))
    }

    /// The children's hashes, read from the front of the data without parsing it.
    static func children(of data: String) -> [String] {
        guard data.hasPrefix("[\"") else { return [] }
        let body = data.dropFirst(2)
        guard let end = body.firstIndex(of: "\"") else { return [] }
        let joined = body[body.startIndex..<end]
        var kids: [String] = []
        var index = joined.startIndex
        while index < joined.endIndex {
            let stop = joined.index(index, offsetBy: hashLength, limitedBy: joined.endIndex) ?? joined.endIndex
            kids.append(String(joined[index..<stop]))
            index = stop
        }
        return kids
    }
}
