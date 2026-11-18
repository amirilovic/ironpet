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

/// Renders a reply's markdown as SwiftUI views. Each run of text blocks (headings, paragraphs, lists, quotes)
/// is one selectable text view, so a drag selects across them. Code, tables, diagrams and rules are views of
/// their own and selection stops at them. `size` is the reply's base font size.
struct MarkdownView: View {
    let text: String
    var size: CGFloat = 13.5
    /// Highlights for the open find bar. Nil for rows with no match.
    var find: ChatFind.RowHighlight?
    /// Redraws when a background check finds that a path in the text exists, so it turns into a link.
    @ObservedObject private var paths = PathCache.shared

    private enum Piece {
        case text([Markdown.Block], segment: Int)
        case block(Markdown.Block, segment: Int)
    }

    var body: some View {
        let blocks = Markdown.parse(text)
        // Only a row with a match needs the segment numbers, so streaming without find parses nothing extra.
        let starts = find == nil ? [] : blocks.reduce(into: [0]) { $0.append($0.last! + Markdown.segments(of: $1).count) }
        let pieces = Self.pieces(blocks, starts: starts)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .text(let blocks, let segment):
                    MarkdownTextView(content: MarkdownText.attributed(blocks, size: size, firstSegment: segment, find: find))
                case .block(let block, let segment):
                    view(for: block, segment: segment)
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { FilePathLinks.handle($0) })
                }
            }
        }
    }

    private static func pieces(_ blocks: [Markdown.Block], starts: [Int]) -> [Piece] {
        var pieces: [Piece] = []
        for (index, block) in blocks.enumerated() {
            let segment = starts.isEmpty ? 0 : starts[index]
            if MarkdownText.isTextBlock(block) {
                if case .text(let run, let first)? = pieces.last {
                    pieces[pieces.count - 1] = .text(run + [block], segment: first)
                } else {
                    pieces.append(.text([block], segment: segment))
                }
            } else {
                pieces.append(.block(block, segment: segment))
            }
        }
        return pieces
    }

    @ViewBuilder
    private func view(for block: Markdown.Block, segment: Int) -> some View {
        switch block {
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
        case .heading, .paragraph, .list, .quote:
            EmptyView()
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
