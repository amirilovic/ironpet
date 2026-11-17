import AppKit

/// Decides what a paste into the chat does before the text field sees it. A multi-megabyte string
/// freezes SwiftUI layout as soon as the field receives it, so large text has to be diverted first.
@MainActor
enum PasteIntake {
    enum Action: Equatable {
        /// The text field handles the paste.
        case field
        /// An image or image file on the pasteboard becomes a PNG attachment.
        case image
        /// Text over the paste limits (Settings > General) becomes a `pasted-text.txt` attachment.
        case largeText(String)
    }

    static func decide(_ pasteboard: NSPasteboard, limits: PasteLimits? = nil) -> Action {
        let limits = limits ?? .current
        if ImageIntake.decide(pasteboard) != .text { return .image }
        if let text = pasteboard.string(forType: .string), limits.exceeds(text) { return .largeText(text) }
        return .field
    }

    /// The attachments a paste produces. An empty result means the text field should handle the paste.
    static func importPaste(_ pasteboard: NSPasteboard,
                            imageDirectory: URL = ScreenCapture.directory,
                            textDirectory: URL = FileIntake.directory,
                            limits: PasteLimits? = nil) -> [URL] {
        switch decide(pasteboard, limits: limits) {
        case .field: return []
        case .image: return ImageIntake.importPaste(pasteboard, into: imageDirectory)
        case .largeText(let text): return DraftPolicy.saveAsAttachment(text, into: textDirectory).map { [$0] } ?? []
        }
    }
}
