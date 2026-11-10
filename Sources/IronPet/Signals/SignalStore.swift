import Foundation

/// Something outside the agents that deserves a look: CI, reviews, production errors.
struct Signal: Identifiable, Equatable {
    enum Kind: String {
        case ciFailed, ciPassed, approved, changesRequested, reviewRequested, sentryNew, sentryEscalating

        var label: String {
            switch self {
            case .ciFailed: return "CI failed"
            case .ciPassed: return "CI passed"
            case .approved: return "Approved"
            case .changesRequested: return "Changes requested"
            case .reviewRequested: return "Review requested"
            case .sentryNew: return "New error"
            case .sentryEscalating: return "Error spiking"
            }
        }

        var symbol: String {
            switch self {
            case .ciFailed: return "xmark.octagon.fill"
            case .ciPassed: return "checkmark.seal.fill"
            case .approved: return "hand.thumbsup.fill"
            case .changesRequested: return "exclamationmark.bubble.fill"
            case .reviewRequested: return "eye.fill"
            case .sentryNew, .sentryEscalating: return "ant.fill"
            }
        }

        var isGitHub: Bool {
            switch self {
            case .sentryNew, .sentryEscalating: return false
            case .ciFailed, .ciPassed, .approved, .changesRequested, .reviewRequested: return true
            }
        }

        var mood: PetMood {
            switch self {
            case .ciFailed, .sentryNew, .sentryEscalating: return .failed
            case .changesRequested, .reviewRequested: return .needsInput
            case .ciPassed, .approved: return .done
            }
        }

        /// Prompt for "Ask Ghost", so the chat can pick up from the alert.
        func prompt(for signal: Signal) -> String? {
            switch self {
            case .ciFailed:
                return "CI is failing on \(signal.url). Use `gh pr checks` and the failing job's logs to find out why, and propose a fix."
            case .changesRequested:
                return "Changes were requested on \(signal.url). Read the review comments with `gh pr view --comments` and summarize what I need to change."
            case .reviewRequested:
                return "I was asked to review \(signal.url). Summarize what the PR changes and anything risky I should look at."
            case .sentryNew, .sentryEscalating:
                return "Investigate this Sentry issue: \(signal.title) (\(signal.url)). Use the Sentry MCP tools to read the issue details, "
                    + "stack trace and recent events, then find the likely cause in this codebase and propose a fix."
            case .ciPassed, .approved:
                return nil
            }
        }
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let url: URL
    var date = Date()
}

@MainActor
final class SignalStore: ObservableObject {
    @Published private(set) var signals: [Signal] = []

    /// Called for signals that should notify (not for state found on the first poll).
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
        guard let top = signals.map(\.kind.mood).max(by: { ranked.firstIndex(of: $0)! < ranked.firstIndex(of: $1)! }) else { return nil }
        return (top, signals.filter { $0.kind.mood == top }.count)
    }
}
