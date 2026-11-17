import XCTest
@testable import IronPet

/// Runs the real git in temporary repositories.
final class GitWorktreeTests: XCTestCase {
    private var dir: URL!
    private var repo: URL!
    private var git: GitWorktree!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-git-\(UUID().uuidString)").resolvingSymlinksInPath()
        repo = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        git = try XCTUnwrap(GitWorktree.locate(), "git is needed for these tests")
        try GitFixture.initRepo(repo)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRepoRootFromASubfolderAndErrorOutsideARepo() async throws {
        let sub = repo.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let root = try await git.repoRoot(of: sub)
        XCTAssertEqual(root.resolvingSymlinksInPath().path, repo.path)
        let plain = dir.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        do {
            _ = try await git.repoRoot(of: plain)
            XCTFail("a plain folder is not a repo")
        } catch let error as GitError {
            XCTAssertTrue(error.message.contains("is not a git repository"), error.message)
        }
    }

    func testEmptyRepositoryHasNoHead() async throws {
        let empty = dir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try GitFixture.sh(["git", "init", "-q"], in: empty)
        do {
            _ = try await git.head(empty)
            XCTFail("no commits means no head")
        } catch let error as GitError {
            XCTAssertTrue(error.message.contains("no commits"), error.message)
        }
    }

    func testAddWorktreeLeavesTheWorkingCopyAlone() async throws {
        try "draft".write(to: repo.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8)
        let before = try GitFixture.sh(["git", "status", "--porcelain"], in: repo)
        let head = try await git.head(repo)
        XCTAssertEqual(head.branch, "main")
        let parent = GitWorktree.parent(for: repo, root: dir.appendingPathComponent("worktrees"))
        let slot = await git.freeSlot(repo, task: "fix-login", parent: parent)
        XCTAssertEqual(slot.branch, "ironpet/fix-login")
        try await git.addWorktree(repo: repo, folder: slot.folder, branch: slot.branch, base: head.sha)
        XCTAssertTrue(FileManager.default.fileExists(atPath: slot.folder.appendingPathComponent("README.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: slot.folder.appendingPathComponent("wip.txt").path),
                       "uncommitted files are not copied")
        let hasUncommitted = await git.hasUncommittedChanges(repo)
        XCTAssertTrue(hasUncommitted)
        XCTAssertEqual(try GitFixture.sh(["git", "status", "--porcelain"], in: repo), before)
        XCTAssertEqual(try GitFixture.sh(["git", "branch", "--show-current"], in: repo), "main")
        let exists = await git.branchExists(repo, "ironpet/fix-login")
        XCTAssertTrue(exists)
        let next = await git.freeSlot(repo, task: "fix-login", parent: parent)
        XCTAssertEqual(next.branch, "ironpet/fix-login-2")
        XCTAssertEqual(next.folder.lastPathComponent, "fix-login-2")
    }

    func testRemoveKeepsADirtyWorktreeUnlessForced() async throws {
        let (folder, branch, base) = try await addWorktree("dirty")
        try "x".write(to: folder.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let dirty = await git.hasUncommittedChanges(folder)
        XCTAssertTrue(dirty)
        do {
            try await git.removeWorktree(repo: repo, folder: folder, force: false)
            XCTFail("a dirty worktree is kept")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        try await git.removeWorktree(repo: repo, folder: folder, force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let deleted = await git.deleteBranchIfEmpty(repo: repo, branch: branch, base: base)
        XCTAssertTrue(deleted, "a branch with no commits goes")
    }

    func testABranchWithCommitsIsKept() async throws {
        let (folder, branch, base) = try await addWorktree("work")
        try "hello".write(to: folder.appendingPathComponent("HELLO.md"), atomically: true, encoding: .utf8)
        try GitFixture.sh(["git", "add", "."], in: folder)
        try GitFixture.sh(["git", "commit", "-qm", "hello"], in: folder)
        let ahead = await git.commitsAhead(folder, base: base)
        XCTAssertEqual(ahead, 1)
        try await git.removeWorktree(repo: repo, folder: folder, force: false)
        let deleted = await git.deleteBranchIfEmpty(repo: repo, branch: branch, base: base)
        XCTAssertFalse(deleted)
        let exists = await git.branchExists(repo, branch)
        XCTAssertTrue(exists)
    }

    func testPruneForgetsAWorktreeDeletedByHand() async throws {
        let (folder, _, _) = try await addWorktree("gone")
        try FileManager.default.removeItem(at: folder)
        await git.prune(repo)
        XCTAssertFalse(try GitFixture.sh(["git", "worktree", "list"], in: repo).contains("gone"))
    }

    func testPushRemoteChoice() async throws {
        let none = await git.pushRemote(repo, baseBranch: "main")
        XCTAssertNil(none)
        try GitFixture.sh(["git", "remote", "add", "fork", "https://example.com/fork.git"], in: repo)
        let only = await git.pushRemote(repo, baseBranch: "main")
        XCTAssertEqual(only, "fork")
        try GitFixture.sh(["git", "remote", "add", "origin", "https://example.com/origin.git"], in: repo)
        let origin = await git.pushRemote(repo, baseBranch: "main")
        XCTAssertEqual(origin, "origin")
        try GitFixture.sh(["git", "config", "branch.main.remote", "fork"], in: repo)
        let upstream = await git.pushRemote(repo, baseBranch: "main")
        XCTAssertEqual(upstream, "fork")
    }

    func testPushBlockEnvironmentMakesAgentPushesFail() async throws {
        let bare = dir.appendingPathComponent("remote.git")
        try GitFixture.sh(["git", "init", "-q", "--bare", bare.path], in: dir)
        try GitFixture.sh(["git", "remote", "add", "origin", bare.path], in: repo)
        let blocked = await git.run(["push", "origin", "main"], in: repo, environment: GitWorktree.pushBlockEnvironment(remotes: ["origin"]))
        XCTAssertNotEqual(blocked.code, 0)
        let (folder, branch, _) = try await addWorktree("push")
        try await git.push(worktree: folder, remote: "origin", branch: branch)
        XCTAssertTrue(try GitFixture.sh(["git", "branch", "--list"], in: bare).contains("ironpet/push"))
    }

    func testOpenPRPushSkipsHooksAndWritesNoUpstream() async throws {
        let bare = dir.appendingPathComponent("remote.git")
        try GitFixture.sh(["git", "init", "-q", "--bare", bare.path], in: dir)
        try GitFixture.sh(["git", "remote", "add", "origin", bare.path], in: repo)
        let marker = dir.appendingPathComponent("hook-ran")
        for hooks in [repo.appendingPathComponent(".git/hooks"), dir.appendingPathComponent("custom-hooks")] {
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
            let hook = hooks.appendingPathComponent("pre-push")
            try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: hook, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        }
        let (folder, branch, _) = try await addWorktree("hooks")
        try await git.push(worktree: folder, remote: "origin", branch: branch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the repository's pre-push hook must not run")
        try GitFixture.sh(["git", "config", "core.hooksPath", dir.appendingPathComponent("custom-hooks").path], in: repo)
        try GitFixture.sh(["git", "-C", folder.path, "commit", "-q", "--allow-empty", "-m", "more"], in: dir)
        try await git.push(worktree: folder, remote: "origin", branch: branch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a hooks path the agent set must not run either")
        XCTAssertTrue(try GitFixture.sh(["git", "branch", "--list"], in: bare).contains(branch))
        let upstream = await git.run(["config", "--get", "branch.\(branch).remote"], in: repo)
        XCTAssertNotEqual(upstream.code, 0, "no upstream is written into the shared config")
    }

    func testPushBlockEnvironmentRewritesPushesToURLsAndRemotesAddedLater() async throws {
        let env = GitWorktree.pushBlockEnvironment(remotes: [])
        XCTAssertEqual(env["GIT_CONFIG_COUNT"], "6")
        XCTAssertEqual(Set((0..<6).compactMap { env["GIT_CONFIG_VALUE_\($0)"] }), Set(GitWorktree.pushPrefixes))
        XCTAssertTrue((0..<6).allSatisfy { env["GIT_CONFIG_KEY_\($0)"] == "url.ironpet-no-push://.pushInsteadOf" })
        try GitFixture.sh(["git", "remote", "add", "later", "git@example.invalid:me/app.git"], in: repo)
        for target in ["later", "https://example.invalid/me/app.git", "http://example.invalid/app.git",
                       "ssh://git@example.invalid/me/app.git", "git://example.invalid/app.git", "file:///tmp/ironpet-none.git"] {
            let result = await git.run(["push", target, "main"], in: repo, environment: env, timeout: 20)
            XCTAssertNotEqual(result.code, 0, target)
            XCTAssertTrue(result.stderr.contains("ironpet-no-push"), "\(target): \(result.stderr)")
        }
        let listed = GitWorktree.pushBlockEnvironment(remotes: ["origin"])
        XCTAssertEqual(listed["GIT_CONFIG_COUNT"], "7")
        XCTAssertEqual(listed["GIT_CONFIG_KEY_0"], "remote.origin.pushurl")
    }

    func testRemotesWithTheirOwnPushURLAreFound() async throws {
        let none = await git.remotesWithOwnPushURL(repo)
        XCTAssertEqual(none, [])
        try GitFixture.sh(["git", "remote", "add", "origin", "https://example.com/origin.git"], in: repo)
        try GitFixture.sh(["git", "remote", "add", "fork", "https://example.com/fork.git"], in: repo)
        let names = await git.remotes(repo)
        XCTAssertEqual(names.sorted(), ["fork", "origin"])
        try GitFixture.sh(["git", "config", "remote.fork.pushurl", "git@example.com:me/fork.git"], in: repo)
        try GitFixture.sh(["git", "config", "--add", "remote.fork.pushurl", "git@example.com:me/mirror.git"], in: repo)
        let found = await git.remotesWithOwnPushURL(repo)
        XCTAssertEqual(found, ["fork"])
        XCTAssertEqual(GitWorktree.pushURLRemotes("remote.a.pushurl x\nremote.my.dotted.pushurl y\nremote.a.pushurl z\nbranch.main.remote a"),
                       ["a", "my.dotted"])
    }

    func testAFailedStartIsUndoneWithoutLosingWork() async throws {
        let (clean, cleanBranch, base) = try await addWorktree("clean")
        await git.discardFailedStart(repo: repo, folder: clean, branch: cleanBranch, base: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clean.path))
        let cleanExists = await git.branchExists(repo, cleanBranch)
        XCTAssertFalse(cleanExists)
        let (dirty, dirtyBranch, _) = try await addWorktree("dirty")
        try "x".write(to: dirty.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        await git.discardFailedStart(repo: repo, folder: dirty, branch: dirtyBranch, base: base)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirty.appendingPathComponent("new.txt").path), "uncommitted work stays")
        let missing = dir.appendingPathComponent("never-made")
        await git.discardFailedStart(repo: repo, folder: missing, branch: "ironpet/never", base: base)
    }

    func testPushURLFollowsAPushurlSetting() async throws {
        try GitFixture.sh(["git", "remote", "add", "origin", "https://example.com/origin.git"], in: repo)
        let plain = await git.pushURL(repo, remote: "origin")
        XCTAssertEqual(plain, "https://example.com/origin.git")
        try GitFixture.sh(["git", "config", "remote.origin.pushurl", "https://evil.example/app.git"], in: repo)
        let redirected = await git.pushURL(repo, remote: "origin")
        XCTAssertEqual(redirected, "https://evil.example/app.git")
        let missing = await git.pushURL(repo, remote: "nope")
        XCTAssertNil(missing)
    }

    func testCompareURL() {
        XCTAssertEqual(GitWorktree.compareURL(remote: "git@github.com:me/app.git", base: "main", branch: "ironpet/x")?.absoluteString,
                       "https://github.com/me/app/compare/main...ironpet/x?expand=1")
        XCTAssertEqual(GitWorktree.compareURL(remote: "https://github.com/me/app", base: nil, branch: "ironpet/x")?.absoluteString,
                       "https://github.com/me/app/compare/ironpet/x?expand=1")
        XCTAssertNil(GitWorktree.compareURL(remote: "git@gitlab.com:me/app.git", base: "main", branch: "x"))
    }

    func testParentFolderIsPerRepository() {
        let root = URL(fileURLWithPath: "/w")
        let a = GitWorktree.parent(for: URL(fileURLWithPath: "/code/app"), root: root)
        let b = GitWorktree.parent(for: URL(fileURLWithPath: "/other/app"), root: root)
        XCTAssertTrue(a.lastPathComponent.hasPrefix("app-"))
        XCTAssertNotEqual(a, b)
    }

    private func addWorktree(_ id: String) async throws -> (URL, String, String) {
        let head = try await git.head(repo)
        let slot = await git.freeSlot(repo, task: id, parent: GitWorktree.parent(for: repo, root: dir.appendingPathComponent("worktrees")))
        try await git.addWorktree(repo: repo, folder: slot.folder, branch: slot.branch, base: head.sha)
        return (slot.folder, slot.branch, head.sha)
    }
}

/// Small helpers for tests that need a real repository.
enum GitFixture {
    static let env: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "Test"; env["GIT_AUTHOR_EMAIL"] = "test@example.com"
        env["GIT_COMMITTER_NAME"] = "Test"; env["GIT_COMMITTER_EMAIL"] = "test@example.com"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        return env
    }()

    @discardableResult
    static func sh(_ arguments: [String], in folder: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitError(message: "\(arguments.joined(separator: " ")) failed") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func initRepo(_ folder: URL) throws {
        try sh(["git", "init", "-q", "-b", "main"], in: folder)
        try "# Demo\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try sh(["git", "add", "."], in: folder)
        try sh(["git", "commit", "-qm", "init"], in: folder)
    }
}
