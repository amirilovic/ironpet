import Foundation

/// What the agent is told when it starts or continues a task. Task text can come from a meeting, a watcher or the screen,
/// so the notes go in a fenced block named as the task's description, and the rules come after them.
enum TaskRunPrompt {
    static func start(task: TaskItem, repo: URL, branch: String, baseBranch: String?) -> String {
        var lines = [
            "The user handed you this task from their ironpet task list. Do it now, in this folder.",
            "",
            "Task: \(task.title)",
        ]
        if !task.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fence = fence(for: task.notes)
            lines += ["", "The task's description, as written in the list (\(origin(task.source))):", fence, task.notes, fence]
        }
        lines += [
            "",
            "You are in a separate git worktree of \(repo.path) on the branch \(branch)"
                + (baseBranch.map { ", started from \($0)" } ?? "") + ". The user's own working copy is not here, and you must not change it.",
            "This is a fresh checkout: untracked files such as dependencies, build output and .env files are not there. Install what you need.",
            "",
            "Rules:",
            "- Commit your work on this branch with a clear message when you are done.",
            "- Do not push, open a pull request or change remotes. The user does that from ironpet with Open PR.",
            "- Do not change this task's status or close it; ironpet tracks it while you work.",
            "- If you need a decision from the user, stop and ask it as your last message.",
            "- End with a short summary: what you did, what is left, and how to check it.",
        ]
        return lines.joined(separator: "\n")
    }

    /// For Retry and a new Start on a finished run: the same session, so the agent still has the task.
    static func resume(task: TaskItem, lastError: String?) -> String {
        var text = "Continue the task \"\(task.title)\" in this worktree."
        if let lastError, !lastError.isEmpty { text += " The last attempt ended with: \(lastError)" }
        return text + " Commit when you are done, do not push, and end with a short summary."
    }

    private static func origin(_ source: TaskSource) -> String {
        switch source {
        case .meeting: return "from a meeting's action items"
        case .automation: return "suggested by an automation from outside text"
        case .capture: return "suggested from text on the user's screen"
        default: return "by the user or an agent"
        }
    }

    /// Three backticks, or more than the longest run in the text, so the notes cannot close the block early.
    static func fence(for text: String) -> String {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }
}
