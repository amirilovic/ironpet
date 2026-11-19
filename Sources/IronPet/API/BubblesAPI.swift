import Combine
import Foundation

struct BubbleActionInfo: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    /// `primary`, `normal` or `destructive`.
    var style: String
}

struct BubbleLineInfo: Codable, Equatable, Identifiable {
    var id: String
    var symbol: String
    var text: String
}

/// A bubble as a client that cannot draw SwiftUI sees it.
struct BubbleInfo: Codable, Equatable, Identifiable {
    var id: String
    var symbol: String
    var title: String
    var subtitle: String?
    var body: String?
    var lines: [BubbleLineInfo]
    var actions: [BubbleActionInfo]
    var expires: Date?
    /// Whether clicking the bubble itself does something.
    var tappable: Bool
}

/// Presses one control of a bubble. With neither `action` nor `line`, it presses the bubble itself.
struct PressBubbleRequest: Codable, Equatable {
    var bubble: String
    var action: String?
    var line: String?
}

/// The bubbles beside the pet. A button press goes through the table of actions the bubbles registered, so any client can
/// press one, not only the view that draws it.
@MainActor
final class BubblesAPI: ObservableObject {
    private let store: BubbleStore
    private var forwarding: AnyCancellable?

    init(store: BubbleStore) {
        self.store = store
        forwarding = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// The bubbles for the view that draws them. A bubble can carry live SwiftUI content, so a client that cannot draw it uses `list`.
    var bubbles: [Bubble] { store.bubbles }
    var petOnLeft: Bool { store.petOnLeft }

    func setPetOnLeft(_ left: Bool) { if store.petOnLeft != left { store.petOnLeft = left } }

    func setHovering(_ on: Bool) { store.setHovering(on) }

    func list() -> [BubbleInfo] {
        store.bubbles.map { bubble in
            BubbleInfo(id: bubble.id, symbol: bubble.symbol, title: bubble.title, subtitle: bubble.subtitle, body: bubble.body,
                       lines: bubble.lines.map { BubbleLineInfo(id: $0.id.uuidString, symbol: $0.symbol, text: $0.text) },
                       actions: bubble.actions.map { BubbleActionInfo(id: $0.id.uuidString, title: $0.title, style: Self.name($0.style)) },
                       expires: bubble.expires, tappable: bubble.onTap != nil)
        }
    }

    func press(_ request: PressBubbleRequest) throws {
        guard let bubble = store.bubbles.first(where: { $0.id == request.bubble }) else {
            throw APIError.notFound("no bubble with id \"\(request.bubble)\"")
        }
        if let id = request.action {
            guard let action = bubble.actions.first(where: { $0.id.uuidString == id }) else { throw APIError.notFound("no action \"\(id)\" on this bubble") }
            action.run()
        } else if let id = request.line {
            guard let line = bubble.lines.first(where: { $0.id.uuidString == id }) else { throw APIError.notFound("no line \"\(id)\" on this bubble") }
            line.run()
        } else {
            guard let tap = bubble.onTap else { throw APIError.invalid("this bubble has no action") }
            tap()
        }
        store.dismiss(bubble.id)
    }

    /// Closes a bubble without pressing anything.
    func dismiss(_ id: String) throws {
        guard store.bubbles.contains(where: { $0.id == id }) else { throw APIError.notFound("no bubble with id \"\(id)\"") }
        store.dismiss(id)
    }

    private static func name(_ style: Bubble.Action.Style) -> String {
        switch style {
        case .primary: return "primary"
        case .normal: return "normal"
        case .destructive: return "destructive"
        }
    }
}
