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
            UNNotificationCategory(identifier: "automation", actions: [done, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: "automation-plain", actions: [], intentIdentifiers: []),
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
        content.title = "\(signal.label): \(signal.title)"
        content.body = signal.subtitle
        content.sound = signal.mood == .done ? nil : .default
        if let url = signal.url { content.userInfo = ["url": url.absoluteString] }
        center.add(UNNotificationRequest(identifier: signal.id, content: content, trigger: nil))
    }

    var onAutomationAction: ((_ ids: [String], _ snooze: Bool) -> Void)?

    /// An automation's bubble as a notification. With Done and Snooze buttons when the bubble has them.
    func announceAutomation(_ notice: AutomationNotice) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        if let subtitle = notice.subtitle { content.subtitle = subtitle }
        content.body = notice.body ?? ""
        content.sound = .default
        content.categoryIdentifier = notice.buttons.contains { $0.title == "Done" } ? "automation" : "automation-plain"
        content.userInfo = ["automation": notice.automationIDs.joined(separator: ",")]
        center.removeDeliveredNotifications(withIdentifiers: [notice.id])
        center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
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
        } else if let raw = info["automation"] as? String {
            let ids = raw.split(separator: ",").map(String.init)
            let snooze = response.actionIdentifier == "snooze"
            DispatchQueue.main.async { self.onAutomationAction?(ids, snooze) }
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
