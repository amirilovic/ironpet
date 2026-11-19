import XCTest
@testable import IronPet

@MainActor
final class TelegramFormTests: XCTestCase {
    private var client: FakeTelegram!
    private var session: ChatSession!
    private var chatAPI: ChatAPI!
    private var bridge: TelegramBridge!
    private var store: UserStore!
    private var replies: [ElicitationReply] = []
    private var updateID = 100

    override func setUp() async throws {
        TestMemory.isolate()
        client = FakeTelegram()
        session = ChatSession(restore: false)
        chatAPI = ChatAPI(session: session)
        store = UserStore()
        store.users.append(.init(id: 10, name: "Ann", username: "ann"))
        replies = []
        let store = store!
        bridge = TelegramBridge(
            client: client, host: chatAPI, tokens: MemoryTokenStore(),
            storage: .init(users: { store.users }, add: { store.users.append($0) },
                           remove: { id in store.users.removeAll { $0.id == id } },
                           offset: { store.offset }, setOffset: { store.offset = $0 }),
            filesDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("tg-form-\(UUID().uuidString)"),
            voiceEnabled: { false }, sleep: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) })
    }

    private func options(_ names: [String]) -> [JSON] { names.map { ["const": $0, "title": $0.uppercased()] } }

    private func threeQuestions() -> ElicitationForm {
        ElicitationForm.parse([
            "mode": "form", "message": "Please answer the following questions.",
            "requestedSchema": ["type": "object", "required": ["question_0"], "properties": [
                "question_0": ["type": "string", "title": "Runner", "description": "Which runner?", "oneOf": options(["a", "b"])],
                "question_0_custom": ["type": "string", "title": "Other"],
                "question_1": ["type": "string", "title": "Mode", "oneOf": options(["x", "y", "z"])],
                "question_2": ["type": "string", "title": "Size", "oneOf": options(["s", "m"])],
            ] as JSON],
        ])!
    }

    private func otherForm() -> ElicitationForm {
        ElicitationForm.parse([
            "mode": "form", "message": "More",
            "requestedSchema": ["type": "object", "required": ["checks", "name", "count"], "properties": [
                "checks": ["type": "array", "title": "Checks", "items": ["anyOf": options(["lint", "build", "test"])]],
                "count": ["type": "number", "title": "Count"],
                "name": ["type": "string", "title": "Name"],
            ] as JSON],
        ])!
    }

    private func open(_ form: ElicitationForm) async {
        session.handleElicitation(form) { [unowned self] reply in replies.append(reply) }
        await bridge.flush()
    }

    private func tap(_ data: String, from: Int64 = 10) -> TelegramUpdate {
        updateID += 1
        return TelegramUpdate(updateId: updateID, callbackQuery: TelegramCallback(
            id: "cb\(updateID)", from: TelegramUser(id: from, isBot: false, firstName: "Ann", lastName: nil, username: nil),
            message: TelegramMessage(messageId: 1, from: nil, chat: .init(id: from, type: "private"), text: nil), data: data))
    }

    private func answer(_ data: String, from: Int64 = 10) async {
        bridge.handle(tap(data, from: from))
        await bridge.flush()
    }

    private func typed(_ text: String, replyingTo messageID: Int64) async {
        var update = telegramMessage(text, from: 10)
        update.message?.replyToMessage = .init(from: nil, text: "question", messageId: messageID)
        bridge.handle(update)
        await bridge.flush()
    }

    private func data(_ message: FakeTelegram.Sent, _ title: String) -> String {
        message.buttons.first { $0.text == title }!.data
    }

    // MARK: S1

    func testFormIsShownAsHeaderAndOneMessagePerQuestion() async {
        await open(threeQuestions())
        XCTAssertEqual(client.sent.count, 4)
        XCTAssertTrue(client.sent[0].text.hasPrefix("Please answer the following questions."))
        XCTAssertEqual(client.sent[0].buttons.map(\.text), ["Skip form"])
        XCTAssertEqual(client.sent[1].buttons.map(\.text), ["A", "B"])
        XCTAssertEqual(client.sent[2].buttons.map(\.text), ["X", "Y", "Z", "Skip"])
        XCTAssertEqual(client.sent[3].buttons.map(\.text), ["S", "M", "Skip"])
        XCTAssertEqual(client.sent[1].keyboard.count, 2, "one option per row")
        XCTAssertTrue(client.sent[1].text.contains("Which runner?"))
        XCTAssertTrue(client.sent[1].text.contains("reply to this message"))
        for message in client.sent { for button in message.buttons { XCTAssertLessThanOrEqual(button.data.utf8.count, 64) } }
    }

    // MARK: S2

    func testTappingEveryQuestionSubmitsLikeTheMac() async {
        let form = threeQuestions()
        await open(form)
        let sent = client.sent
        await answer(data(sent[1], "A"))
        XCTAssertTrue(replies.isEmpty)
        await answer(data(sent[2], "Y"))
        await answer(data(sent[3], "Skip"))
        let expected = form.content(["question_0": .one("a"), "question_1": .one("y")])
        XCTAssertEqual(replies, [.accept(expected)])
        XCTAssertTrue(session.forms.isEmpty)
        guard case .form(let record)? = session.items.last?.kind else { return XCTFail("no record") }
        XCTAssertFalse(record.skipped)
        XCTAssertEqual(record.lines.map(\.answer), ["A", "Y"])
        let edits = client.edits.map(\.text)
        XCTAssertTrue(edits.contains { $0.contains("Answer: A") })
        XCTAssertTrue(edits.contains { $0.contains("Answer: Y") })
        XCTAssertTrue(edits.contains { $0.contains("Answer: Skipped") })
        XCTAssertTrue(edits.contains { $0.hasSuffix("Answered.") })
        XCTAssertTrue(client.edits.allSatisfy { $0.keyboard.isEmpty })
    }

    func testOtherReplyFillsTheCustomField() async {
        let form = threeQuestions()
        await open(form)
        let first: Int64 = 502
        await typed("my own", replyingTo: first)
        await answer(data(client.sent[1], "B"))
        await answer(data(client.sent[2], "X"))
        await answer(data(client.sent[3], "M"))
        XCTAssertEqual(replies, [.accept(form.content(["question_0": .one("b"), "question_0_custom": .text("my own"),
                                                      "question_1": .one("x"), "question_2": .one("m")]))])
    }

    // MARK: S3

    func testAnsweredOnTheMacClosesTheTelegramMessages() async {
        await open(threeQuestions())
        let sent = client.sent
        let id = session.forms[0].id
        session.setAnswer(form: id, field: "question_0", .one("a"))
        session.skipForm(id)
        await bridge.flush()
        XCTAssertEqual(client.edits.count, 4)
        XCTAssertTrue(client.edits.allSatisfy { $0.keyboard.isEmpty && $0.text.hasSuffix("Skipped on the Mac.") })
        await answer(data(sent[1], "A"))
        XCTAssertEqual(client.answers.last, "This form is no longer open.")
        XCTAssertEqual(replies, [.decline])
    }

    func testSubmittedOnTheMacSaysAnswered() async {
        await open(threeQuestions())
        let id = session.forms[0].id
        session.setAnswer(form: id, field: "question_0", .one("a"))
        session.submitForm(id)
        await bridge.flush()
        XCTAssertTrue(client.edits.allSatisfy { $0.text.hasSuffix("Answered on the Mac.") })
    }

    // MARK: S4

    func testMultiSelectTogglesAndDone() async {
        let form = otherForm()
        await open(form)
        let sent = client.sent
        XCTAssertEqual(sent[1].buttons.map(\.text), ["LINT", "BUILD", "TEST", "Done"])
        await answer(data(sent[1], "TEST"))
        await answer(data(sent[1], "LINT"))
        XCTAssertEqual(client.edits.last?.keyboard.flatMap { $0 }.map(\.text), ["✓ LINT", "BUILD", "✓ TEST", "Done"])
        await answer(data(sent[1], "Done"))
        await typed("not a number", replyingTo: 503)
        XCTAssertEqual(client.sent.last?.text, "That is not a number. Reply with a number, like 3 or 2.5.")
        XCTAssertTrue(session.forms[0].answers["count"] == nil)
        await typed("4", replyingTo: 503)
        await typed("Ann", replyingTo: 504)
        XCTAssertEqual(replies, [.accept(form.content(["checks": .many(["lint", "test"]), "count": .text("4"), "name": .text("Ann")]))])
        XCTAssertEqual(replies.first?.json["content"].flatMap { $0 as? JSON }?["checks"] as? [String], ["lint", "test"])
    }

    // MARK: S5

    func testSkipFormDeclines() async {
        await open(threeQuestions())
        await answer(data(client.sent[0], "Skip form"))
        XCTAssertEqual(replies, [.decline])
        guard case .form(let record)? = session.items.last?.kind else { return XCTFail("no record") }
        XCTAssertTrue(record.skipped)
        XCTAssertTrue(client.edits.allSatisfy { $0.keyboard.isEmpty })
    }

    // MARK: S6

    func testAnotherUserCannotAnswer() async {
        await open(threeQuestions())
        await answer(data(client.sent[1], "A"), from: 99)
        XCTAssertEqual(client.answers.last, "Not authorised.")
        XCTAssertTrue(session.forms[0].answers.isEmpty)
        XCTAssertTrue(replies.isEmpty)
    }

    func testStaleFormNumberIsRejected() async {
        await open(threeQuestions())
        await answer("f:99:0:0")
        XCTAssertEqual(client.answers.last, "This form is no longer open.")
    }

    func testCallbackDataRoundTrips() {
        for tap in [TelegramFormTap.skipForm, .option(field: 3, option: 12), .skip(field: 1), .done(field: 0)] {
            let parsed = TelegramFormLayout.parse(TelegramFormLayout.data(form: 7, tap))
            XCTAssertEqual(parsed?.form, 7)
            XCTAssertEqual(parsed?.tap, tap)
        }
        XCTAssertNil(TelegramFormLayout.parse("a:1:2"))
    }
}
