import XCTest
@testable import IronPet

@MainActor
final class ChatSendButtonTests: XCTestCase {
    private var session: ChatViewModel!

    override func setUp() async throws {
        TestMemory.isolate()
        session = ChatHarness().model
    }

    func testEmptyInputCannotSend() {
        session.input = ""
        XCTAssertFalse(session.canSend)
    }

    func testWhitespaceOnlyCannotSend() {
        session.input = "  \n\t "
        XCTAssertFalse(session.canSend)
    }

    func testTypedCharacterCanSendAndClearingHidesIt() {
        session.input = "a"
        XCTAssertTrue(session.canSend)
        session.input = ""
        XCTAssertFalse(session.canSend)
    }

    func testAttachmentAloneCanSend() {
        session.input = ""
        session.attachments = [URL(fileURLWithPath: "/tmp/x.png")]
        XCTAssertTrue(session.canSend)
    }
}
