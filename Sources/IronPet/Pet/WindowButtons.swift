import AppKit

extension NSWindow {
    /// Hides the close, minimize and zoom buttons. AppKit on recent macOS re-shows them after
    /// layout, key changes and appearance changes, so call this again from `update()`.
    func hideStandardWindowButtons() {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = standardWindowButton(type), !button.isHidden { button.isHidden = true }
        }
    }
}
