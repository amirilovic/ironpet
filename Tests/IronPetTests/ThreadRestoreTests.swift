import XCTest
@testable import IronPet

final class ThreadRestoreTests: XCTestCase {
    private func thread(_ kinds: [ChatSession.Item.Kind]) -> ChatThread {
        ChatThread(id: "t1", title: "Chat", workspace: "/tmp", updatedAt: Date(),
                   items: kinds.map { ChatSession.Item(kind: $0) }, agent: "claude")
    }

    func testRunningStepsShowAsFailedAfterQuit() {
        let restored = thread([.user("hi"), .tool("Ran `npm test`", ok: nil), .tool("Read a.ts", ok: true)]).restoredAfterQuit()
        guard case .tool(_, let running) = restored.items[1].kind, case .tool(_, let finished) = restored.items[2].kind else {
            return XCTFail("tool items expected")
        }
        XCTAssertEqual(running, false)
        XCTAssertEqual(finished, true)
    }

    func testOtherItemsAndMetadataAreKept() {
        let original = thread([.user("hi"), .assistant("hello"), .tool("Edited b.ts", ok: false)])
        let restored = original.restoredAfterQuit()
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.agent, "claude")
        XCTAssertEqual(restored.items.map(\.id), original.items.map(\.id))
        guard case .assistant(let text) = restored.items[1].kind else { return XCTFail("assistant item expected") }
        XCTAssertEqual(text, "hello")
    }
}
