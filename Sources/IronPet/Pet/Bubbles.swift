import AppKit
import Combine
import SwiftUI

/// Something Ghost says next to himself: agent updates, approvals, alerts, reminders.
struct Bubble: Identifiable {
    struct Action: Identifiable {
        enum Style { case primary, normal, destructive }
        let id = UUID()
        let title: String
        var style: Style = .normal
        let run: () -> Void
    }

    /// Showing a bubble with the same id replaces the old one.
    let id: String
    var symbol: String
    var tint: Color
    var title: String
    var subtitle: String?
    var body: String?
    var actions: [Action] = []
    var onTap: (() -> Void)?
    /// nil stays until answered or closed.
    var expires: Date?
}

@MainActor
final class BubbleStore: ObservableObject {
    @Published private(set) var bubbles: [Bubble] = []
    /// Which side of the bubbles the pet is on, so the tail points at him.
    @Published var petOnLeft = false
    private var hovering = false
    static let limit = 4

    func show(_ bubble: Bubble) {
        var next = bubbles.filter { $0.id != bubble.id }
        next.append(bubble)
        while next.count > Self.limit {
            next.remove(at: next.firstIndex { $0.expires != nil } ?? 0)
        }
        bubbles = next
    }

    func dismiss(_ id: String) {
        bubbles.removeAll { $0.id == id }
    }

    /// Bubbles don't expire under the pointer, and get a few more seconds after it leaves.
    func setHovering(_ on: Bool) {
        hovering = on
        guard !on else { return }
        let soon = Date().addingTimeInterval(4)
        bubbles = bubbles.map { b in
            var b = b
            if let e = b.expires, e < soon { b.expires = soon }
            return b
        }
    }

    func sweep(now: Date = Date()) {
        guard !hovering else { return }
        let kept = bubbles.filter { $0.expires.map { $0 > now } ?? true }
        if kept.count != bubbles.count { bubbles = kept }
    }
}

/// Transparent, non-activating panel beside the pet that holds the bubble stack.
@MainActor
final class BubblePanel {
    let panel: NSPanel
    private let store: BubbleStore
    private let host: NSHostingView<BubbleStackView>
    private var anchor: CGRect = .zero
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?

    /// Hidden while the chat or agents window is open; bubbles wait until it closes.
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
        host = FirstMouseHostingView(rootView: BubbleStackView(store: store))
        panel.contentView = host
        store.$bubbles
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.update()
                // SwiftUI lays out the new bubbles a moment later; size the panel again once it has.
                DispatchQueue.main.async { self?.update() }
            }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak store] _ in
            MainActor.assumeIsolated { store?.sweep() }
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

struct BubbleStackView: View {
    @ObservedObject var store: BubbleStore
    static let padding: CGFloat = 14
    static let tailFromBottom: CGFloat = padding + 20

    var body: some View {
        VStack(alignment: store.petOnLeft ? .leading : .trailing, spacing: 8) {
            ForEach(store.bubbles) { bubble in
                BubbleView(bubble: bubble,
                           tail: bubble.id == store.bubbles.last?.id ? (store.petOnLeft ? .leading : .trailing) : nil,
                           dismiss: { store.dismiss(bubble.id) })
                    .transition(.asymmetric(insertion: .scale(scale: 0.85, anchor: store.petOnLeft ? .bottomLeading : .bottomTrailing)
                                                .combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .padding(Self.padding)
        .animation(.spring(duration: 0.3, bounce: 0.25), value: store.bubbles.map(\.id))
        .onHover { store.setHovering($0) }
    }
}

private struct BubbleView: View {
    let bubble: Bubble
    let tail: HorizontalEdge?
    let dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: bubble.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(bubble.tint)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(bubble.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button(action: dismiss) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
                    .help("Close")
                }
                if let subtitle = bubble.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let text = bubble.body, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !bubble.actions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(bubble.actions) { action in button(action) }
                    }
                    .controlSize(.small)
                    .padding(.top, 5)
                }
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(BubbleShape(tail: tail).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(BubbleShape(tail: tail).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let tap = bubble.onTap else { return }
            tap()
            dismiss()
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder private func button(_ action: Bubble.Action) -> some View {
        let run = { action.run(); dismiss() }
        switch action.style {
        case .primary: Button(action.title, action: run).buttonStyle(.borderedProminent)
        case .destructive: Button(action.title, role: .destructive, action: run).buttonStyle(.bordered)
        case .normal: Button(action.title, action: run).buttonStyle(.bordered)
        }
    }
}

/// Rounded rectangle with a small tail near the bottom of one side, pointing at the pet.
private struct BubbleShape: Shape {
    let tail: HorizontalEdge?

    func path(in rect: CGRect) -> Path {
        let body = Path(roundedRect: rect, cornerRadius: 14)
        guard let tail else { return body }
        let tipY = rect.maxY - 20
        var t = Path()
        if tail == .leading {
            t.move(to: CGPoint(x: rect.minX + 1, y: tipY - 9))
            t.addLine(to: CGPoint(x: rect.minX - 9, y: tipY))
            t.addLine(to: CGPoint(x: rect.minX + 1, y: tipY + 7))
        } else {
            t.move(to: CGPoint(x: rect.maxX - 1, y: tipY - 9))
            t.addLine(to: CGPoint(x: rect.maxX + 9, y: tipY))
            t.addLine(to: CGPoint(x: rect.maxX - 1, y: tipY + 7))
        }
        t.closeSubpath()
        return body.union(t)
    }
}
