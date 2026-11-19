import AppKit

/// Reads the text selected in a transcript message. SwiftUI's selectable `Text` does not expose its selection, so the
/// probe sends the responder chain the same `copy:` that Cmd-C sends, reads what it put on the pasteboard, and puts the
/// user's earlier pasteboard contents back.
@MainActor
enum SelectionProbe {
    /// The selected text, or nil when nothing is selected or the selection is in a text field such as the composer.
    static func selectedText(keepOnPasteboard: Bool = false) -> String? {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor { return nil }
        // A transcript text view hands over its selection directly, so the read does not depend on `copy:` and the pasteboard.
        if let view = NSApp.keyWindow?.firstResponder as? ChatTextView { return selectedText(in: view) }
        let board = NSPasteboard.general
        let before = board.changeCount
        let saved = snapshot(board)
        guard NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil), board.changeCount != before else { return nil }
        let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keepOnPasteboard { restore(saved, to: board) }
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// The selection in a transcript text view as the pasteboard would get it, or nil when it is empty.
    static func selectedText(in view: ChatTextView) -> String? {
        guard let storage = view.textStorage else { return nil }
        let range = view.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return nil }
        let text = MarkdownText.plainText(of: storage, in: range).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func snapshot(_ board: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ saved: [[(NSPasteboard.PasteboardType, Data)]], to board: NSPasteboard) {
        board.clearContents()
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }
}
