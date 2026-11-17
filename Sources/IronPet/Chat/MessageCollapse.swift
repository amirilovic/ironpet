import Foundation

/// Decides how much of a long user message the transcript renders. A pasted crash report of 60 KB
/// otherwise goes through SwiftUI text layout in full on every transcript update.
enum MessageCollapse {
    /// A message collapses when it has more than this many characters or lines.
    static let maxCharacters = 1_500
    static let maxLines = 30
    /// A collapsed message shows at most this many characters and lines of its start.
    static let previewCharacters = 600
    static let previewLines = 12

    struct Preview: Equatable {
        let text: String
        /// Counted in UTF-16 units, which is O(1) for the text length. It matches the character count for plain text.
        let hiddenCharacters: Int
    }

    /// The visible start of `text`, or nil when the message is short enough to render in full.
    static func preview(of text: String) -> Preview? {
        // Bounded scans, so the check stays cheap for multi-megabyte text.
        let head = text.prefix(maxCharacters + 1)
        let overCharacters = head.count > maxCharacters
        // Over the line limit means more than maxLines lines, so text must follow the maxLines-th
        // line break. A single trailing line break does not add a line.
        var overLines = false
        var newlines = 0
        for index in head.indices where head[index].isNewline {
            newlines += 1
            if newlines == maxLines {
                overLines = text.index(after: index) < text.endIndex
                break
            }
        }
        guard overCharacters || overLines else { return nil }

        var cut = text.prefix(previewCharacters)
        if cut.count == previewCharacters, !text.dropFirst(previewCharacters).isEmpty {
            // Back up to a line break, else a space, unless that would discard most of the preview.
            let floor = previewCharacters / 2
            if let index = cut.lastIndex(where: \.isNewline), cut.distance(from: cut.startIndex, to: index) >= floor {
                cut = cut[..<index]
            } else if let index = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: index) >= floor {
                cut = cut[..<index]
            }
        }
        // Limit to previewLines lines.
        var lines = 0
        if let index = cut.firstIndex(where: { if $0.isNewline { lines += 1 }; return lines >= previewLines }) {
            cut = cut[..<index]
        }
        let shown = String(cut)
        return Preview(text: shown, hiddenCharacters: max(0, text.utf16.count - shown.utf16.count))
    }
}
