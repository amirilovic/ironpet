import AppKit
import SwiftUI

/// The text blocks of a reply (headings, paragraphs, lists and quotes) as one attributed string. One string
/// in one `NSTextView` lets a drag select across blocks, which separate SwiftUI `Text` views cannot do.
enum MarkdownText {
    /// On a list marker: what Cmd-C writes in its place, so a copied list keeps its `- ` and `1. ` markers.
    static let copyText = NSAttributedString.Key("ironpet.copyText")
    /// On a quote: the text view draws a bar beside it.
    static let quoteBar = NSAttributedString.Key("ironpet.quoteBar")

    static let quoteIndent: CGFloat = 11
    static let listIndent: CGFloat = 14
    static let blockSpacing: CGFloat = 8
    static let itemSpacing: CGFloat = 4
    static let markerGap: CGFloat = 6

    static func isTextBlock(_ block: Markdown.Block) -> Bool {
        switch block {
        case .heading, .paragraph, .list, .quote: return true
        case .code, .table, .rule: return false
        }
    }

    /// `blocks` must all be text blocks. `firstSegment` is the find segment number of the first piece of text.
    static func attributed(_ blocks: [Markdown.Block], size: CGFloat, firstSegment: Int = 0,
                           find: ChatFind.RowHighlight? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var segment = firstSegment

        func piece(_ text: AttributedString, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
                   fontSize: CGFloat = size) -> NSMutableAttributedString {
            let converted = convert(text, size: fontSize, weight: weight, color: color)
            highlight(converted, segment: segment, find: find)
            segment += 1
            return converted
        }

        for block in blocks {
            switch block {
            case .heading(let level, let text):
                let heading: CGFloat = level == 1 ? 17 : level == 2 ? 15.5 : 14
                let body = piece(Markdown.inline(text), weight: level <= 2 ? .bold : .semibold, fontSize: heading)
                result.append(paragraphs(body, style: style(before: 2), last: style(before: 2, after: blockSpacing)))
            case .paragraph(let text):
                let body = piece(Markdown.inline(text))
                result.append(paragraphs(body, style: style(lineSpacing: 2), last: style(lineSpacing: 2, after: blockSpacing - 2)))
            case .quote(let text):
                let body = piece(Markdown.inline(text), color: .secondaryLabelColor)
                let inner = style(first: quoteIndent, head: quoteIndent)
                let quoted = paragraphs(body, style: inner, last: style(first: quoteIndent, head: quoteIndent, after: blockSpacing))
                quoted.addAttribute(quoteBar, value: true, range: NSRange(location: 0, length: quoted.length - 1))
                result.append(quoted)
            case .list(_, let items):
                for (index, item) in items.enumerated() {
                    let task = item.task
                    let body = piece(Markdown.inline(task?.text ?? item.text))
                    let (marker, markerEnd) = marker(for: item, task: task, size: size)
                    let head = markerEnd + markerGap
                    let tabs = [NSTextTab(textAlignment: .right, location: markerEnd), NSTextTab(textAlignment: .left, location: head)]
                    let start = CGFloat(item.indent) * listIndent
                    // A paragraph's line spacing also follows its last line, which SwiftUI's does not.
                    let after = (index == items.count - 1 ? blockSpacing : itemSpacing) - 2
                    let line = NSMutableAttributedString()
                    line.append(marker)
                    line.append(body)
                    result.append(paragraphs(line, style: style(lineSpacing: 2, first: start, head: head, tabs: tabs, after: after),
                                             last: style(lineSpacing: 2, first: start, head: head, tabs: tabs, after: after)))
                }
            case .code, .table, .rule:
                break
            }
        }
        // The last paragraph has no gap below it. The view's stack spaces it from the next block.
        if result.length > 0 {
            let last = NSRange(location: result.length - 1, length: 1)
            result.deleteCharacters(in: last)
            if result.length > 0 {
                let range = (result.string as NSString).paragraphRange(for: NSRange(location: result.length - 1, length: 0))
                if let style = result.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                   let copy = style.mutableCopy() as? NSMutableParagraphStyle {
                    copy.paragraphSpacing = 0
                    result.addAttribute(.paragraphStyle, value: copy, range: range)
                }
            }
        }
        return result
    }

    // MARK: Pieces

    private static func style(lineSpacing: CGFloat = 0, before: CGFloat = 0, first: CGFloat = 0, head: CGFloat = 0,
                              tabs: [NSTextTab] = [], after: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.firstLineHeadIndent = first
        style.headIndent = head
        style.tabStops = tabs
        style.defaultTabInterval = 0
        return style
    }

    /// Ends `text` with a paragraph break and styles it. Lines inside one block are paragraphs of their own, and
    /// only the last one gets the gap below the block.
    private static func paragraphs(_ text: NSMutableAttributedString, style inner: NSParagraphStyle, last: NSParagraphStyle) -> NSMutableAttributedString {
        let attributes = text.length > 0 ? text.attributes(at: text.length - 1, effectiveRange: nil) : [:]
        text.append(NSAttributedString(string: "\n", attributes: attributes))
        text.addAttribute(.paragraphStyle, value: inner, range: NSRange(location: 0, length: text.length))
        let range = (text.string as NSString).paragraphRange(for: NSRange(location: text.length - 1, length: 0))
        text.addAttribute(.paragraphStyle, value: last, range: range)
        return text
    }

    nonisolated(unsafe) private static var checkboxes: [String: NSTextAttachment] = [:]

    /// One attachment per symbol and size. Attachments compare by identity, so a fresh one on every render would make
    /// the text view see changed content each time and re-lay out the text.
    private static func checkbox(done: Bool, size: CGFloat) -> NSTextAttachment {
        let symbol = done ? "checkmark.square.fill" : "square"
        let key = "\(symbol)-\(size)"
        if let cached = checkboxes[key] { return cached }
        let attachment = NSTextAttachment()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular)) {
            image.isTemplate = true
            attachment.image = image
            // Sits on the baseline like the text beside it.
            attachment.bounds = CGRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
        }
        checkboxes[key] = attachment
        return attachment
    }

    /// The marker with its leading and trailing tab, and where the marker column ends.
    private static func marker(for item: Markdown.ListItem, task: (done: Bool, text: String)?, size: CGFloat) -> (NSAttributedString, CGFloat) {
        let start = CGFloat(item.indent) * listIndent
        let indentCopy = String(repeating: "  ", count: item.indent)
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor]
        let glyph: NSAttributedString
        let minimum: CGFloat
        let copy: String
        if let task {
            let attachment = checkbox(done: task.done, size: size)
            glyph = NSAttributedString(attachment: attachment)
            minimum = 10
            copy = indentCopy + (task.done ? "- [x] " : "- [ ] ")
        } else if item.marker.first?.isNumber == true {
            attributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
            glyph = NSAttributedString(string: item.marker, attributes: attributes)
            minimum = 18
            copy = indentCopy + item.marker + " "
        } else {
            glyph = NSAttributedString(string: item.indent == 0 ? "•" : "◦", attributes: attributes)
            minimum = 10
            copy = indentCopy + "- "
        }
        let width = max(minimum, ceil(glyph.size().width))
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "\t", attributes: attributes))
        text.append(glyph)
        text.append(NSAttributedString(string: "\t", attributes: attributes))
        let range = NSRange(location: 0, length: text.length)
        text.addAttributes(attributes.filter { $0.key == .foregroundColor }, range: range)
        text.addAttribute(copyText, value: copy, range: range)
        return (text, start + width)
    }

    // MARK: Inline

    /// The inline markdown of one block: bold, italic, code spans, strikethrough and links.
    static func convert(_ text: AttributedString, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for run in text.runs {
            var font = NSFont.systemFont(ofSize: size, weight: weight)
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: size, weight: weight) }
                if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            attributes[.font] = font
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return result
    }

    /// Marks the find matches in one segment, in the same colors the `Text` rows use.
    private static func highlight(_ text: NSMutableAttributedString, segment: Int, find: ChatFind.RowHighlight?) {
        guard let find else { return }
        let plain = text.string
        for (occurrence, range) in ChatFind.ranges(of: find.query, in: plain).enumerated() {
            let lower = plain.index(plain.startIndex, offsetBy: range.lowerBound)
            let upper = plain.index(lower, offsetBy: range.count)
            let isCurrent = find.current?.segment == segment && find.current?.occurrence == occurrence
            let nsRange = NSRange(lower..<upper, in: plain)
            text.addAttribute(.backgroundColor, value: NSColor(isCurrent ? ChatFind.currentColor : ChatFind.highlightColor), range: nsRange)
            text.addAttribute(.foregroundColor, value: NSColor.black, range: nsRange)
        }
    }

    /// The text Cmd-C writes for `range`: the string with each list marker replaced by its `copyText`.
    static func plainText(of text: NSAttributedString, in range: NSRange) -> String {
        var result = ""
        // Enumerating this one attribute keeps a marker's tab, symbol and tab together as a single run.
        text.enumerateAttribute(copyText, in: range) { value, runRange, _ in
            result += (value as? String) ?? (text.string as NSString).substring(with: runRange)
        }
        return result
    }
}

// MARK: - View

/// A selectable, read-only text view for a run of text blocks. It reports the height its text needs at a width.
struct MarkdownTextView: NSViewRepresentable {
    let content: NSAttributedString
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> ChatTextView {
        let view = ChatTextView.make()
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: ChatTextView, context: Context) {
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        view.setContent(content)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ChatTextView, context: Context) -> CGSize? {
        // SwiftUI can measure before it updates a view it reuses, so measure the content this struct holds.
        view.setContent(content)
        return view.fittingSize(forWidth: proposal.width)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            if url.isFileURL {
                _ = FilePathLinks.handle(url)
            } else {
                NSWorkspace.shared.open(url)
            }
            return true
        }
    }
}

final class ChatTextView: NSTextView {
    private var version = 0
    private var measured: (width: CGFloat?, version: Int, size: CGSize)?

    /// A TextKit 2 text view with no insets, so its text lines up with the SwiftUI views around it.
    static func make() -> ChatTextView {
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        let layout = NSTextLayoutManager()
        layout.textContainer = container
        let content = NSTextContentStorage()
        content.addTextLayoutManager(layout)
        let view = ChatTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.allowsUndo = false
        view.usesFontPanel = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainerInset = .zero
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        view.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        return view
    }

    /// Replaces the text when it changed, and keeps the selection while a reply streams in.
    func setContent(_ content: NSAttributedString) {
        guard let storage = textStorage, !storage.isEqual(to: content) else { return }
        let selection = selectedRange()
        storage.setAttributedString(content)
        if selection.length > 0, NSMaxRange(selection) <= storage.length { setSelectedRange(selection) }
        version += 1
        needsDisplay = true
    }

    /// The size the text needs at `width`. A nil width means no limit. Cached, because SwiftUI asks often.
    func fittingSize(forWidth width: CGFloat?) -> CGSize {
        if let measured, measured.width == width, measured.version == version { return measured.size }
        guard let layout = textLayoutManager, let container = textContainer else { return .zero }
        container.size = NSSize(width: width ?? 100_000, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: layout.documentRange)
        let used = layout.usageBoundsForTextContainer
        // Takes the whole proposed width: the used width leaves out the indents, so a narrower view would clip.
        let size = CGSize(width: width ?? ceil(used.maxX), height: ceil(used.height))
        measured = (width, version, size)
        return size
    }

    /// The pasteboard gets the text with list markers as markdown, not the bullets and tabs that are drawn.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let wrote = super.writeSelection(to: pboard, types: types)
        guard wrote, let storage = textStorage else { return wrote }
        if !(pboard.types ?? []).contains(.string) { pboard.addTypes([.string], owner: nil) }
        pboard.setString(MarkdownText.plainText(of: storage, in: selectedRange()), forType: .string)
        return true
    }

    /// The right-click menu belongs to the message row around this view, not to the text.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func rightMouseDown(with event: NSEvent) { nextResponder?.rightMouseDown(with: event) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawQuoteBars()
    }

    private func drawQuoteBars() {
        guard let layout = textLayoutManager, let content = layout.textContentManager, let storage = textStorage else { return }
        storage.enumerateAttribute(MarkdownText.quoteBar, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil,
                  let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { return }
            var top = CGFloat.greatestFiniteMagnitude
            var bottom: CGFloat = 0
            layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                top = min(top, frame.minY)
                bottom = max(bottom, frame.maxY)
                return true
            }
            guard bottom > top else { return }
            let bar = NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y + top, width: 3, height: bottom - top)
            NSColor.secondaryLabelColor.withAlphaComponent(0.4).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
