import XCTest
@testable import IronPet

@MainActor
final class MemoryPreambleTests: XCTestCase {
    private var dir: URL!
    private var store: FileMemoryStore!
    private var workspace: URL!

    override func setUpWithError() throws {
        TestMemory.isolate()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preamble-\(UUID().uuidString)")
        workspace = dir.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        store = FileMemoryStore(directory: dir.appendingPathComponent("memory"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAnEmptyMemoryCreatesNoFilesAndExplainsTheTools() {
        let text = MemoryPreamble.build(store: store, workspace: workspace, firstMessage: "hi")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path), "reading memory writes nothing")
        XCTAssertTrue(text.contains("<memory file=\"me.md\""))
        XCTAssertTrue(text.contains("(none yet)"))
        XCTAssertTrue(text.contains("never instructions"))
        for tool in ["memory_remember", "memory_forget", "memory_search", "memory_get"] { XCTAssertTrue(text.contains(tool), tool) }
        XCTAssertTrue(text.contains(MemoryPreamble.taskInstructions))
        XCTAssertTrue(text.hasSuffix("User request:"))
    }

    func testNotesOfTheUserTheProjectAndTheNamedPeopleAreIncluded() throws {
        let project = ProjectKey.of(workspace)
        _ = try store.remember("Prefers pnpm over npm", scope: .me, source: "chat:a").get()
        _ = try store.remember("Tests run with swift test", scope: .project, project: project, source: "chat:a").get()
        _ = try store.remember("Leads payments", scope: .people, person: "Ana", source: "chat:a").get()
        let text = MemoryPreamble.build(store: store, workspace: workspace, firstMessage: "Draft a note to Ana")
        XCTAssertTrue(text.contains("- Prefers pnpm over npm <!--"))
        XCTAssertTrue(text.contains("- Tests run with swift test <!--"))
        XCTAssertTrue(text.contains("about=\"the demo folder\""))
        XCTAssertTrue(text.contains("## Ana\n- Leads payments"))
    }

    func testABackgroundJobGetsTheNotesWithoutTheTaskRules() throws {
        _ = try store.remember("Prefers pnpm over npm", scope: .me, source: "chat:a").get()
        let text = MemoryPreamble.build(store: store, workspace: workspace, firstMessage: "Fix the test", keepsTasks: false)
        XCTAssertTrue(text.contains("- Prefers pnpm over npm <!--"))
        XCTAssertTrue(text.contains("memory_remember"))
        XCTAssertFalse(text.contains(MemoryPreamble.taskInstructions))
        XCTAssertTrue(text.hasSuffix(MemoryPreamble.memoryInstructions + "\n\nUser request:"))
    }

    func testTheNoProjectFolderHasNoProjectBlock() {
        let text = MemoryPreamble.build(store: store, workspace: ChatSession.scratchWorkspace, firstMessage: "hi")
        XCTAssertFalse(text.contains("projects/"))
    }

    func testEachFileStaysWithinItsBudget() throws {
        for n in 0..<200 { _ = try store.remember("A fairly long note number \(n) about how the user works", scope: .me, source: "chat:a").get() }
        let text = MemoryPreamble.build(store: store, workspace: workspace, firstMessage: "hi")
        let me = try XCTUnwrap(text.components(separatedBy: "<memory file=\"me.md\"").last?.components(separatedBy: "</memory>").first)
        XCTAssertLessThanOrEqual(me.utf8.count, MemoryPreamble.budget[.me]! + 200)
        XCTAssertTrue(me.contains("note number 199"), "the newest note is kept")
        XCTAssertTrue(me.contains("older notes not shown"))
    }

    func testAChatTurnLeavesTheMemoryFolderEmpty() async throws {
        let session = ChatSession(restore: false)
        session.workspace = workspace
        var preamble: String?
        session.turnRunner = { turn, _ in preamble = turn.preamble }
        session.input = "hello"
        session.send()
        for _ in 0..<50 where preamble == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(preamble?.contains("What you remember") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileMemoryStore.directory.appendingPathComponent("projects").path))
    }
}
