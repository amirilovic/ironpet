import Foundation

extension NotificationDraft {
    /// The notification for an automation's bubble. The source is the automation, or `system` when the bubble has none.
    init(notice: AutomationNotice) {
        let body = notice.body ?? ""
        var links = notice.links
        if let url = notice.url, let link = NotificationLink(kind: "url", ref: url.absoluteString), !links.contains(link) { links.append(link) }
        self.init(source: notice.automationIDs.first ?? NotificationItem.systemSource, type: notice.notificationType, title: notice.title,
                  summary: notice.summary ?? Self.summary(of: body.isEmpty ? (notice.subtitle ?? "") : body),
                  description: notice.detail ?? body, links: Array(links.prefix(NotificationLink.maxLinks)))
    }

    /// The notification for the bubble that announces a new or changed alert. An alert from an automation is `automation:<id>:<key>`.
    init(signal: Signal) {
        var links = signal.links
        if let url = signal.url, let link = NotificationLink(kind: "url", ref: url.absoluteString), !links.contains(link) { links.insert(link, at: 0) }
        links.append(NotificationLink(.alert, signal.id, label: "Alert"))
        let parts = signal.id.split(separator: ":", omittingEmptySubsequences: false)
        let source = parts.count >= 3 && parts[0] == "automation" ? String(parts[1]) : NotificationItem.systemSource
        self.init(source: source, type: .alertAnnouncement, title: "\(signal.label): \(signal.title)", summary: signal.subtitle,
                  description: signal.detail ?? signal.subtitle, links: Array(links.prefix(NotificationLink.maxLinks)))
    }
}
