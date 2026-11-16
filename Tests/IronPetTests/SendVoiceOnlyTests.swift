import XCTest
@testable import IronPet

@MainActor
final class SendVoiceOnlyTests: XCTestCase {
    private var sent: [String] = []
    private var session: ChatSession!

    override func setUp() {
        session = ChatSession(restore: false)
        session.sendAfterDictation = true
        session.workspace = FileManager.default.temporaryDirectory
        sent = []
        session.turnRunner = { turn, emit in
            await MainActor.run {
                self.sent.append(turn.prompt)
                emit(.finished(error: nil))
            }
        }
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 1_200_000_000)
    }

    private func edit(to new: String) {
        let old = session.input
        session.input = new
        session.inputChanged(from: old, to: new)
    }

    func testPasteIsNeverSent() async {
        for text in ["word", "a long paragraph of pasted text that goes on", "line one\nline two\nline three"] {
            session.input = ""
            edit(to: text)
            await settle()
            XCTAssertEqual(session.input, text)
        }
        XCTAssertTrue(sent.isEmpty)
    }

    func testTypingIsNeverSent() async {
        var text = ""
        for ch in "hello there" {
            text.append(ch)
            edit(to: text)
        }
        await settle()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(session.input, "hello there")
    }

    func testVoiceNoteSendsExactlyOnce() async {
        session.receiveTranscript("hello from voice")
        await settle()
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].contains("hello from voice"))
    }

    func testVoiceNoteWithToggleOffOnlyFillsInput() async {
        session.sendAfterDictation = false
        session.receiveTranscript("hello from voice")
        await settle()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(session.input, "hello from voice")
    }

    func testWisprDictationIsInsertedNotSent() async {
        session.receiveDictation("dictated words here")
        await settle()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(session.input, "dictated words here")
    }

    func testPrefillIsNotSent() async {
        session.prefill("Explain this error in detail")
        session.inputChanged(from: "", to: session.input)
        await settle()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(session.input, "Explain this error in detail")
    }

    func testSlashCommandPickIsNotSent() async {
        session.receiveCommands([SlashCommand(name: "compact", detail: "Shrink")])
        edit(to: "/co")
        XCTAssertTrue(session.completeSlash())
        await settle()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(session.input, "/compact ")
    }
}
