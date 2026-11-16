import AppKit
import SwiftUI

/// What the transcript's scroll view reports for following and the jump button.
struct ScrollMetrics: Equatable {
    var distanceFromBottom: CGFloat
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
}

/// Marks scrolls the app made itself, so the offset change they cause is not taken for the reader's.
final class ScrollActivity {
    private var programmaticUntil = Date.distantPast

    func noteProgrammaticScroll() { programmaticUntil = Date().addingTimeInterval(0.3) }

    var isProgrammatic: Bool { Date() < programmaticUntil }
}

/// Reports the metrics of the NSScrollView this view sits inside, once per change, on the next main queue turn.
/// A bounds change with the same content and viewport sizes is the reader scrolling (wheel, trackpad, scrollbar,
/// coasting), unless the app just scrolled itself. SwiftUI's own scroll-geometry callbacks need macOS 15.
struct ScrollObserver: NSViewRepresentable {
    let activity: ScrollActivity
    let onChange: (ScrollMetrics, _ userDriven: Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = Anchor()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.activity = activity
        context.coordinator.onChange = onChange
    }

    func makeCoordinator() -> Coordinator { Coordinator(activity: activity, onChange: onChange) }

    private final class Anchor: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: enclosingScrollView)
        }
    }

    @MainActor
    final class Coordinator {
        var activity: ScrollActivity
        var onChange: (ScrollMetrics, Bool) -> Void
        private var last: ScrollMetrics?
        private var observers: [NSObjectProtocol] = []

        init(activity: ScrollActivity, onChange: @escaping (ScrollMetrics, Bool) -> Void) {
            self.activity = activity
            self.onChange = onChange
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        func attach(to scroll: NSScrollView?) {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let scroll, let document = scroll.documentView else { return }
            scroll.contentView.postsBoundsChangedNotifications = true
            document.postsFrameChangedNotifications = true
            let names: [(Notification.Name, AnyObject)] = [
                (NSView.boundsDidChangeNotification, scroll.contentView),
                (NSView.frameDidChangeNotification, document),
            ]
            for (name, object) in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) {
                    [weak self, weak scroll] _ in
                    MainActor.assumeIsolated { if let scroll { self?.measure(scroll) } }
                })
            }
            measure(scroll)
        }

        private func measure(_ scroll: NSScrollView) {
            guard let document = scroll.documentView else { return }
            let visible = scroll.contentView.bounds
            let top = document.isFlipped ? visible.minY : document.bounds.maxY - visible.maxY
            let metrics = ScrollMetrics(distanceFromBottom: document.bounds.height - visible.height - top,
                                        contentHeight: document.bounds.height, viewportHeight: visible.height)
            guard metrics != last else { return }
            let last0 = last
            let sameSizes = last.map { $0.contentHeight == metrics.contentHeight && $0.viewportHeight == metrics.viewportHeight } ?? false
            let moved = last.map { abs($0.distanceFromBottom - metrics.distanceFromBottom) > 0.5 } ?? false
            last = metrics
            // The app's own scrolls go toward the end. Moving away from it is the reader, even while streaming
            // keeps renewing the programmatic window.
            let awayFromEnd = last0.map { metrics.distanceFromBottom > $0.distanceFromBottom + 0.5 } ?? false
            let userDriven = sameSizes && moved && (!activity.isProgrammatic || awayFromEnd)
            // SwiftUI may be mid-layout here; writing state now would invalidate that layout again.
            DispatchQueue.main.async { [weak self] in self?.onChange(metrics, userDriven) }
        }
    }
}
