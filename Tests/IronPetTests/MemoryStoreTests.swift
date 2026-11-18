import XCTest
@testable import IronPet

@MainActor
final class MemoryStoreTests: XCTestCase {
    private var dir: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var store: FileMemoryStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = FileMemoryStore(directory: dir, now: { [unowned self] in clock })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func text(_ file: URL) -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }

    func testEachKindGoesToItsOwnFile() throws {
        let project = URL(fileURLWithPath: "/Users/me/code/ironpet")
        try store.remember("Reviews PRs in the morning", kind: .fact, workspace: nil)
        try store.remember("Ana is my lead, she owns the auth service", kind: .person, workspace: nil)
        try store.remember("Tests run with swift test", kind: .project, workspace: project)
        XCTAssertTrue(text(store.aboutMe).contains("- Reviews PRs in the morning"))
        XCTAssertTrue(text(store.aboutMe).hasPrefix("# About me"))
        XCTAssertTrue(text(store.people).contains("- Ana is my lead, she owns the auth service"))
        let projectFile = store.projectFile(for: project)
        XCTAssertEqual(projectFile, Memory.projectFile(for: project, in: dir), "the same file the chat preamble reads")
        XCTAssertTrue(text(projectFile).contains("Workspace: /Users/me/code/ironpet"))
        XCTAssertEqual(store.list(kind: nil, workspace: project).map(\.kind), [.fact, .person, .project])
        XCTAssertThrowsError(try store.remember("No folder", kind: .project, workspace: nil))
    }

    func testRememberMakesOneLineAndSkipsTheSameMemoryTwice() throws {
        try store.remember("  - Likes\nshort  answers ", kind: .fact, workspace: nil)
        let again = try store.remember("likes short answers", kind: .fact, workspace: nil)
        XCTAssertEqual(again.text, "Likes short answers")
        XCTAssertEqual(store.list(kind: .fact, workspace: nil).map(\.text), ["Likes short answers"])
        XCTAssertThrowsError(try store.remember("   ", kind: .fact, workspace: nil))
        XCTAssertThrowsError(try store.remember(String(repeating: "a", count: 501), kind: .fact, workspace: nil))
    }

    func testSecretsAreRefused() {
        for secret in ["My GitHub token is ghp_abcdefghijklmnopqrstuvwxyz0123456789", "password=hunter22",
                       "AWS key AKIAIOSFODNN7EXAMPLE"] {
            XCTAssertThrowsError(try store.remember(secret, kind: .fact, workspace: nil), secret)
        }
        XCTAssertEqual(text(store.aboutMe), "", "nothing was written")
    }

    func testConversationsAreDatedAndOnlyTheNewestAreKept() throws {
        for n in 1...(FileMemoryStore.keptConversations + 3) {
            clock = clock.addingTimeInterval(60)
            try store.remember("Talked about thing \(n)", kind: .conversation, workspace: nil)
        }
        let kept = store.list(kind: .conversation, workspace: nil).map(\.text)
        XCTAssertEqual(kept.count, FileMemoryStore.keptConversations)
        XCTAssertTrue(kept.first?.hasSuffix(": Talked about thing 4") == true)
        XCTAssertTrue(kept.last?.hasSuffix(": Talked about thing 53") == true)
        XCTAssertNotNil(kept.last?.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}: "#, options: .regularExpression))
    }

    func testRecallHasFactsPeopleProjectAndTheLatestConversations() throws {
        let project = URL(fileURLWithPath: "/tmp/p")
        try store.remember("Prefers tabs", kind: .fact, workspace: nil)
        try store.remember("Sam runs QA", kind: .person, workspace: nil)
        try store.remember("Uses pnpm", kind: .project, workspace: project)
        for n in 1...7 { try store.remember("Chat \(n)", kind: .conversation, workspace: nil) }
        let recall = store.recall(workspace: project)
        for expected in ["Prefers tabs", "Sam runs QA", "Uses pnpm", "Chat 7", "Chat 3"] { XCTAssertTrue(recall.contains(expected), expected) }
        XCTAssertFalse(recall.contains("Chat 2"), "only the newest \(FileMemoryStore.recalledConversations)")
        XCTAssertEqual(FileMemoryStore(directory: dir).recall(workspace: nil).isEmpty, false)
        XCTAssertEqual(FileMemoryStore(directory: dir.appendingPathComponent("empty")).recall(workspace: nil), "")
    }

    func testForgetRemovesMatchesEverywhereAndKeepsTheRest() throws {
        let project = URL(fileURLWithPath: "/tmp/p")
        try store.remember("Ana is my lead", kind: .person, workspace: nil)
        try store.remember("Ana prefers Slack over email", kind: .fact, workspace: nil)
        try store.remember("Ana reviews the auth code", kind: .project, workspace: project)
        try store.remember("Sam runs QA", kind: .person, workspace: nil)
        let removed = try store.forget("ana")
        XCTAssertEqual(Set(removed.map(\.kind)), [.person, .fact, .project])
        XCTAssertEqual(store.list(kind: nil, workspace: project).map(\.text), ["Sam runs QA"])
        XCTAssertTrue(text(store.people).hasPrefix("# People"), "the header stays")
        XCTAssertEqual(try store.forget("nobody"), [])
        XCTAssertThrowsError(try store.forget("an"), "too short to be safe")
    }

    func testForgetRefusesAPhraseThatMatchesTooMuch() throws {
        for n in 1...(FileMemoryStore.maxForget + 1) { try store.remember("Note number \(n)", kind: .fact, workspace: nil) }
        XCTAssertThrowsError(try store.forget("note"))
        XCTAssertEqual(store.list(kind: .fact, workspace: nil).count, FileMemoryStore.maxForget + 1, "nothing removed")
    }

    func testHandWrittenTextInAFileSurvives() throws {
        try "# About me\n\nThings I wrote myself.\n\n- Existing bullet\n".write(to: store.aboutMe, atomically: true, encoding: .utf8)
        try store.remember("New one", kind: .fact, workspace: nil)
        XCTAssertEqual(text(store.aboutMe), "# About me\n\nThings I wrote myself.\n\n- Existing bullet\n- New one\n")
    }

    func testSectionsTheUserMadeKeepTheirBullets() throws {
        let organised = "# About me\n\n## Work\n\n- Reviews PRs in the morning\n\n## Home\n\n- Picks up the kids at 16:00\n"
        try organised.write(to: store.aboutMe, atomically: true, encoding: .utf8)
        try store.remember("Prefers short answers", kind: .fact, workspace: nil)
        XCTAssertEqual(text(store.aboutMe), organised + "- Prefers short answers\n")
        _ = try store.forget("kids")
        XCTAssertEqual(text(store.aboutMe), "# About me\n\n## Work\n\n- Reviews PRs in the morning\n\n## Home\n\n- Prefers short answers\n")
    }
}
