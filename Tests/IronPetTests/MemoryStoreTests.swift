import CryptoKit
import XCTest
@testable import IronPet

final class MemoryNoteTests: XCTestCase {
    func testNoteLineRoundTripsWithItsDateAndSource() {
        let note = MemoryNote(text: "Prefers pnpm over npm.", date: "2026-11-18", source: "chat:3f2a9c1d")
        XCTAssertEqual(note.line, "- Prefers pnpm over npm. <!-- 2026-11-18 chat:3f2a9c1d -->")
        XCTAssertEqual(MemoryNote.parse(note.line), note)
    }

    func testHandWrittenLinesAreUserNotesAndOtherLinesAreNotNotes() {
        XCTAssertEqual(MemoryNote.parse("- Uses tabs"), MemoryNote(text: "Uses tabs", date: nil, source: "user"))
        XCTAssertEqual(MemoryNote.parse("* Uses tabs")?.line, "- Uses tabs")
        XCTAssertEqual(MemoryNote.parse("- Odd <!-- not a trailer -->")?.source, "user", "a comment that is not a trailer is part of the text")
        for line in ["# About me", "Workspace: /x", "", "-", "plain prose"] { XCTAssertNil(MemoryNote.parse(line), line) }
    }

    func testCleanKeepsOneLineAndRefusesSecretsAndLongText() {
        XCTAssertEqual(try MemoryNote.clean("- Prefers\npnpm  <!-- x -->").get(), "Prefers pnpm x")
        XCTAssertEqual(MemoryNote.clean("   "), .failure(.empty))
        XCTAssertEqual(MemoryNote.clean(String(repeating: "a", count: 241)), .failure(.tooLong))
        XCTAssertEqual(MemoryNote.clean("My key is sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"), .failure(.secret))
    }

    func testSectionsAppendInPlaceAndNewOnesGoAtTheEnd() {
        var document = MemoryDocument("# People\n\n## Ana\n\n- Leads payments <!-- 2026-11-01 chat:a -->\n\n## Bo\n\n- Likes Go\n")
        document.append(MemoryNote(text: "Is in Lisbon", date: "2026-11-18", source: "chat:b"), section: "ana")
        document.append(MemoryNote(text: "New here", date: "2026-11-18", source: "chat:b"), section: "Cy")
        XCTAssertEqual(document.text, """
            # People

            ## Ana

            - Leads payments <!-- 2026-11-01 chat:a -->
            - Is in Lisbon <!-- 2026-11-18 chat:b -->

            ## Bo

            - Likes Go

            ## Cy

            - New here <!-- 2026-11-18 chat:b -->

            """)
        XCTAssertEqual(document.entries.map(\.section), ["Ana", "Ana", "Bo", "Cy"])
    }

    func testRemoteURLsOfOneRepoNormalizeToOneKey() {
        for url in ["git@github.com:Owner/Repo.git", "https://github.com/Owner/Repo", "https://user@GitHub.com/Owner/Repo.git/",
                    "ssh://git@github.com:22/Owner/Repo.git"] {
            XCTAssertEqual(ProjectKey.normalizeRemote(url), "github.com/Owner/Repo", url)
        }
        XCTAssertEqual(ProjectKey.normalizeRemote("/srv/git/app.git"), "file:/srv/git/app")
        XCTAssertNil(ProjectKey.normalizeRemote("  "))
    }

    func testOriginIsReadFromTheGitConfig() {
        let config = """
            [core]
            \tbare = false
            [remote "upstream"]
            \turl = git@github.com:other/repo.git
            [remote "origin"]
            \turl = git@github.com:me/app.git
            \tfetch = +refs/heads/*:refs/remotes/origin/*
            """
        XCTAssertEqual(ProjectKey.originURL(config: config), "git@github.com:me/app.git")
        XCTAssertNil(ProjectKey.originURL(config: "[remote \"upstream\"]\n url = x"))
    }
}

@MainActor
final class MemoryStoreTests: XCTestCase {
    private var dir: URL!
    private var store: FileMemoryStore!
    private var index: MemoryIndex!
    private var clock = Date(timeIntervalSince1970: 1_795_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        index = MemoryIndex(database: try Database(path: nil, migrations: MemoryIndex.migrations))
        store = FileMemoryStore(directory: dir.appendingPathComponent("memory"), index: index)
        store.now = { [unowned self] in clock }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func repo(_ name: String, remote: String?, worktreeOf main: URL? = nil) throws -> URL {
        let folder = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let main {
            let gitDir = main.appendingPathComponent(".git/worktrees/\(name)")
            try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
            try "../..\n".write(to: gitDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
            try "gitdir: \(gitDir.path)\n".write(to: folder.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        } else if let remote {
            let git = folder.appendingPathComponent(".git")
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            try "[remote \"origin\"]\n\turl = \(remote)\n".write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        }
        return folder
    }

    func testReadingCreatesNothingAndTheFirstNoteCreatesTheFile() {
        XCTAssertEqual(store.budgeted(store.aboutMe, bytes: 4000), "")
        XCTAssertTrue(store.files().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        let note = try? store.remember("Prefers pnpm over npm.", scope: .me, source: "chat:3f2a9c1d").get()
        XCTAssertEqual(note?.date, MemoryNote.day(clock))
        XCTAssertEqual(store.text(store.aboutMe), "# About me\n\n\(note!.line)\n")
        XCTAssertEqual(store.files().map(\.path), ["me.md"])
    }

    func testRememberDropsDuplicatesAndSecretsAndLogsTheChange() throws {
        _ = try store.remember("Prefers pnpm over npm.", scope: .me, source: "chat:a").get()
        _ = try store.remember("prefers PNPM over npm", scope: .me, source: "chat:b").get()
        XCTAssertEqual(store.document(store.aboutMe)?.notes.count, 1)
        guard case .failure(let failure) = store.remember("token ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789ab", scope: .me, source: "chat:a") else {
            return XCTFail("a secret is refused")
        }
        XCTAssertTrue(failure.message.contains("key, token or password"))
        let changes = store.recentChanges()
        XCTAssertEqual(changes.map(\.action), [.added])
        XCTAssertEqual(changes.first?.source, "chat:a")
    }

    func testSecretsOfEveryKindAreRefusedAndNothingIsWritten() {
        for secret in ["My GitHub token is ghp_abcdefghijklmnopqrstuvwxyz0123456789", "password=hunter22", "AWS key AKIAIOSFODNN7EXAMPLE"] {
            guard case .failure = store.remember(secret, scope: .me, source: "chat:a") else { XCTFail(secret); continue }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.aboutMe.path))
    }

    func testANoteIsOneLineAndEmptyOrLongTextIsRefused() throws {
        let saved = try store.remember("  Likes\nshort  answers ", scope: .me, source: "chat:a").get()
        XCTAssertEqual(saved.text, "Likes short answers")
        XCTAssertEqual(try store.remember("likes short answers", scope: .me, source: "chat:b").get(), saved, "the same note comes back")
        XCTAssertEqual(store.document(store.aboutMe)?.notes.count, 1)
        guard case .failure = store.remember("   ", scope: .me, source: "chat:a") else { return XCTFail("empty") }
        guard case .failure = store.remember(String(repeating: "a", count: MemoryNote.maxLength + 1), scope: .me, source: "chat:a") else {
            return XCTFail("too long")
        }
    }

    func testTheUsersOwnTextAndSectionsSurviveRememberAndForget() throws {
        let organised = "# About me\n\nThings I wrote myself.\n\n## Work\n\n- Reviews PRs in the morning\n\n## Home\n\n- Picks up the kids at 16:00\n"
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try organised.write(to: store.aboutMe, atomically: true, encoding: .utf8)
        let note = try store.remember("Prefers short answers", scope: .me, source: "chat:a").get()
        XCTAssertEqual(store.text(store.aboutMe), organised + note.line + "\n")
        _ = try store.forget("kids", source: "chat:a").get()
        XCTAssertEqual(store.text(store.aboutMe),
                       "# About me\n\nThings I wrote myself.\n\n## Work\n\n- Reviews PRs in the morning\n\n## Home\n\n" + note.line + "\n")
    }

    func testForgetLooksInMePeopleAndTheProjectAndKeepsTheRest() throws {
        let project = ProjectKey.of(try repo("app", remote: "git@github.com:o/app.git"))
        _ = try store.remember("Ana prefers Slack over email", scope: .me, source: "chat:a").get()
        _ = try store.remember("Is my lead", scope: .people, person: "Ana", source: "chat:a").get()
        _ = try store.remember("Ana reviews the auth code", scope: .project, project: project, source: "chat:a").get()
        _ = try store.remember("Runs QA", scope: .people, person: "Sam", source: "chat:a").get()
        let removed = try store.forget("ana", project: project, source: "chat:a").get()
        XCTAssertEqual(Set(removed.map(\.file)), ["me.md", store.relativePath(store.projectFile(project))])
        XCTAssertEqual(store.document(store.people)?.notes.map(\.text), ["Is my lead", "Runs QA"], "a section name is not note text")
        XCTAssertTrue(store.text(store.people).hasPrefix("# People"), "the header stays")
    }

    func testEveryChangeKeepsTheOldFileInHistory() throws {
        _ = try store.remember("One", scope: .me, source: "chat:a").get()
        clock += 1
        _ = try store.remember("Two", scope: .me, source: "chat:a").get()
        let folder = store.historyRoot.appendingPathComponent("me.md")
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(copies.count, 1, "the first write had no earlier version")
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent(copies[0]), encoding: .utf8).contains("- One"))
        XCTAssertFalse(try String(contentsOf: folder.appendingPathComponent(copies[0]), encoding: .utf8).contains("- Two"))
        XCTAssertEqual(index.count(.history), 1)
    }

    func testHistoryKeepsTheNewestCopiesOfEachFile() throws {
        for n in 0..<(FileMemoryStore.historyLimit + 5) {
            clock += 1
            _ = try store.remember("Note \(n)", scope: .me, source: "chat:a").get()
        }
        let folder = store.historyRoot.appendingPathComponent("me.md")
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(copies.count, FileMemoryStore.historyLimit)
        XCTAssertEqual(index.count(.history), FileMemoryStore.historyLimit)
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent(copies.last!), encoding: .utf8).contains("Note \(FileMemoryStore.historyLimit + 3)"))
    }

    func testForgetMovesMatchingNotesToHistoryAndUndoBringsThemBack() throws {
        _ = try store.remember("Prefers pnpm over npm", scope: .me, source: "chat:a").get()
        _ = try store.remember("Works in Helsinki", scope: .me, source: "chat:a").get()
        let removed = try store.forget("pnpm", source: "agent").get()
        XCTAssertEqual(removed.map(\.note.text), ["Prefers pnpm over npm"])
        XCTAssertEqual(store.document(store.aboutMe)?.notes.map(\.text), ["Works in Helsinki"])
        let change = try XCTUnwrap(store.recentChanges().first)
        XCTAssertEqual(change.action, .forgot)
        try store.undo(change).get()
        XCTAssertEqual(Set(store.document(store.aboutMe)?.notes.map(\.text) ?? []), ["Prefers pnpm over npm", "Works in Helsinki"])
        XCTAssertTrue(store.recentChanges().first { $0.id == change.id }?.undone == true)
    }

    func testForgetRefusesWhenNothingOrTooMuchMatches() throws {
        for n in 1...6 { _ = try store.remember("Uses tool \(n)", scope: .me, source: "chat:a").get() }
        guard case .failure(let none) = store.forget("rust", source: "agent") else { return XCTFail() }
        XCTAssertTrue(none.message.contains("no note matches"))
        guard case .failure(let many) = store.forget("uses tool", source: "agent") else { return XCTFail() }
        XCTAssertTrue(many.message.contains("6 notes match"))
        XCTAssertEqual(store.document(store.aboutMe)?.notes.count, 6, "nothing was removed")
    }

    func testReplaceSwapsOutTheOldNoteAndUndoRestoresIt() throws {
        _ = try store.remember("Uses npm", scope: .me, source: "chat:a").get()
        clock += 86_400
        _ = try store.replace(["uses npm."], with: "Uses pnpm, not npm", scope: .me, source: "chat:b").get()
        XCTAssertEqual(store.document(store.aboutMe)?.notes.map(\.text), ["Uses pnpm, not npm"])
        let change = try XCTUnwrap(store.recentChanges().first)
        XCTAssertEqual(change.action, .replaced)
        try store.undo(change).get()
        XCTAssertEqual(store.document(store.aboutMe)?.notes.map(\.text), ["Uses npm"])
    }

    func testUndoFailsAndKeepsTheChangeWhenTheNoteHasChangedSince() throws {
        _ = try store.remember("Uses npm", scope: .me, source: "chat:a").get()
        let change = try XCTUnwrap(store.recentChanges().first)
        try store.rewrite(store.aboutMe, with: "# About me\n\n- Uses npm, mostly\n", action: .edited, source: "user", summary: "x").get()
        guard case .failure(let failure) = store.undo(change) else { return XCTFail("the note is not there any more") }
        XCTAssertTrue(failure.message.contains("changed since"))
        XCTAssertEqual(store.recentChanges().first { $0.id == change.id }?.undone, false)
        XCTAssertEqual(store.document(store.aboutMe)?.notes.map(\.text), ["Uses npm, mostly"])
    }

    func testSettingsDoNotSaveOverAFileThatChangedWhileEditing() throws {
        _ = try store.remember("First", scope: .me, source: "chat:a").get()
        let model = MemorySettingsModel(store: store, index: index)
        XCTAssertEqual(model.selected, "me.md")
        model.draft = model.draft + "- Mine\n"
        _ = try store.remember("Learned meanwhile", scope: .me, source: "chat:b").get()
        model.save()
        XCTAssertNotNil(model.message)
        XCTAssertTrue(store.text(store.aboutMe).contains("Learned meanwhile"))
        XCTAssertFalse(store.text(store.aboutMe).contains("Mine"))
        model.revert()
        model.draft = model.draft + "- Mine\n"
        model.save()
        XCTAssertNil(model.message)
        XCTAssertTrue(store.text(store.aboutMe).contains("- Mine"))
        XCTAssertTrue(store.text(store.aboutMe).contains("Learned meanwhile"))
    }

    func testUndoOfAnAddRemovesTheNote() throws {
        _ = try store.remember("Ana leads payments", scope: .people, person: "Ana", source: "chat:a").get()
        try store.undo(XCTUnwrap(store.recentChanges().first)).get()
        XCTAssertEqual(store.document(store.people)?.notes, [])
    }

    func testRewriteIsUndoneFromItsHistoryCopy() throws {
        _ = try store.remember("Keep me", scope: .me, source: "chat:a").get()
        clock += 1
        try store.rewrite(store.aboutMe, with: "# About me\n\n- Shorter\n", action: .edited, source: "user", summary: "Edited in Settings").get()
        try store.undo(XCTUnwrap(store.recentChanges().first)).get()
        XCTAssertEqual(store.document(store.aboutMe)?.notes.map(\.text), ["Keep me"])
    }

    func testPeopleNeedANameAndProjectsNeedAFolder() {
        guard case .failure = store.remember("Likes tea", scope: .people, source: "chat:a") else { return XCTFail() }
        guard case .failure = store.remember("Uses SwiftPM", scope: .project, source: "chat:a") else { return XCTFail() }
    }

    func testBudgetKeepsWholeNotesNewestFirstAndSaysHowManyAreLeft() throws {
        for (n, day) in [(1, 0.0), (2, 1), (3, 2)] {
            clock = Date(timeIntervalSince1970: 1_795_000_000 + day * 86_400)
            _ = try store.remember("Note number \(n) with some words", scope: .me, source: "chat:a").get()
        }
        let one = (store.document(store.aboutMe)?.notes.last?.line.utf8.count ?? 0) + 1
        let text = store.budgeted(store.aboutMe, bytes: one * 2 + 5)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("Note number 3"))
        XCTAssertTrue(lines[1].contains("Note number 2"))
        XCTAssertEqual(lines[2], "(1 older note not shown; use memory_search to find them.)")
        XCTAssertFalse(store.budgeted(store.aboutMe, bytes: 10_000).contains("not shown"))
    }

    func testPeopleNamedInTheMessageComeFirst() throws {
        for (name, day) in [("Ana", 0.0), ("Bo", 2), ("Cy Twain", 1)] {
            clock = Date(timeIntervalSince1970: 1_795_000_000 + day * 86_400)
            _ = try store.remember("\(name) note", scope: .people, person: name, source: "chat:a").get()
        }
        XCTAssertEqual(store.peopleSections(named: "Can you ask cy twain and ana?"), ["Ana", "Cy Twain", "Bo"])
        XCTAssertEqual(store.peopleSections(named: "hello"), ["Bo", "Cy Twain", "Ana"])
        XCTAssertEqual(store.budgeted(store.people, bytes: 4000, sections: ["Ana"]).components(separatedBy: "\n").first, "## Ana")
    }

    func testWorktreesAndClonesOfARepoShareOneProjectFile() throws {
        let main = try repo("app", remote: "git@github.com:me/app.git")
        let worktree = try repo("app-fix", remote: nil, worktreeOf: main)
        let clone = try repo("app-clone", remote: "https://github.com/me/app")
        let keys = [main, worktree, clone].map(ProjectKey.of)
        XCTAssertTrue(keys.allSatisfy { $0.isRepo && $0.key == "github.com/me/app" && $0.name == "app" })
        XCTAssertEqual(Set(keys.map(store.projectFile)).count, 1)
        let plain = try repo("notes", remote: nil)
        XCTAssertEqual(ProjectKey.of(plain), ProjectKey.path(plain))
        XCTAssertFalse(ProjectKey.of(plain).isRepo)
    }

    func testPathKeyMatchesTheFileNameOldVersionsWrote() {
        let folder = URL(fileURLWithPath: "/Users/you/code/demo")
        XCTAssertEqual(ProjectKey.path(folder).fileName, "demo-\(oldSuffix(folder)).md")
    }

    /// What the old `Memory.projectFile` used: the first four bytes of the SHA-256 of the standardized path.
    private func oldSuffix(_ folder: URL) -> String {
        SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    func testMigrationDeletesHeaderOnlyFilesAndMovesNotesToTheRepoFile() throws {
        let projects = store.directory.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let gone = projects.appendingPathComponent("app-11111111.md")
        try "# app\n\nWorkspace: /var/folders/x/T/ironpet-runner-1/app\n".write(to: gone, atomically: true, encoding: .utf8)
        let main = try repo("app", remote: "git@github.com:me/app.git")
        let old = projects.appendingPathComponent(ProjectKey.path(main).fileName)
        try "# app\n\nWorkspace: \(main.path)\n\n- Tests run with swift test\n".write(to: old, atomically: true, encoding: .utf8)
        let kept = projects.appendingPathComponent("scratch-22222222.md")
        try "# scratch\n\nWorkspace: /nowhere\n\n- A note\n".write(to: kept, atomically: true, encoding: .utf8)
        store.migrateLayout()
        let target = store.projectFile(ProjectKey.of(main))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "notes for a folder that is gone stay where they are")
        XCTAssertEqual(store.document(target)?.notes.map(\.text), ["Tests run with swift test"])
        XCTAssertTrue(store.text(target).contains("Repo: github.com/me/app"))
        // Runs once: a header-only file written later is left alone.
        try "# later\n".write(to: gone, atomically: true, encoding: .utf8)
        store.migrateLayout()
        XCTAssertTrue(FileManager.default.fileExists(atPath: gone.path))
    }

    func testForgetEverythingRemovesFilesHistoryAndTheirIndex() throws {
        _ = try store.remember("One", scope: .me, source: "chat:a").get()
        _ = try store.remember("Two", scope: .me, source: "chat:a").get()
        store.forgetEverything()
        XCTAssertTrue(store.files().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.historyRoot.path))
        XCTAssertEqual(index.count(.note), 0)
        XCTAssertEqual(index.count(.history), 0)
        XCTAssertTrue(store.recentChanges().isEmpty)
    }

    func testContainsOnlyMatchesInsideTheFolder() {
        let saved = FileMemoryStore.directory
        defer { FileMemoryStore.directory = saved }
        FileMemoryStore.directory = URL(fileURLWithPath: "/tmp/m/memory")
        XCTAssertTrue(FileMemoryStore.contains("/tmp/m/memory/me.md"))
        XCTAssertFalse(FileMemoryStore.contains("/tmp/m/memory-other/me.md"))
        XCTAssertFalse(FileMemoryStore.contains("/tmp/m/memory"))
    }
}
