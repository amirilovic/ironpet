import Foundation

/// An open item that deserves a look: CI that failed, a review waiting on you, a production error. Automations create
/// them with `alert` actions. The alerts list shows them until they are dismissed or the automation resolves them,
/// and the most urgent one sets Ghost's mood and badge.
struct Signal: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    /// nil for an alert with nothing to open.
    let url: URL?
    var date = Date()
    /// The line above the title, such as "CI failed".
    var label: String
    var symbol: String
    var mood: PetMood
    /// Prompt for "Ask Ghost", so the chat can pick up from the alert.
    var ask: String?
}

@MainActor
final class SignalStore: ObservableObject {
    @Published private(set) var signals: [Signal] = []

    /// Called for signals that should notify (not for state found on the first run).
    var onNew: ((Signal) -> Void)?

    func add(_ signal: Signal, notify: Bool) {
        signals.removeAll { $0.id == signal.id }
        signals.insert(signal, at: 0)
        if signals.count > 50 { signals.removeLast(signals.count - 50) }
        if notify { onNew?(signal) }
    }

    func dismiss(_ id: String) {
        signals.removeAll { $0.id == id }
    }

    func removeAll(where shouldRemove: (Signal) -> Bool) {
        signals.removeAll(where: shouldRemove)
    }

    func dismissAll() {
        signals = []
    }

    /// Most urgent mood among open signals and how many share it.
    var summary: (mood: PetMood, count: Int)? {
        let ranked: [PetMood] = [.done, .failed, .needsInput]
        guard let top = signals.map(\.mood).max(by: { ranked.firstIndex(of: $0)! < ranked.firstIndex(of: $1)! }) else { return nil }
        return (top, signals.filter { $0.mood == top }.count)
    }
}
