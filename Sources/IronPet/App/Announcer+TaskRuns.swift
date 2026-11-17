import AppKit
import SwiftUI

/// Bubbles for agents working on tasks. Each run has its own approval bubble and one bubble for how it ended.
extension Announcer {
    func taskRunApproval(_ approval: TaskRun.Approval, task: String, openTasks: @escaping () -> Void) {
        bubbles.show(Self.taskRunApprovalBubble(approval, task: task, decide: { [weak self] in self?.decide(approval.id, $0) }, openTasks: openTasks))
        NSSound(named: "Pop")?.play()
        if alsoSystemNotifications {
            notifier.announceApproval(id: approval.id, title: approval.title, detail: Self.taskRunApprovalBody(approval),
                                      canAllow: approval.allowableAtAGlance)
        }
    }

    /// Allow only when the whole request fits: a longer one is answered in Tasks, where all of it shows.
    static func taskRunApprovalBubble(_ approval: TaskRun.Approval, task: String, decide: @escaping (Bool) -> Void,
                                      openTasks: @escaping () -> Void) -> Bubble {
        var actions: [Bubble.Action] = []
        if approval.allowableAtAGlance { actions.append(.init(title: "Allow", style: .primary) { decide(true) }) }
        actions.append(.init(title: "Deny", style: .destructive) { decide(false) })
        actions.append(.init(title: "Show task", style: approval.allowableAtAGlance ? .normal : .primary, run: openTasks))
        return Bubble(id: taskRunApprovalID(approval.id), symbol: "hand.raised.fill", tint: .orange,
                      title: "Task agent wants to: \(approval.title)", subtitle: task, body: taskRunApprovalBody(approval), actions: actions)
    }

    /// The detail when it fits, else its start and where to read the rest.
    static func taskRunApprovalBody(_ approval: TaskRun.Approval) -> String {
        if !approval.canAllow { return ApprovalRules.onlyAlwaysAllow }
        guard !TaskRun.Approval.fitsAtAGlance(approval.detail) else { return approval.detail }
        let start = approval.detail.split(separator: "\n", omittingEmptySubsequences: false).prefix(3).joined(separator: "\n")
        return String(start.prefix(TaskRun.Approval.glanceLimit - 60)) + "…\nToo long to show here: open the task to read all of it before you allow."
    }

    func clearTaskRunApproval(id: UUID) {
        bubbles.dismiss(Self.taskRunApprovalID(id))
        notifier.clearApproval(id: id)
    }

    func taskRunEnded(_ run: TaskRun, task: String, openTasks: @escaping () -> Void, openPR: (() -> Void)?) {
        bubbles.show(Self.taskRunEndedBubble(run, task: task, openTasks: openTasks, openPR: openPR))
        NSSound(named: "Pop")?.play()
        let finished = run.state == .finished
        if alsoSystemNotifications { notifier.announceChat(finished ? "Agent finished: \(task)" : "Agent failed: \(task)") }
    }

    static func taskRunEndedBubble(_ run: TaskRun, task: String, openTasks: @escaping () -> Void, openPR: (() -> Void)?) -> Bubble {
        let finished = run.state == .finished
        var actions: [Bubble.Action] = []
        if let openPR, run.canOpenPR { actions.append(.init(title: "Open PR", style: .primary, run: openPR)) }
        actions.append(.init(title: "Show task", style: actions.isEmpty ? .primary : .normal, run: openTasks))
        let body = finished ? (run.summary ?? commitsText(run)) : (run.error ?? "The agent stopped.")
        return Bubble(id: taskRunID(run.task), symbol: finished ? "checkmark.circle.fill" : "xmark.octagon.fill",
                      tint: finished ? .green : .red, title: finished ? "Agent finished: \(task)" : "Agent failed: \(task)",
                      subtitle: finished ? commitsText(run) : run.agentName, body: body, actions: actions, onTap: openTasks,
                      expires: Date().addingTimeInterval(finished ? 30 : 60))
    }

    func taskRunPushed(_ run: TaskRun, remote: String) {
        bubbles.show(Bubble(id: Self.taskRunID(run.task), symbol: "arrow.up.circle.fill", tint: .green,
                            title: "Pushed \(run.branch)", subtitle: remote, body: "Finish the pull request in your browser.",
                            actions: [], expires: Date().addingTimeInterval(15)))
    }

    func taskRunOpenPRFailed(_ run: TaskRun, task: String, reason: String, openTasks: @escaping () -> Void) {
        bubbles.show(Bubble(id: Self.taskRunID(run.task), symbol: "exclamationmark.triangle.fill", tint: .orange,
                            title: "Did not open a PR: \(task)", subtitle: run.branch, body: reason,
                            actions: [.init(title: "Show task", style: .primary, run: openTasks)], onTap: openTasks,
                            expires: Date().addingTimeInterval(60)))
    }

    static func taskRunApprovalID(_ id: UUID) -> String { "task-run-approval:\(id.uuidString)" }
    static func taskRunID(_ task: String) -> String { "task-run:\(task)" }

    static func commitsText(_ run: TaskRun) -> String {
        "\(run.commits == 1 ? "1 commit" : "\(run.commits) commits") on \(run.branch)"
    }
}
