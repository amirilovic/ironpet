import AppKit
import SwiftUI
import WebKit

/// Block-level markdown for agent replies. SwiftUI's `Text` only renders inline markdown (bold, code,
/// links), so headings, lists, quotes, code blocks, tables and rules are split out here and inline
/// markdown inside each block still goes through `AttributedString(markdown:)`.
enum Markdown {
    struct ListItem: Equatable {
        var indent: Int
        var marker: String
        var text: String

        /// `- [ ] todo` and `- [x] done` render as checkboxes.
        var task: (done: Bool, text: String)? {
            for (prefix, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(prefix) {
                return (done, String(text.dropFirst(prefix.count)))
            }
            return nil
        }
    }

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list(ordered: Bool, items: [ListItem])
        case quote(String)
        /// `closed` is false while a reply is still streaming the block; a diagram renders only once closed.
        case code(language: String?, text: String, closed: Bool)
        case table(header: [String], rows: [[String]])
        case rule
    }

    /// The text each block draws, in order, for search. Closed mermaid diagrams render as an image and have none.
    static func segments(of block: Block) -> [String] {
        func shown(_ markdown: String) -> String { String(inline(markdown).characters) }
        switch block {
        case .heading(_, let text), .paragraph(let text), .quote(let text):
            return [shown(text)]
        case .list(_, let items):
            return items.map { shown($0.task?.text ?? $0.text) }
        case .code(let language, let text, let closed):
            return language?.lowercased() == "mermaid" && closed ? [] : [text]
        case .table(let header, let rows):
            return (header + rows.flatMap { $0 }).map(shown)
        case .rule:
            return []
        }
    }

    static func segments(of text: String) -> [String] {
        parse(text).flatMap { segments(of: $0) }
    }

    static func parse(_ text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var i = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }
            if let fence = fence(trimmed) {
                flush()
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                var closed = false
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        closed = true
                        i += 1
                        break
                    }
                    body.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n"), closed: closed))
                continue
            }
            if let heading = heading(trimmed) {
                flush()
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }
            if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    var cells = cells(row)
                    if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                    rows.append(Array(cells.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    guard next.hasPrefix(">") else { break }
                    var content = next.dropFirst()
                    if content.hasPrefix(" ") { content = content.dropFirst() }
                    quoted.append(String(content))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            if let first = listItem(line) {
                flush()
                var items = [first]
                i += 1
                while i < lines.count {
                    if let item = listItem(lines[i]) {
                        items.append(item)
                    } else if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                              lines[i].hasPrefix("  ") || lines[i].hasPrefix("\t") {
                        // An indented line that is not a new item continues the previous one.
                        items[items.count - 1].text += " " + lines[i].trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    i += 1
                }
                let ordered = first.marker.first?.isNumber == true
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }
            paragraph.append(trimmed)
            i += 1
        }
        flush()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        return FilePathLinks.link(parsed)
    }

    private static func fence(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            let run = trimmed.prefix { $0 == marker.first }
            return String(run)
        }
        return nil
    }

    private static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        let parts = cells(trimmed)
        return !parts.isEmpty && parts.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    private static func cells(_ row: String) -> [String] {
        var row = row.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: String) -> ListItem? {
        let expanded = line.replacingOccurrences(of: "\t", with: "    ")
        let spaces = expanded.prefix { $0 == " " }.count
        let rest = expanded.dropFirst(spaces)
        var marker = ""
        if let first = rest.first, "-*+".contains(first) {
            marker = String(first)
        } else {
            let digits = rest.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 3 else { return nil }
            let after = rest.dropFirst(digits.count).first
            guard after == "." || after == ")" else { return nil }
            marker = String(digits) + "."
        }
        let afterMarker = rest.dropFirst(marker.first?.isNumber == true ? marker.count : 1)
        guard afterMarker.first == " " else { return nil }
        return ListItem(indent: spaces / 2, marker: marker, text: afterMarker.trimmingCharacters(in: .whitespaces))
    }
}

/// Renders a reply's markdown as SwiftUI views. The caller sets the base font.
struct MarkdownView: View {
    let text: String
    /// Highlights for the open find bar. Nil for rows with no match.
    var find: ChatFind.RowHighlight?
    /// Redraws when a background check finds that a path in the text exists, so it turns into a link.
    @ObservedObject private var paths = PathCache.shared

    var body: some View {
        let blocks = Markdown.parse(text)
        // Only a row with a match needs the segment numbers, so streaming without find parses nothing extra.
        let starts = find == nil ? [] : blocks.reduce(into: [0]) { $0.append($0.last! + Markdown.segments(of: $1).count) }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block, segment: starts.isEmpty ? 0 : starts[index])
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { FilePathLinks.handle($0) })
    }

    /// The reply font set by the caller, which the link cursor layout has to match.
    static let baseSize: CGFloat = 13.5

    private func linked(_ text: String, _ segment: Int, size: CGFloat = baseSize, lineSpacing: CGFloat = 0, weight: NSFont.Weight = .regular) -> some View {
        let parsed = Markdown.inline(text)
        return ChatFind.text(parsed, segment: segment, find: find).lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .linkCursor(parsed, size: size, lineSpacing: lineSpacing, weight: weight)
    }

    @ViewBuilder
    private func view(for block: Markdown.Block, segment: Int) -> some View {
        switch block {
        case .heading(let level, let text):
            linked(text, segment, size: level == 1 ? 17 : level == 2 ? 15.5 : 14, weight: level <= 2 ? .bold : .semibold)
                .font(.system(size: level == 1 ? 17 : level == 2 ? 15.5 : 14, weight: level <= 2 ? .bold : .semibold))
                .padding(.top, 2)
        case .paragraph(let text):
            linked(text, segment, lineSpacing: 2)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    ListRow(item: item, ordered: ordered, segment: segment + index, find: find)
                }
            }
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                linked(text, segment).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text, let closed):
            if language?.lowercased() == "mermaid", closed {
                MermaidBlock(code: text)
            } else {
                CodeBlock(language: language, code: text, segment: segment, find: find)
            }
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows, segment: segment, find: find)
        case .rule:
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.vertical, 2)
        }
    }
}

private struct ListRow: View {
    let item: Markdown.ListItem
    let ordered: Bool
    let segment: Int
    let find: ChatFind.RowHighlight?
    @ObservedObject private var paths = PathCache.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            bullet.frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
            let text = Markdown.inline(task?.text ?? item.text)
            ChatFind.text(text, segment: segment, find: find).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .linkCursor(text, size: MarkdownView.baseSize, lineSpacing: 2)
        }
        .padding(.leading, CGFloat(item.indent) * 14)
    }

    private var task: (done: Bool, text: String)? { item.task }

    @ViewBuilder
    private var bullet: some View {
        if let task {
            Image(systemName: task.done ? "checkmark.square.fill" : "square").foregroundStyle(.secondary)
        } else if item.marker.first?.isNumber == true {
            // Per item, not per list: a bulleted sub-item under a numbered list keeps its bullet.
            Text(item.marker).monospacedDigit().foregroundStyle(.secondary)
        } else {
            Text(item.indent == 0 ? "•" : "◦").foregroundStyle(.secondary)
        }
    }
}

private struct CodeBlock: View {
    let language: String?
    let code: String
    let segment: Int
    let find: ChatFind.RowHighlight?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.borderless)
                .pointerCursor()
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                ChatFind.text(AttributedString(code), segment: segment, find: find)
                    .font(.system(size: 12, design: .monospaced))
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]
    let segment: Int
    let find: ChatFind.RowHighlight?
    @ObservedObject private var paths = PathCache.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                        ChatFind.text(Markdown.inline(cell), segment: segment + column, find: find).fontWeight(.semibold)
                    }
                }
                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).gridCellColumns(max(header.count, 1))
                let rowStarts = rows.reduce(into: [segment + header.count]) { $0.append($0.last! + $1.count) }
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            ChatFind.text(Markdown.inline(cell), segment: rowStarts[r] + column, find: find)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - Mermaid

/// `mermaid.html` and `mermaid.min.js` are copied into the app bundle by `scripts/bundle.sh`. Debug builds
/// and preview renders don't have them, so diagrams fall back to their source as a code block.
enum MermaidAssets {
    static var page: URL? { Bundle.main.url(forResource: "mermaid", withExtension: "html") }
}

private struct MermaidBlock: View {
    let code: String
    @State private var height: CGFloat = 80
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let page = MermaidAssets.page {
            MermaidWebView(page: page, code: code, dark: colorScheme == .dark, height: $height)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        } else {
            CodeBlock(language: "mermaid", code: code, segment: 0, find: nil)
        }
    }
}

/// Renders one diagram with the bundled mermaid.js. Mermaid runs with `securityLevel: 'strict'` (no click
/// handlers or HTML in labels), the page loads nothing from the network, and any navigation away is refused.
private struct MermaidWebView: NSViewRepresentable {
    let page: URL
    let code: String
    let dark: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> PassThroughWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "size")
        let view = PassThroughWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.pending = (code, dark)
        view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: PassThroughWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.render(code, dark: dark, in: view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var height: Binding<CGFloat>
        var pending: (code: String, dark: Bool)?
        private var loaded = false
        private var shown: (code: String, dark: Bool)?

        init(height: Binding<CGFloat>) { self.height = height }

        func render(_ code: String, dark: Bool, in view: WKWebView) {
            guard loaded else { pending = (code, dark); return }
            if let shown, shown.code == code, shown.dark == dark { return }
            shown = (code, dark)
            let source = (try? String(data: JSONEncoder().encode(code), encoding: .utf8)) ?? "\"\""
            view.evaluateJavaScript("void renderDiagram(\(source), \(dark))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let pending { render(pending.code, dark: pending.dark, in: webView) }
            pending = nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.isFileURL == true && action.navigationType == .other ? .allow : .cancel)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let size = message.body as? [String: Any], let h = (size["h"] as? NSNumber)?.doubleValue, h > 0 else { return }
            height.wrappedValue = CGFloat(h)
        }
    }
}

/// Scrolling over a diagram scrolls the chat, not the (non-scrolling) page.
private final class PassThroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

/// WKUserContentController retains its handlers; this breaks the cycle with the coordinator.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
