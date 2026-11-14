import AppKit
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?

    /// UNUserNotificationCenter traps when the process is not inside an app bundle (e.g. `swift run`).
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()

    func start() {
        guard let center else { return NSLog("ironpet: not running from an app bundle, notifications disabled") }
        center.delegate = self
        let allow = UNNotificationAction(identifier: "allow", title: "Allow", options: [])
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive])
        let done = UNNotificationAction(identifier: "done", title: "Done", options: [])
        let snooze = UNNotificationAction(identifier: "snooze", title: "Snooze 10 min", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "approval", actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: "reminder", actions: [done, snooze], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if !granted { NSLog("ironpet: notifications not authorized \(error?.localizedDescription ?? "")") }
        }
    }

    func announce(_ session: AgentSession) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(session.source.displayName): \(session.status.label)"
        content.subtitle = session.workspaceName
        content.body = session.status == .needsInput
            ? (session.detail ?? session.prompt ?? "")
            : (session.summary ?? session.prompt ?? "")
        content.sound = session.status == .done ? nil : .default
        content.userInfo = ["session": session.id]
        let request = UNNotificationRequest(identifier: "\(session.id):\(session.status.rawValue)", content: content, trigger: nil)
        center.add(request)
    }

    var onOpenChat: (() -> Void)?
    var onApprovalAction: ((UUID, Bool) -> Void)?

    /// Approval request with Allow / Deny buttons, so the user can answer without switching apps.
    func announceApproval(id: UUID, title: String, detail: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(Config.load().config.pet.name): \(title)"
        content.body = String(detail.prefix(240))
        content.sound = .default
        content.categoryIdentifier = "approval"
        content.userInfo = ["approval": id.uuidString]
        center.add(UNNotificationRequest(identifier: "approval:\(id.uuidString)", content: content, trigger: nil))
    }

    /// CI, review and Sentry alerts. Clicking opens the PR or issue.
    func announceSignal(_ signal: Signal) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(signal.kind.label): \(signal.title)"
        content.body = signal.subtitle
        content.sound = signal.kind.mood == .done ? nil : .default
        content.userInfo = ["url": signal.url.absoluteString]
        center.add(UNNotificationRequest(identifier: signal.id, content: content, trigger: nil))
    }

    var onReminderAction: ((_ kinds: [ReminderScheduler.Kind], _ snooze: Bool) -> Void)?

    /// Water / stretch / eye break, with Done and Snooze buttons. Several due at once share one notification.
    func announceReminder(_ kinds: [ReminderScheduler.Kind], agentWorking: Bool) {
        guard let center, let first = kinds.first else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(Config.load().config.pet.name): " + (kinds.count == 1 ? first.title : "Time for a short break")
        content.body = kinds.count == 1 ? first.body : kinds.map { "\($0.title): \($0.body)" }.joined(separator: "\n")
        if agentWorking { content.subtitle = "Your agent is still working, good moment for it." }
        content.sound = .default
        content.categoryIdentifier = "reminder"
        content.userInfo = ["reminder": kinds.map(\.rawValue).joined(separator: ",")]
        center.removeDeliveredNotifications(withIdentifiers: ["reminder"])
        center.add(UNNotificationRequest(identifier: "reminder", content: content, trigger: nil))
    }

    /// Clicking opens `summary.md`.
    func announceMeetingSummary(_ url: URL) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Meeting summary ready"
        content.body = url.deletingLastPathComponent().lastPathComponent
        content.sound = .default
        content.userInfo = ["file": url.path]
        center.add(UNNotificationRequest(identifier: "meeting-summary:\(url.path)", content: content, trigger: nil))
    }

    func clearApproval(id: UUID) {
        center?.removeDeliveredNotifications(withIdentifiers: ["approval:\(id.uuidString)"])
    }

    func announceChat(_ title: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "Click to open the chat."
        content.sound = .default
        content.userInfo = ["chat": true]
        center.add(UNNotificationRequest(identifier: "chat:\(UUID().uuidString)", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let raw = info["approval"] as? String, let id = UUID(uuidString: raw) {
            let action = response.actionIdentifier
            DispatchQueue.main.async {
                switch action {
                case "allow": self.onApprovalAction?(id, true)
                case "deny": self.onApprovalAction?(id, false)
                default: self.onOpenChat?()
                }
            }
        } else if let raw = info["reminder"] as? String {
            let kinds = raw.split(separator: ",").compactMap { ReminderScheduler.Kind(rawValue: String($0)) }
            let snooze = response.actionIdentifier == "snooze"
            DispatchQueue.main.async { self.onReminderAction?(kinds, snooze) }
        } else if let path = info["file"] as? String {
            DispatchQueue.main.async { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        } else if let link = info["url"] as? String, let url = URL(string: link) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        } else if let id = info["session"] as? String {
            DispatchQueue.main.async { self.onOpen?(id) }
        } else if info["chat"] != nil {
            DispatchQueue.main.async { self.onOpenChat?() }
        }
        completionHandler()
    }
}
