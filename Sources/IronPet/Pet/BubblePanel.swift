import AppKit
import Combine
import SwiftUI

/// Transparent, non-activating panel beside the pet that holds the bubble stack.
@MainActor
final class BubblePanel {
    let panel: NSPanel
    private let store: BubbleStore
    private let host: NSHostingView<BubbleStackView>
    private var anchor: CGRect = .zero
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?

    /// Hidden while the chat or a main section of the ironpet window is open; bubbles wait until it closes.
    var isSuppressed = false {
        didSet { if isSuppressed != oldValue { update() } }
    }

    init(store: BubbleStore) {
        self.store = store
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        host = FirstMouseHostingView(rootView: BubbleStackView(api: BubblesAPI(store: store)))
        panel.contentView = host
        store.$bubbles
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.update()
                // SwiftUI lays out the new bubbles a moment later; size the panel again once it has.
                DispatchQueue.main.async { self?.update() }
            }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak store] _ in
            MainActor.assumeIsolated {
                store?.sweep()
                // A bubble with live content changes height without the stack changing.
                if let self, self.panel.isVisible, abs(self.host.fittingSize.height - self.panel.frame.height) > 0.5 { self.update() }
            }
        }
    }

    func follow(_ petFrame: CGRect) {
        guard petFrame != anchor else { return }
        anchor = petFrame
        update()
    }

    private func update() {
        guard !store.bubbles.isEmpty, !isSuppressed, anchor != .zero else {
            panel.orderOut(nil)
            return
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let petOnLeft = anchor.midX < screen.midX
        if store.petOnLeft != petOnLeft { store.petOnLeft = petOnLeft }
        let size = host.fittingSize
        // The tail tip sits `tailFromBottom` above the panel's bottom edge; aim it at the pet's head.
        var origin = CGPoint(x: petOnLeft ? anchor.maxX - 22 : anchor.minX - size.width + 22,
                             y: anchor.minY + anchor.height * 0.62 - BubbleStackView.tailFromBottom)
        origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }
}

/// Buttons in a panel that never becomes key must respond to the first click.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
