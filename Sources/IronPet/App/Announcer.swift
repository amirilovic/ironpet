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

    static let taskSuggestionsID = "task-suggestions"

    /// One info bubble for suggestions that just arrived from a meeting summary, a watcher or screen capture: the count and the
    /// first title, no buttons. They stay pending until resolved in the Tasks tab or over MCP. Nil when there are none.
    static func taskSuggestionsBubble(_ added: [TaskSuggestion], review: @escaping () -> Void = {}, now: Date = Date()) -> Bubble? {
        guard let first = added.first else { return nil }
        let title: String
        switch first.origin {
        case .meeting: title = "From your meeting"
        case .capture: title = "From your screen"
        case .automation(_, let name): title = name
        }
        let count = added.count
        return Bubble(id: taskSuggestionsID, symbol: first.source.symbol, tint: .blue, title: title,
                      body: "\(count) \(count == 1 ? "suggestion" : "suggestions") for review\n\(first.title)",
                      onTap: review, expires: now.addingTimeInterval(20))
    }

    /// Replaces the previous one, so a run shows one bubble however many suggestions it stored.
    func taskSuggestions(_ added: [TaskSuggestion], review: @escaping () -> Void = {}) {
        if Self.showTaskSuggestions(added, in: bubbles, review: review) { chime() }
    }

    /// Shows the bubble and returns whether there was one to show.
    @discardableResult
    static func showTaskSuggestions(_ added: [TaskSuggestion], in store: BubbleStore, review: @escaping () -> Void = {}) -> Bool {
        guard let bubble = taskSuggestionsBubble(added, review: review) else { return false }
        store.show(bubble)
        return true
    }

    static let tasksDueID = "task-due"

    /// Open tasks that are due today or overdue. Stays until answered or closed, since it comes once per due date.
    func tasksDue(_ tasks: [TaskItem], chime: Bool, done: @escaping () -> Void, snooze: @escaping () -> Void,
                  open: @escaping () -> Void) {
        guard !tasks.isEmpty else { return }
        bubbles.show(Self.tasksDueBubble(tasks, now: Date(), done: done, snooze: snooze, open: open))
        if chime { self.chime() }
    }

    static func tasksDueBubble(_ tasks: [TaskItem], now: Date, calendar: Calendar = .current, done: @escaping () -> Void,
                               snooze: @escaping () -> Void, open: @escaping () -> Void) -> Bubble {
        let overdue = tasks.contains { TaskDue.kind($0, now: now, calendar: calendar) == .overdue }
        let title: String
        let subtitle: String?
        let body: String?
        if tasks.count == 1, let task = tasks.first {
            switch TaskDue.kind(task, now: now, calendar: calendar) {
            case .today: title = "Due today: \(task.title)"; subtitle = nil
            case .now: title = "Due now: \(task.title)"; subtitle = task.due.map { "Due at \($0.formatted(date: .omitted, time: .shortened))" }
            case .overdue: title = "Overdue: \(task.title)"; subtitle = task.dueLabel(now: now, calendar: calendar)
            }
            body = nil
        } else {
            title = "\(tasks.count) tasks due"
            subtitle = nil
            // The body shows 4 lines, so each task has to fit on one.
            var lines = tasks.prefix(3).map { task in
                let name = task.title.count > 30 ? String(task.title.prefix(29)) + "…" : task.title
                let when: String
                switch TaskDue.kind(task, now: now, calendar: calendar) {
                case .today: when = "today"
                case .now: when = "now"
                case .overdue: when = "overdue"
                }
                return "• \(name) · \(when)"
            }
            if tasks.count > 3 { lines.append("and \(tasks.count - 3) more") }
            body = lines.joined(separator: "\n")
        }
        let later = TaskDue.snoozesToTomorrow(tasks, calendar: calendar) ? "Remind tomorrow" : "Snooze 1 h"
        return Bubble(id: tasksDueID, symbol: overdue ? "calendar.badge.exclamationmark" : "calendar", tint: overdue ? .orange : .accentColor,
                      title: title, subtitle: subtitle, body: body,
                      actions: [.init(title: tasks.count == 1 ? "Done" : "All done", style: .primary, run: done),
                                .init(title: later, run: snooze), .init(title: "Open", run: open)],
                      onTap: open)
    }

    /// What happened while the user was away, one clickable line per kind of news.
    func welcomeBack(_ digest: ActivityDigest, away: TimeInterval, open: @escaping (ActivityDigest.Target) -> Void,
                     showAll: @escaping () -> Void) {
        bubbles.show(Self.digestBubble(digest, id: WelcomeBack.bubbleID, title: "Welcome back", subtitle: Self.awayText(away),
                                       petName: ConfigStore.shared.config.pet.name, open: open, showAll: showAll))
        if digest.items.contains(where: \.isUrgent) { chime() }
    }

    static let digestLineLimit = 5

    /// A summary bubble for any digest: up to five lines, the last one "and N more" when it does not fit.
    static func digestBubble(_ digest: ActivityDigest, id: String, title: String, subtitle: String?, petName: String,
                             open: @escaping (ActivityDigest.Target) -> Void, showAll: @escaping () -> Void,
                             expires: TimeInterval = 180, now: Date = Date()) -> Bubble {
        let fits = digest.items.count <= digestLineLimit
        let shown = fits ? digest.items : Array(digest.items.prefix(digestLineLimit - 1))
        var lines = shown.map { item in
            let line = digestLine(item, petName: petName)
            let target = item.target
            return Bubble.Line(symbol: line.symbol, tint: line.tint, text: line.text) { if let target { open(target) } else { showAll() } }
        }
        if !fits {
            let rest = digest.items.dropFirst(shown.count).reduce(0) { $0 + $1.count }
            lines.append(Bubble.Line(symbol: "ellipsis.circle", tint: .secondary, text: "and \(rest) more", run: showAll))
        }
        let urgent = digest.items.contains(where: \.isUrgent)
        return Bubble(id: id, symbol: urgent ? "exclamationmark.bubble.fill" : "sun.max.fill", tint: urgent ? .orange : .accentColor,
                      title: title, subtitle: subtitle, lines: lines, actions: [.init(title: "Show all", run: showAll)],
                      expires: now.addingTimeInterval(expires))
    }

    /// "While you were away (42 min)", or "(1 h 5 min)".
    static func awayText(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        let span = minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
        return "While you were away (\(span))"
    }

    /// One line of a summary: the thing itself when there is one, a count when there are several.
    static func digestLine(_ item: ActivityDigest.Item, petName: String) -> (symbol: String, tint: Color, text: String) {
        let n = item.count
        let first = item.events.first
        let name = first?.title ?? ""
        switch item.kind {
        case .sessionNeedsInput:
            return ("hand.raised.fill", .orange, n == 1 ? "\(name) is waiting for you" : "\(n) agents are waiting for you")
        case .sessionFailed:
            return ("xmark.octagon.fill", .red, n == 1 ? "\(name) failed" : "\(n) agents failed")
        case .sessionDone:
            return ("checkmark.circle.fill", .green, n == 1 ? "\(name) finished" : "\(n) agents finished")
        case .alertOpened:
            let failing = item.isUrgent
            let symbol = n == 1 ? (first?.extra[ActivityEvent.AlertKey.symbol] ?? "bell.fill") : "bell.badge.fill"
            return (symbol, failing ? .red : .orange, n == 1 ? alertText(first) : "\(n) new alerts")
        case .alertResolved:
            return ("checkmark.seal.fill", .green, n == 1 ? "Cleared: " + alertText(first) : "\(n) alerts cleared")
        case .taskDue:
            return ("calendar", .accentColor, n == 1 ? "Task due: \(name)" : "\(n) tasks due")
        case .taskSuggested:
            return ("checklist", .accentColor, n == 1 ? "Suggested task: \(name)" : "\(n) suggested tasks")
        case .meetingSummary:
            return ("doc.text.fill", .green, n == 1 ? "Meeting summary ready: \(name)" : "\(n) meeting summaries ready")
        case .chatFinished:
            return ("bubble.left.fill", .accentColor, name.isEmpty ? "\(petName) finished your task" : name)
        case .automationBubble:
            let tint: Color
            switch first?.extra[ActivityEvent.AutomationKey.tint] {
            case "good": tint = .green
            case "bad": tint = .red
            case "warn": tint = .orange
            default: tint = .cyan
            }
            guard n == 1, let first else { return ("bell.fill", .cyan, "\(n) updates from automations") }
            let detail = first.detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return ("bell.fill", tint, detail.isEmpty || detail == first.title ? first.title : "\(first.title): \(detail)")
        default:
            return ("sparkle", .secondary, n == 1 ? name : "\(n) more updates")
        }
    }

    /// "CI failed: irtaza/ironpet #84", from the alert's label and what it is about.
    private static func alertText(_ event: ActivityEvent?) -> String {
        guard let event else { return "" }
        let about = event.detail.isEmpty ? event.title : event.detail
        return event.extra[ActivityEvent.AlertKey.label].map { "\($0): \(about)" } ?? about
    }

    /// The morning brief or the day's recap from a `digest` automation. Open shows it on the Today page.
    func brief(_ brief: Brief, automation: Automation, open: @escaping () -> Void) {
        let bubble = Self.briefBubble(brief, automation: automation, now: Date(), open: open)
        bubbles.show(bubble)
        guard !brief.isEmpty else { return }
        chime()
        if alsoSystemNotifications || automation.presentation.notification == true {
            notifier.announceAutomation(AutomationNotice(id: bubble.id, symbol: bubble.symbol, title: bubble.title, subtitle: bubble.subtitle,
                                                         body: bubble.body, automationIDs: [automation.id]))
        }
    }

    static func briefID(_ kind: Brief.Kind) -> String { "digest:\(kind.rawValue)" }

    /// Stays until the end of the day, since it comes once a day. An empty one, which only Run now shows, goes in 15 seconds.
    static func briefBubble(_ brief: Brief, automation: Automation, now: Date, calendar: Calendar = .current,
                            open: @escaping () -> Void) -> Bubble {
        var day = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        let expires: Date?
        if let seconds = automation.presentation.expiresSeconds {
            expires = now.addingTimeInterval(seconds)
        } else if brief.isEmpty {
            expires = now.addingTimeInterval(15)
        } else {
            expires = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        }
        return Bubble(id: briefID(brief.kind), symbol: automation.presentation.symbol ?? brief.kind.symbol,
                      tint: brief.kind == .brief ? .orange : .indigo,
                      title: automation.action.title ?? brief.kind.title, subtitle: (brief.kind == .recap ? brief.window.start : now).formatted(day),
                      body: brief.isEmpty ? "Nothing to report" : brief.lines.prefix(4).joined(separator: "\n"),
                      actions: [.init(title: "Open", style: .primary, run: open)], onTap: open, expires: expires)
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
