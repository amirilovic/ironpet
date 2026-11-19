import XCTest
@testable import IronPet

@MainActor
final class ChatKeepsSessionTests: XCTestCase {
    private var session: ChatSession!
    private var h: ChatHarness!
    private let folderA = FileManager.default.temporaryDirectory
    private let folderB = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-folder-b")

    override func setUp() async throws {
        TestMemory.isolate()
        h = ChatHarness(); session = h.session
        session.workspace = folderA
        session.turnRunner = { _, _ in }
        h.model.input = "hello"
        await h.model.sendNow()
        for _ in 0..<5 { await Task.yield() }
        session.stop()
    }

    func testPrepareForShowKeepsSessionAndFolder() {
        let ids = session.items.map(\.id)
        session.prepareForShow()
        XCTAssertEqual(session.workspace, folderA)
        XCTAssertEqual(session.items.map(\.id), ids)
        XCTAssertFalse(session.needsWorkspace)
    }

    func testPrepareForShowAsksWhenNoFolderYet() {
        let fresh = ChatSession(restore: false)
        fresh.workspace = nil
        fresh.prepareForShow()
        XCTAssertTrue(fresh.needsWorkspace)
        XCTAssertNil(fresh.workspace)
    }

    func testPromptWaitsInInputWhenNoFolder() async {
        let h = ChatHarness()
        let fresh = h.session
        fresh.workspace = nil
        fresh.prepareForShow()
        h.model.prefill("fix it")
        XCTAssertEqual(h.model.input, "fix it")
        XCTAssertNil(fresh.workspace)
        await h.model.sendNow()
        XCTAssertEqual(h.model.input, "fix it", "the draft comes back when there is no folder to send in")
        XCTAssertTrue(fresh.items.isEmpty)
        XCTAssertNil(fresh.workspace)
        await h.model.settle()
        XCTAssertTrue(h.model.needsWorkspace, "the window learns it must ask for a folder")
    }

    func testUserPicksFolderStartsNewSession() {
        session.use(folderB)
        XCTAssertEqual(session.workspace, folderB)
        XCTAssertTrue(session.items.isEmpty)
    }

    func testNewChatClearsSession() {
        session.newChat()
        XCTAssertTrue(session.items.isEmpty)
    }
}
