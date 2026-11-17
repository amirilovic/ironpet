import CryptoKit
import Foundation

struct GitError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// The git commands a task run needs, run off the main thread with a timeout. In the user's own working copy it only
/// reads, adds a worktree and a branch, and removes what it added: never `reset`, `clean`, `checkout` or `branch -D`.
struct GitWorktree {
    let git: String

    /// The user's git on the login-shell PATH. Nil when there is none.
    static func locate() -> GitWorktree? {
        LoginShell.find("git").map { GitWorktree(git: $0.path) }
    }

    /// Runs git in `folder`. `GIT_TERMINAL_PROMPT=0` so a remote that wants a password fails instead of waiting.
    func run(_ arguments: [String], in folder: URL, environment extra: [String: String] = [:], timeout: TimeInterval = 30) async -> CommandResult {
        var env = LoginShell.environment()
        env["GIT_TERMINAL_PROMPT"] = "0"
        env.merge(extra) { _, new in new }
        return await CommandRunner.run(executable: git, arguments: ["-C", folder.path] + arguments, timeout: timeout,
                                       environment: env, maxBytes: 64 * 1024)
    }

    private func output(_ arguments: [String], in folder: URL) async throws -> String {
        let result = await run(arguments, in: folder)
        guard result.code == 0, !result.timedOut, result.spawnError == nil else { throw GitError(message: Self.describe(result)) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func describe(_ result: CommandResult) -> String {
        if let spawn = result.spawnError { return spawn }
        if result.timedOut { return "git did not finish in time" }
        let text = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return String((text.isEmpty ? "git failed (exit \(result.code ?? -1))" : text).prefix(300))
    }

    // MARK: Reading

    /// The top folder of the repository `folder` is in.
    func repoRoot(of folder: URL) async throws -> URL {
        guard FileManager.default.fileExists(atPath: folder.path) else { throw GitError(message: "\(folder.path) does not exist") }
        let result = await run(["rev-parse", "--show-toplevel"], in: folder)
        guard result.code == 0, !result.stdout.isEmpty else {
            throw GitError(message: "\(folder.lastPathComponent) is not a git repository. A task run works in its own copy, so it needs git.")
        }
        return URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The commit the working copy is on, and its branch (nil when detached).
    func head(_ repo: URL) async throws -> (branch: String?, sha: String) {
        let sha = await run(["rev-parse", "--verify", "-q", "HEAD"], in: repo)
        guard sha.code == 0, !sha.stdout.isEmpty else { throw GitError(message: "\(repo.lastPathComponent) has no commits yet.") }
        let branch = await run(["symbolic-ref", "--short", "-q", "HEAD"], in: repo)
        let name = branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (branch.code == 0 && !name.isEmpty ? name : nil, sha.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Uncommitted or untracked changes in a working copy.
    func hasUncommittedChanges(_ folder: URL) async -> Bool {
        let result = await run(["status", "--porcelain"], in: folder)
        return result.code == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func remotes(_ repo: URL) async -> [String] {
        let result = await run(["remote"], in: repo)
        return result.stdout.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    /// The same list without waiting on a task, for the chat building an agent's environment. Empty when git fails.
    func remotesNow(_ repo: URL) -> [String] {
        var env = LoginShell.environment()
        env["GIT_TERMINAL_PROMPT"] = "0"
        let result = CommandRunner.runBlocking(executable: git, arguments: ["-C", repo.path, "remote"], timeout: 5,
                                               environment: env, stdin: nil, maxBytes: 16 * 1024)
        guard result.code == 0 else { return [] }
        return result.stdout.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    /// Remotes with their own `pushurl`. git pushes to every `pushurl` a remote has, so the push block's extra one
    /// does not stop a push to them.
    func remotesWithOwnPushURL(_ repo: URL) async -> [String] {
        let result = await run(["config", "--get-regexp", #"^remote\..*\.pushurl$"#], in: repo)
        guard result.code == 0 else { return [] }
        return Self.pushURLRemotes(result.stdout)
    }

    /// The remote names in `git config --get-regexp` output such as `remote.origin.pushurl git@host:me/app.git`.
    static func pushURLRemotes(_ output: String) -> [String] {
        var names: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let key = line.split(separator: " ", maxSplits: 1).first, key.hasPrefix("remote."), key.hasSuffix(".pushurl") else { continue }
            let name = String(key.dropFirst("remote.".count).dropLast(".pushurl".count))
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Undoes a Start that failed after picking its slot: removes the worktree when git made it and it is clean,
    /// forgets it, and deletes the branch when it has no commits.
    func discardFailedStart(repo: URL, folder: URL, branch: String, base: String) async {
        if FileManager.default.fileExists(atPath: folder.path) { try? await removeWorktree(repo: repo, folder: folder, force: false) }
        await prune(repo)
        await deleteBranchIfEmpty(repo: repo, branch: branch, base: base)
    }

    /// The remote Open PR pushes to: the base branch's upstream remote, else `origin`, else the only one.
    func pushRemote(_ repo: URL, baseBranch: String?) async -> String? {
        let all = await remotes(repo)
        if let baseBranch {
            let configured = await run(["config", "--get", "branch.\(baseBranch).remote"], in: repo).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if all.contains(configured) { return configured }
        }
        if all.contains("origin") { return "origin" }
        return all.count == 1 ? all[0] : nil
    }

    /// The URL `git push <remote>` uses: its `pushurl` when one is set, else its `url`.
    func pushURL(_ repo: URL, remote: String) async -> String? {
        let url = await run(["remote", "get-url", "--push", remote], in: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    func remoteURL(_ repo: URL, remote: String) async -> String? {
        let url = await run(["remote", "get-url", remote], in: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    /// Commits on `HEAD` of `folder` that `base` does not have.
    func commitsAhead(_ folder: URL, base: String, ref: String = "HEAD") async -> Int {
        Int(await run(["rev-list", "--count", "\(base)..\(ref)"], in: folder).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func branchExists(_ repo: URL, _ branch: String) async -> Bool {
        await run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repo).code == 0
    }

    // MARK: Changing

    /// A branch and folder that are both free: `ironpet/<id>` in `<parent>/<id>`, then `-2`, `-3`, ...
    func freeSlot(_ repo: URL, task id: String, parent: URL) async -> (branch: String, folder: URL) {
        for n in 1...50 {
            let name = n == 1 ? id : "\(id)-\(n)"
            let folder = parent.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: folder.path), !(await branchExists(repo, "ironpet/\(name)")) {
                return ("ironpet/\(name)", folder)
            }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        return ("ironpet/\(id)-\(stamp)", parent.appendingPathComponent("\(id)-\(stamp)"))
    }

    /// Adds a worktree on a new branch from `base`. The user's working tree, index and current branch stay as they are.
    func addWorktree(repo: URL, folder: URL, branch: String, base: String) async throws {
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = await run(["worktree", "add", "-b", branch, folder.path, base], in: repo, timeout: 120)
        guard result.code == 0, !result.timedOut else { throw GitError(message: Self.describe(result)) }
    }

    /// Removes a worktree. Without `force` git refuses when it has uncommitted changes, and the folder stays.
    func removeWorktree(repo: URL, folder: URL, force: Bool) async throws {
        let result = await run(["worktree", "remove"] + (force ? ["--force"] : []) + [folder.path], in: repo, timeout: 60)
        guard result.code == 0 else { throw GitError(message: Self.describe(result)) }
    }

    /// Deletes the branch only when it has no commits beyond `base`, with `-d`, so nothing the agent committed is lost.
    @discardableResult
    func deleteBranchIfEmpty(repo: URL, branch: String, base: String) async -> Bool {
        guard await branchExists(repo, branch), await commitsAhead(repo, base: base, ref: branch) == 0 else { return false }
        return await run(["branch", "-d", branch], in: repo).code == 0
    }

    func prune(_ repo: URL) async {
        _ = await run(["worktree", "prune"], in: repo)
    }

    func push(worktree: URL, remote: String, branch: String) async throws {
        let result = await run(Self.pushArguments(remote: remote, branch: branch), in: worktree, timeout: 180)
        guard result.code == 0, !result.timedOut else { throw GitError(message: Self.describe(result)) }
    }

    // MARK: Pure helpers

    /// Open PR's push. Hooks are off, since the agent could have written them into the shared repository, and no upstream
    /// is set, since that would write the task's branch into the shared config.
    static func pushArguments(remote: String, branch: String) -> [String] {
        ["-c", "core.hooksPath=/dev/null", "push", "--no-verify", remote, branch]
    }

    /// `~/.ironpet/worktrees/<repo>-<hash>`: one folder per repository, so two repos with the same name never share one.
    static func parent(for repo: URL, root: URL = Paths.worktrees) -> URL {
        let digest = SHA256.hash(data: Data(repo.standardizedFileURL.path.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("\(repo.lastPathComponent)-\(suffix)")
    }

    static let noPushURL = "ironpet-no-push://task-runs-cannot-push"
    /// URL prefixes rewritten for pushes only, so a push to a remote added later, or straight to a URL, fails too.
    static let pushPrefixes = ["https://", "http://", "ssh://", "git@", "git://", "file://"]

    /// Environment for the agent process: every remote's push URL points nowhere and every push URL is rewritten to
    /// nowhere, so a `git push` the agent runs without asking fails. ironpet's own push on Open PR runs without it.
    static func pushBlockEnvironment(remotes: [String]) -> [String: String] {
        let entries = remotes.map { ("remote.\($0).pushurl", noPushURL) }
            + pushPrefixes.map { ("url.ironpet-no-push://.pushInsteadOf", $0) }
        var env = ["GIT_CONFIG_COUNT": String(entries.count)]
        for (index, entry) in entries.enumerated() {
            env["GIT_CONFIG_KEY_\(index)"] = entry.0
            env["GIT_CONFIG_VALUE_\(index)"] = entry.1
        }
        return env
    }

    /// GitHub's new-PR page for `branch`, from a remote URL. Nil for other hosts.
    static func compareURL(remote: String, base: String?, branch: String) -> URL? {
        var path: String?
        if remote.hasPrefix("git@github.com:") {
            path = String(remote.dropFirst("git@github.com:".count))
        } else if let url = URL(string: remote), url.host?.lowercased() == "github.com" {
            path = String(url.path.drop(while: { $0 == "/" }))
        }
        guard var repo = path, !repo.isEmpty else { return nil }
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        let range = base.map { "\($0)...\(branch)" } ?? branch
        let encoded = range.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? range
        return URL(string: "https://github.com/\(repo)/compare/\(encoded)?expand=1")
    }
}
