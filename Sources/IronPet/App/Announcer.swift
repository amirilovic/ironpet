import AppKit
import SwiftUI

/// Everything ironpet announces goes out as a bubble next to Ghost, and optionally as a macOS notification too.
@MainActor
final class Announcer {
    private static let systemKey = "notifications.system"

    let bubbles = BubbleStore()
    let notifier: Notifier

    var openSession: (String) -> Void = { _ in }
    var openChat: () -> Void = {}
    var ask: (String) -> Void = { _ in }
    var decide: (UUID, Bool) -> Void = { _, _ in }
    var automationAction: (_ ids: [String], _ snooze: Bool) -> Void = { _, _ in }

    var alsoSystemNotifications: Bool {
        get { UserDefaults.standard.bool(forKey: Self.systemKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.systemKey) }
    }

    init(notifier: Notifier) {
        self.notifier = notifier
        notifier.onOpen = { [weak self] id in self?.openSession(id) }
        notifier.onOpenChat = { [weak self] in self?.openChat() }
        notifier.onApprovalAction = { [weak self] id, allow in self?.decide(id, allow) }
        notifier.onAutomationAction = { [weak self] ids, snooze in self?.automationAction(ids, snooze) }
    }

    func session(_ session: AgentSession) {
        let id = session.id
        let open = Bubble.Action(title: Editors.label(for: session), style: .primary) { [weak self] in
            self?.openSession(id)
        }
        let body = session.status == .needsInput ? (session.detail ?? session.prompt) : (session.summary ?? session.prompt)
        bubbles.show(Bubble(id: "session:\(id)", symbol: session.status.symbol, tint: session.status.tint,
                            title: "\(session.workspaceName): \(session.status.label)", subtitle: session.source.displayName,
                            body: body, actions: [open], onTap: { [weak self] in self?.openSession(id) },
                            expires: Date().addingTimeInterval(session.status == .done ? 15 : 45)))
        if session.status != .done { chime() }
        if alsoSystemNotifications { notifier.announce(session) }
    }

    func approval(id: UUID, title: String, detail: String) {
        bubbles.show(Bubble(id: Self.approvalID(id), symbol: "hand.raised.fill", tint: .orange,
                            title: "\(ConfigStore.shared.config.pet.name) wants to: \(title)", body: String(detail.prefix(240)),
                            actions: [
                                .init(title: "Allow", style: .primary) { [weak self] in self?.decide(id, true) },
                                .init(title: "Deny", style: .destructive) { [weak self] in self?.decide(id, false) },
                                .init(title: "Open chat") { [weak self] in self?.openChat() },
                            ]))
        chime()
        if alsoSystemNotifications { notifier.announceApproval(id: id, title: title, detail: detail) }
    }

    /// An unknown Telegram user sent /start. Allow adds them; nothing else about them reaches the chat.
    func telegramPairing(_ request: TelegramBridge.Pending, allow: @escaping () -> Void, deny: @escaping () -> Void) {
        let user = request.user
        let handle = user.username.map { "@\($0), " } ?? ""
        bubbles.show(Bubble(id: Self.telegramID(user.id), symbol: "paperplane.fill", tint: .blue,
                            title: "Telegram user \(user.displayName) (\(handle)id \(user.id)) wants to connect",
                            body: "Allow them to chat with \(ConfigStore.shared.config.pet.name) from Telegram?",
                            actions: [.init(title: "Allow", style: .primary, run: allow),
                                      .init(title: "Deny", style: .destructive, run: deny)]))
        chime()
    }

    func clearTelegramPairing(id: Int64) {
        bubbles.dismiss(Self.telegramID(id))
    }

    static func telegramID(_ id: Int64) -> String { "telegram:\(id)" }

    func clearApproval(id: UUID) {
        bubbles.dismiss(Self.approvalID(id))
        notifier.clearApproval(id: id)
    }

    func signal(_ signal: Signal) {
        let url = signal.url
        var actions: [Bubble.Action] = []
        if let url { actions.append(.init(title: "Open", style: .primary) { NSWorkspace.shared.open(url) }) }
        if let prompt = signal.ask {
            actions.append(.init(title: "Ask \(ConfigStore.shared.config.pet.name)") { [weak self] in self?.ask(prompt) })
        }
        let quiet = signal.mood == .done
        bubbles.show(Bubble(id: "signal:\(signal.id)", symbol: signal.symbol, tint: quiet ? .green : signal.mood == .failed ? .red : .orange,
                            title: signal.label, subtitle: signal.subtitle, body: signal.title, actions: actions,
                            onTap: url.map { link in { NSWorkspace.shared.open(link) } },
                            expires: Date().addingTimeInterval(quiet ? 15 : 40)))
        if !quiet { chime() }
        if alsoSystemNotifications { notifier.announceSignal(signal) }
    }

    /// A bubble from an automation: a reminder, a poll result, a shell or prompt answer, or an approval question.
    func automation(_ notice: AutomationNotice) {
        let tint: Color
        switch notice.tint {
        case .info: tint = .cyan
        case .good: tint = .green
        case .bad: tint = .red
        case .warn: tint = .orange
        }
        let actions = notice.buttons.map { button in
            Bubble.Action(title: button.title, style: button.primary ? .primary : button.destructive ? .destructive : .normal) { [weak self] in
                self?.bubbles.dismiss(notice.id)
                button.run()
            }
        }
        bubbles.show(Bubble(id: notice.id, symbol: notice.symbol, tint: tint, title: notice.title, subtitle: notice.subtitle, body: notice.body,
                            actions: actions, expires: notice.expires.map { Date().addingTimeInterval($0) }))
        chime()
        if alsoSystemNotifications || notice.systemNotification { notifier.announceAutomation(notice) }
    }

    func chat(_ title: String, detail: String = "Click to open the chat.") {
        bubbles.show(Bubble(id: "chat", symbol: "bubble.left.fill", tint: .accentColor, title: title, body: detail,
                            actions: [.init(title: "Open chat", style: .primary) { [weak self] in self?.openChat() }],
                            onTap: { [weak self] in self?.openChat() },
                            expires: Date().addingTimeInterval(20)))
        chime()
        if alsoSystemNotifications { notifier.announceChat(title) }
    }

    /// A meeting summary was written. Clicking opens it.
    func meetingSummary(_ url: URL) {
        let open: () -> Void = { NSWorkspace.shared.open(url) }
        bubbles.show(Bubble(id: "meeting-summary", symbol: "doc.text.fill", tint: .green, title: "Meeting summary ready",
                            body: url.deletingLastPathComponent().lastPathComponent,
                            actions: [.init(title: "Open summary", style: .primary) { open() }], onTap: open,
                            expires: Date().addingTimeInterval(60)))
        chime()
        if alsoSystemNotifications { notifier.announceMeetingSummary(url) }
    }

    /// Action items from a meeting summary (the user's, and the ones they wait on from others), or tasks a watcher
    /// automation proposed. Nothing becomes a task until they choose.
    func taskSuggestions(_ suggestions: [TaskSuggestion], addAll: @escaping () -> Void, review: @escaping () -> Void) {
        guard !suggestions.isEmpty else { return }
        let text = Self.taskSuggestionsText(suggestions)
        bubbles.show(Bubble(id: "task-suggestions", symbol: "checklist", tint: .accentColor, title: text.title, body: text.body,
                            actions: [.init(title: "Add all", style: .primary, run: addAll), .init(title: "Review", run: review)],
                            onTap: review, expires: Date().addingTimeInterval(60)))
        chime()
    }

    /// "3 action items from the meeting" over "2 for you, 1 waiting on others" and the first three items, or
    /// "2 suggested tasks from <automation>" for one watcher run.
    static func taskSuggestionsText(_ suggestions: [TaskSuggestion]) -> (title: String, body: String) {
        let count = suggestions.count
        let waiting = suggestions.filter { $0.waitingOn != nil }.count
        let mine = count - waiting
        let title = if case .automation(_, let name) = suggestions.first?.origin {
            "\(count) suggested \(count == 1 ? "task" : "tasks") from \(name)"
        } else if mine == 0 {
            "\(count) \(count == 1 ? "item" : "items") you're waiting on from the meeting"
        } else {
            "\(count) action \(count == 1 ? "item" : "items") from the meeting"
        }
        var lines = mine > 0 && waiting > 0 ? ["\(mine) for you, \(waiting) waiting on others"] : []
        lines += suggestions.prefix(3).map { s in "• " + (s.waitingLabel.map { "\($0): \(s.title)" } ?? s.title) }
        if count > 3 { lines.append("and \(count - 3) more") }
        return (title, lines.joined(separator: "\n"))
    }

    func tasksAdded(_ count: Int) {
        bubbles.show(Bubble(id: "task-suggestions", symbol: "checkmark.circle.fill", tint: .green,
                            title: "Added \(count) \(count == 1 ? "task" : "tasks")", expires: Date().addingTimeInterval(8)))
    }

    /// Small talk from the Actions menu.
    func say(_ text: String) {
        bubbles.show(Bubble(id: "say", symbol: "pawprint.fill", tint: .accentColor, title: ConfigStore.shared.config.pet.name, body: text,
                            expires: Date().addingTimeInterval(8)))
    }

    private func chime() {
        NSSound(named: "Pop")?.play()
    }

    private static func approvalID(_ id: UUID) -> String { "approval:\(id.uuidString)" }
}
