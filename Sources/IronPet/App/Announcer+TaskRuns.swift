import AppKit
import SwiftUI

/// Bubbles for agents working on tasks. Each run has its own approval bubble and one bubble for how it ended.
extension Announcer {
    func taskRunApproval(_ approval: TaskRun.Approval, task: String, openTasks: @escaping () -> Void) {
        bubbles.show(Bubble(id: Self.taskRunApprovalID(approval.id), symbol: "hand.raised.fill", tint: .orange,
                            title: "Task agent wants to: \(approval.title)", subtitle: task, body: String(approval.detail.prefix(240)),
                            actions: [
                                .init(title: "Allow", style: .primary) { [weak self] in self?.decide(approval.id, true) },
                                .init(title: "Deny", style: .destructive) { [weak self] in self?.decide(approval.id, false) },
                                .init(title: "Show task", run: openTasks),
                            ]))
        NSSound(named: "Pop")?.play()
        if alsoSystemNotifications { notifier.announceApproval(id: approval.id, title: approval.title, detail: approval.detail) }
    }

    func clearTaskRunApproval(id: UUID) {
        bubbles.dismiss(Self.taskRunApprovalID(id))
        notifier.clearApproval(id: id)
    }

    func taskRunEnded(_ run: TaskRun, task: String, openTasks: @escaping () -> Void, openPR: (() -> Void)?) {
        let finished = run.state == .finished
        var actions: [Bubble.Action] = []
        if let openPR, run.canOpenPR { actions.append(.init(title: "Open PR", style: .primary, run: openPR)) }
        actions.append(.init(title: "Show task", style: actions.isEmpty ? .primary : .normal, run: openTasks))
        let body = finished ? (run.summary ?? Self.commitsText(run)) : (run.error ?? "The agent stopped.")
        bubbles.show(Bubble(id: Self.taskRunID(run.task), symbol: finished ? "checkmark.circle.fill" : "xmark.octagon.fill",
                            tint: finished ? .green : .red, title: finished ? "Agent finished: \(task)" : "Agent failed: \(task)",
                            subtitle: finished ? Self.commitsText(run) : run.agentName, body: body, actions: actions, onTap: openTasks,
                            expires: Date().addingTimeInterval(finished ? 30 : 60)))
        NSSound(named: "Pop")?.play()
        if alsoSystemNotifications { notifier.announceChat(finished ? "Agent finished: \(task)" : "Agent failed: \(task)") }
    }

    func taskRunPushed(_ run: TaskRun, remote: String) {
        bubbles.show(Bubble(id: Self.taskRunID(run.task), symbol: "arrow.up.circle.fill", tint: .green,
                            title: "Pushed \(run.branch)", subtitle: remote, body: "Finish the pull request in your browser.",
                            actions: [], expires: Date().addingTimeInterval(15)))
    }

    static func taskRunApprovalID(_ id: UUID) -> String { "task-run-approval:\(id.uuidString)" }
    static func taskRunID(_ task: String) -> String { "task-run:\(task)" }

    static func commitsText(_ run: TaskRun) -> String {
        "\(run.commits == 1 ? "1 commit" : "\(run.commits) commits") on \(run.branch)"
    }
}
