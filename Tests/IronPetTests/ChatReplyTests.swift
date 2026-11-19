import XCTest
@testable import IronPet

@MainActor
final class ChatReplyTests: XCTestCase {
    private var session: ChatSession!
    private var h: ChatHarness!
    private var turns: [ACPTurn] = []

    override func setUp() async throws {
        TestMemory.isolate()
        h = ChatHarness(); session = h.session
        turns = []
        session.workspace = FileManager.default.temporaryDirectory
        session.turnRunner = { [unowned self] turn, _ in turns.append(turn) }
    }

    private func settle() async {
        for _ in 0..<200 where turns.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func assistantItem(_ text: String) -> ChatSession.Item {
        let item = ChatSession.Item(kind: .assistant(text), date: Date(timeIntervalSince1970: 0))
        session.items.append(item)
        return item
    }

    func testReplyingToAnAssistantMessageSetsTheChipAndOnlyOneAtATime() {
        let first = assistantItem("first answer")
        let second = assistantItem("second answer")
        h.model.reply(to: first)
        XCTAssertEqual(h.model.replyingTo?.itemID, first.id)
        XCTAssertEqual(h.model.replyingTo?.text, "first answer")
        let tick = h.model.replyFocusTick
        h.model.reply(to: second)
        XCTAssertEqual(h.model.replyingTo?.itemID, second.id)
        XCTAssertGreaterThan(h.model.replyFocusTick, tick)
        h.model.replyingTo = nil
        XCTAssertNil(h.model.replyingTo)
    }

    func testToolStepsAndErrorsCannotBeRepliedTo() {
        h.model.reply(to: ChatSession.Item(kind: .tool("Ran `ls`", ok: true)))
        h.model.reply(to: ChatSession.Item(kind: .error("boom")))
        XCTAssertNil(h.model.replyingTo)
    }

    func testSendPutsTheFullOriginalAheadOfTheTextAndClearsTheChip() async {
        let original = assistantItem("line one\nline two\nline three")
        h.model.reply(to: original)
        h.model.input = "what about this?"
        await h.model.sendNow()
        await settle()
        XCTAssertNil(h.model.replyingTo)
        let prompt = turns.first?.prompt ?? ""
        XCTAssertTrue(prompt.hasPrefix("> Replying to "), prompt)
        XCTAssertTrue(prompt.contains("> line one\n> line two\n> line three"), prompt)
        XCTAssertTrue(prompt.hasSuffix("\n\nwhat about this?"), prompt)
        // The transcript keeps the user's own words and the reference, not the quoted block.
        guard case .user(let shown) = session.items.last?.kind else { return XCTFail("user item expected") }
        XCTAssertEqual(shown, "what about this?")
        XCTAssertEqual(session.items.last?.reply?.itemID, original.id)
    }

    func testAnOriginalOverTheLimitIsCutInThePromptButKeptWhole() async {
        let long = String(repeating: "a", count: ChatSession.replyLimit + 500)
        h.model.reply(to: assistantItem(long))
        h.model.input = "and?"
        await h.model.sendNow()
        await settle()
        let prompt = turns.first?.prompt ?? ""
        XCTAssertFalse(prompt.contains(long))
        XCTAssertTrue(prompt.contains(String(repeating: "a", count: ChatSession.replyLimit)))
        XCTAssertTrue(prompt.contains("was cut"), prompt)
        XCTAssertEqual(session.items.last?.reply?.text.count, long.count)
    }

    func testReplyOnAMessageSentWhileBusySurvivesTheQueue() async {
        h.model.input = "start"
        await h.model.sendNow()
        await settle()
        h.model.reply(to: assistantItem("earlier"))
        h.model.input = "queued reply"
        await h.model.sendNow()
        XCTAssertEqual(session.queue.first?.reply?.text, "earlier")
        XCTAssertNil(h.model.replyingTo)
    }

    func testReplySurvivesSavingAndReopeningAThread() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reply-threads-\(UUID().uuidString)")
        let saved = ThreadStore.directory
        ThreadStore.directory = folder
        defer { ThreadStore.directory = saved; try? FileManager.default.removeItem(at: folder) }
        let reply = ChatSession.Reply(itemID: UUID(), sender: "Ghost", text: "the original", date: Date(timeIntervalSince1970: 100))
        let thread = ChatThread(id: "t-reply", title: "Chat", workspace: "/tmp", updatedAt: Date(),
                                items: [ChatSession.Item(kind: .user("answer", ), reply: reply)], agent: "claude")
        ThreadStore.save(thread)
        let loaded = try XCTUnwrap(ThreadStore.load("t-reply")).restoredAfterQuit()
        XCTAssertEqual(loaded.items.first?.reply, reply)
    }

    func testThreadsSavedBeforeRepliesStillLoad() throws {
        let item = ChatSession.Item(kind: .user("old"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json["reply"] = nil
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(try JSONDecoder().decode(ChatSession.Item.self, from: data).reply)
    }

    func testAskingAboutASelectionSendsOnlyTheSelectedText() async {
        let original = assistantItem("intro line\nthe part I care about\noutro line that must not be sent")
        h.model.reply(to: original, selection: "  the part I care about ")
        XCTAssertEqual(h.model.replyingTo?.text, "the part I care about")
        h.model.input = "why this?"
        await h.model.sendNow()
        await settle()
        let prompt = turns.first?.prompt ?? ""
        XCTAssertTrue(prompt.hasPrefix("> About this part of "), prompt)
        XCTAssertTrue(prompt.contains("> the part I care about\n\nwhy this?"), prompt)
        XCTAssertFalse(prompt.contains("intro line"), prompt)
        XCTAssertFalse(prompt.contains("outro"), prompt)
        XCTAssertEqual(session.items.last?.reply?.itemID, original.id)
    }

    func testAnEmptySelectionFallsBackToTheWholeMessage() {
        let original = assistantItem("whole message")
        h.model.reply(to: original, selection: "   ")
        XCTAssertEqual(h.model.replyingTo?.text, "whole message")
        XCTAssertNil(h.model.replyingTo?.selection)
    }
}
