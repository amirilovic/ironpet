import ApplicationServices
import Foundation

/// What the user has to approve before an agent acts, whatever the app. The words are generic verbs, never the names of apps or of
/// their buttons: a button called "Send" in any app asks, and no app is trusted to skip the question.
enum DesktopSafety {
    private static let pattern = try! NSRegularExpression(
        pattern: #"\b(send|sends|sending|pay|pays|paying|payment|delete|deletes|deleting|submit|submits|submitting|buy|buys|buying|purchase|purchases|check ?out|transfer|transfers)\b"#,
        options: .caseInsensitive)

    /// The verb that makes `text` need approval, or nil.
    static func riskyVerb(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range), let found = Range(match.range, in: text) else { return nil }
        return text[found].lowercased()
    }

    /// Why an action needs the user's approval, or nil when it does not. `element` is what the element shows (its name, and its value
    /// unless the user types into it); `window` is the window title.
    static func approvalReason(element: [String], window: String?) -> String? {
        for text in element { if let verb = riskyVerb(in: text) { return "the element says \"\(verb)\"" } }
        if let window, let verb = riskyVerb(in: window) { return "the window title says \"\(verb)\"" }
        return nil
    }
}

extension DesktopSafety {
    /// Key codes of q and w, which with Command quit the app or close the window.
    private static let quitCode: CGKeyCode = 12, closeCode: CGKeyCode = 13

    /// Why a key press needs the user's approval, or nil. Cmd+Return, and Cmd with q or w, always ask: they send, quit or close in
    /// most apps. Any other press that holds Command or is Return asks when the focused window or element says send, pay, delete,
    /// submit or buy. A plain letter, Tab, Escape or an arrow never asks. `element` is what the focused element shows.
    static func keyApprovalReason(_ stroke: DesktopKeyStroke, element: [String], window: String?) -> String? {
        if stroke.hasCommand {
            if stroke.isReturn { return "Cmd+Return sends or submits in most apps" }
            if stroke.keyCode == quitCode { return "Cmd+Q quits the app" }
            if stroke.keyCode == closeCode { return "Cmd+W closes the window" }
        }
        guard stroke.hasCommand || stroke.isReturn else { return nil }
        return approvalReason(element: element, window: window).map { "\($0) and the key can trigger it" }
    }
}

/// What the user was asked about an action.
struct DesktopApproval: Equatable {
    var id = UUID()
    var title: String
    var detail: String
}

/// One action an agent took or tried, as the log keeps it.
struct DesktopActionRecord: Equatable {
    enum Outcome: String { case done, failed, declined, refused }

    var at: Date
    var app: String
    var window: String
    var role: String
    var name: String
    var action: String
    var outcome: Outcome
    /// Why it failed, was refused or needed approval.
    var note: String = ""
}

extension ActivityEvent.Kind {
    static let desktopAction = ActivityEvent.Kind("desktop.action")
}

extension ActivityEvent {
    enum DesktopKey {
        static let app = "app", window = "window", role = "role", name = "name", action = "action", outcome = "outcome", note = "note"
    }

    /// One desktop action an agent took. The element's name is cut like any other activity text.
    static func desktopAction(_ record: DesktopActionRecord) -> ActivityEvent {
        let name = record.name.isEmpty ? record.role : "\(record.role) \"\(clamp(record.name, 60))\""
        let target = name.isEmpty ? "" : " \(name)"
        return ActivityEvent(at: record.at, kind: .desktopAction, ref: record.app, title: "\(record.action)\(target) in \(record.app)",
                             detail: record.note,
                             extra: [DesktopKey.app: record.app, DesktopKey.window: clamp(record.window, 80), DesktopKey.role: record.role,
                                     DesktopKey.name: clamp(record.name, 80), DesktopKey.action: record.action,
                                     DesktopKey.outcome: record.outcome.rawValue, DesktopKey.note: clamp(record.note, 120)])
    }
}

/// Asks the user through a bubble and waits for the answer. No answer within `timeout` is a no.
@MainActor
final class DesktopApprovals {
    private let present: (DesktopApproval, @escaping (Bool) -> Void) -> Void
    private let dismiss: (DesktopApproval) -> Void
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 120, present: @escaping (DesktopApproval, @escaping (Bool) -> Void) -> Void, dismiss: @escaping (DesktopApproval) -> Void) {
        self.timeout = timeout
        self.present = present
        self.dismiss = dismiss
    }

    func ask(_ request: DesktopApproval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var answered = false
            let finish: (Bool) -> Void = { [dismiss] answer in
                guard !answered else { return }
                answered = true
                if !answer { dismiss(request) }
                continuation.resume(returning: answer)
            }
            present(request, finish)
            Task { @MainActor [timeout] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                finish(false)
            }
        }
    }
}
