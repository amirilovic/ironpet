import Foundation

@MainActor
final class BubbleStore: ObservableObject {
    @Published private(set) var bubbles: [Bubble] = [] {
        didSet {
            // Dismissal, expiry and the limit all remove bubbles; a client that saw `bubble.shown` needs to hear about each.
            let kept = Set(bubbles.map(\.id))
            for gone in oldValue.map(\.id) where !kept.contains(gone) { events?.publish(.bubbleDismissed, id: gone) }
        }
    }
    /// Which side of the bubbles the pet is on, so the tail points at him.
    @Published var petOnLeft = false
    private var hovering = false
    static let limit = 4
    /// Called when a bubble goes away through `dismiss`, whether the user closed it or code did.
    var onDismissed: ((String) -> Void)?
    /// When each id was last shown, for the past hour, so a summary can tell what came up while the user was away.
    private(set) var shownAt: [String: Date] = [:]
    var now: () -> Date = Date.init
    /// Where `bubble.shown` and `bubble.dismissed` are published for API clients, with the bubble's id.
    weak var events: APIEventBus?

    func show(_ bubble: Bubble) {
        defer { events?.publish(.bubbleShown, id: bubble.id) }
        let now = now()
        let onScreen = Set(bubbles.map(\.id))
        shownAt = shownAt.filter { onScreen.contains($0.key) || now.timeIntervalSince($0.value) < 3600 }
        shownAt[bubble.id] = now
        var next = bubbles.filter { $0.id != bubble.id }
        next.append(bubble)
        while next.count > Self.limit {
            // The brief and recap stay until midnight, so they are usually the oldest with an expiry; pass over them first.
            let shortLived = next.indices.dropLast().first { next[$0].expires != nil && !next[$0].id.hasPrefix(WelcomeBack.digestPrefix) }
            next.remove(at: shortLived ?? next.firstIndex { $0.expires != nil } ?? next.firstIndex { $0.content == nil } ?? 0)
        }
        bubbles = next
    }

    /// The last time a bubble whose id starts with `prefix` was shown, within the past hour.
    func lastShown(prefix: String) -> Date? {
        shownAt.filter { $0.key.hasPrefix(prefix) }.values.max()
    }

    func dismiss(_ id: String) {
        guard bubbles.contains(where: { $0.id == id }) else { return }
        bubbles.removeAll { $0.id == id }
        onDismissed?(id)
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
