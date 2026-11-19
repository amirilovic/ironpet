import XCTest
@testable import IronPet

@MainActor
final class SendVoiceOnlyTests: XCTestCase {
    private var sent: [String] = []
    private var session: ChatSession!
    private var h: ChatHarness!

    override func setUp() {
        TestMemory.isolate()
        h = ChatHarness(); session = h.session
        h.model.sendAfterDictation = true
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
        let old = h.model.input
        h.model.input = new
        h.model.inputChanged(from: old, to: new)
    }

    func testPasteIsNeverSent() async {
        for text in ["word", "a long paragraph of pasted text that goes on", "line one\nline two\nline three"] {
            h.model.input = ""
            edit(to: text)
            await settle()
            XCTAssertEqual(h.model.input, text)
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
        XCTAssertEqual(h.model.input, "hello there")
    }

    func testVoiceNoteSendsExactlyOnce() async {
        h.model.receiveTranscript("hello from voice")
        await settle()
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].contains("hello from voice"))
    }

    func testVoiceNoteWithToggleOffOnlyFillsInput() async {
        h.model.sendAfterDictation = false
        h.model.receiveTranscript("hello from voice")
        await settle()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(h.model.input, "hello from voice")
    }

    func testWisprDictationIsInsertedNotSent() async {
        h.model.receiveDictation("dictated words here")
        await settle()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(h.model.input, "dictated words here")
    }

    func testPrefillIsNotSent() async {
        h.model.prefill("Explain this error in detail")
        h.model.inputChanged(from: "", to: h.model.input)
        await settle()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(h.model.input, "Explain this error in detail")
    }

    func testSlashCommandPickIsNotSent() async {
        session.receiveCommands([SlashCommand(name: "compact", detail: "Shrink")])
        await h.model.settle()
        edit(to: "/co")
        XCTAssertTrue(h.model.completeSlash())
        await settle()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(h.model.input, "/compact ")
    }
}
