import AppKit
import SwiftUI

/// Finds where the links of a message sit, so the chat can show the pointing hand over them. SwiftUI's `Text` does
/// not report link positions, so this lays the same string out with TextKit at the same width and font.
enum LinkLayout {
    /// The text as TextKit lays it out: the base font everywhere, monospace for code spans, bold for strong spans.
    static func attributed(_ text: AttributedString, size: CGFloat, lineSpacing: CGFloat, weight: NSFont.Weight = .regular) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        for run in text.runs {
            var font = NSFont.systemFont(ofSize: size, weight: weight)
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: size, weight: weight) }
                if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return result
    }

    /// One rectangle per line fragment of each link, in a top-left coordinate space of the given width.
    static func linkRects(in text: NSAttributedString, width: CGFloat) -> [CGRect] {
        guard width > 0, text.length > 0 else { return [] }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var rects: [CGRect] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in rects.append(rect) }
        }
        return rects
    }
}

/// An invisible layer over a `Text`. It lets every click and drag through, so selection still works, and adds
/// cursor rects over the links. AppKit tracks cursor rects itself, so moving the mouse does not re-render any row.
private struct LinkCursorOverlay: NSViewRepresentable {
    let text: AttributedString
    let size: CGFloat
    let lineSpacing: CGFloat
    let weight: NSFont.Weight

    func makeNSView(context: Context) -> CursorView { CursorView() }

    func updateNSView(_ view: CursorView, context: Context) {
        let attributed = LinkLayout.attributed(text, size: size, lineSpacing: lineSpacing, weight: weight)
        guard view.content?.isEqual(to: attributed) != true else { return }
        view.content = attributed
    }

    final class CursorView: NSView {
        var content: NSAttributedString? { didSet { invalidate() } }
        private var rects: [CGRect] = []
        private var rectsWidth: CGFloat = 0

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if newSize.width != rectsWidth { invalidate() }
        }

        private func invalidate() {
            rects = []
            rectsWidth = 0
            window?.invalidateCursorRects(for: self)
        }

        override func resetCursorRects() {
            guard let content, content.length > 0 else { return }
            if rectsWidth != bounds.width {
                rects = LinkLayout.linkRects(in: content, width: bounds.width)
                rectsWidth = bounds.width
            }
            for rect in rects { addCursorRect(rect.intersection(bounds), cursor: .pointingHand) }
        }
    }
}

extension View {
    /// The pointing hand over the links in `text`, which this view shows at `size` points.
    @ViewBuilder
    func linkCursor(_ text: AttributedString, size: CGFloat, lineSpacing: CGFloat = 0, weight: NSFont.Weight = .regular) -> some View {
        if text.runs.contains(where: { $0.link != nil }) {
            overlay { LinkCursorOverlay(text: text, size: size, lineSpacing: lineSpacing, weight: weight) }
        } else {
            self
        }
    }
}
