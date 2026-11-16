import XCTest
@testable import IronPet

@MainActor
final class ChatKeepsSessionTests: XCTestCase {
    private var session: ChatSession!
    private let folderA = FileManager.default.temporaryDirectory
    private let folderB = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-folder-b")

    override func setUp() async throws {
        session = ChatSession(restore: false)
        session.workspace = folderA
        session.turnRunner = { _, _ in }
        session.input = "hello"
        session.send()
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

    func testPromptWaitsInInputWhenNoFolder() {
        let fresh = ChatSession(restore: false)
        fresh.workspace = nil
        fresh.prepareForShow()
        fresh.prefill("fix it")
        XCTAssertEqual(fresh.input, "fix it")
        XCTAssertNil(fresh.workspace)
        fresh.send()
        XCTAssertEqual(fresh.input, "fix it")
        XCTAssertTrue(fresh.items.isEmpty)
        XCTAssertNil(fresh.workspace)
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
