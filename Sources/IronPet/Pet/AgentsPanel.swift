import AppKit
import SwiftUI

/// The agents and alerts window. A panel rather than an NSPopover so it always stays on screen,
/// even when the pet sits against a screen edge. Closes on Esc or when it loses focus.
final class AgentsPanel: NSPanel {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 460, height: 530),
                   styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isMovable = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = true

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { close() }

    override func resignKey() {
        super.resignKey()
        close()
    }

    /// Below the pet when there is room, otherwise above it; always clamped to the pet's screen.
    /// A fresh root view each time resets the view's state (which tab opens first).
    func show<Content: View>(_ content: Content, near anchor: CGRect) {
        host.rootView = AnyView(content.ignoresSafeArea().id(UUID()))
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 4)
        if origin.y < screen.minY { origin.y = anchor.maxY + 4 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        setFrame(CGRect(origin: origin, size: size), display: true)
        makeKeyAndOrderFront(nil)
    }
}
