import Foundation

/// Which project a task belongs to, for Start. Memory notes are not used: they are keyed by a hash of the folder.
enum TaskProject {
    /// Folders to try, best first: a `file` link (its folder when it points at a file), a `thread` link's workspace, a watched
    /// `session` link's workspace, then the project of the task's last run. Folders inside `~/.ironpet` (meetings, the
    /// no-project folder) and folders that no longer exist are left out.
    static func candidates(for task: TaskItem, threadWorkspace: (String) -> String?, sessionWorkspace: (String) -> String?,
                           lastRun: TaskRun?, ironpetRoot: URL = Paths.root) -> [URL] {
        var found: [URL] = []
        func add(_ path: String?) {
            guard let path, !path.isEmpty else { return }
            var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
            if !isDirectory.boolValue { url = url.deletingLastPathComponent() }
            let root = ironpetRoot.standardizedFileURL.path
            guard url.path != root, !url.path.hasPrefix(root + "/"), !found.contains(url) else { return }
            found.append(url)
        }
        for link in task.links where link.kind == .file { add(link.ref) }
        for link in task.links where link.kind == .thread { add(threadWorkspace(link.ref)) }
        for link in task.links where link.kind == .session { add(sessionWorkspace(link.ref)) }
        add(lastRun?.repo.path)
        return found
    }

    /// The repository root of the first candidate that is in a git repository.
    static func resolve(_ candidates: [URL], git: GitWorktree) async -> URL? {
        for folder in candidates {
            if let root = try? await git.repoRoot(of: folder) { return root }
        }
        return nil
    }
}
