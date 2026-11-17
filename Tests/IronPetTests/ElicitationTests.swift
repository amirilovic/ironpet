import XCTest
@testable import IronPet

@MainActor
final class ElicitationTests: XCTestCase {
    /// The shape `askUserQuestionsToCreateRequest` produces for two questions.
    private let askParams: JSON = [
        "mode": "form", "sessionId": "s1", "message": "Please answer the following questions.",
        "requestedSchema": ["type": "object", "properties": [
            "question_0": ["type": "string", "title": "Library", "description": "Which library?",
                           "oneOf": [["const": "A", "title": "A", "description": "the first"], ["const": "B", "title": "B"]]],
            "question_0_custom": ["type": "string", "title": "Other", "description": "Type your own answer."],
            "question_1": ["type": "array", "title": "Checks", "description": "Which checks?",
                           "items": ["anyOf": [["const": "lint", "title": "lint"], ["const": "test", "title": "test", "description": "slow"]]]],
            "question_1_custom": ["type": "string", "title": "Other"],
        ]],
    ]

    func testAskUserQuestionFormHasRadiosCheckboxesAndTwoOtherFields() throws {
        let form = try XCTUnwrap(ElicitationForm.parse(askParams))
        XCTAssertEqual(form.fields.map(\.id), ["question_0", "question_0_custom", "question_1", "question_1_custom"])
        guard case .single(let radios) = form.fields[0].kind, case .multi(let boxes) = form.fields[2].kind else { return XCTFail("kinds") }
        XCTAssertEqual(radios.map(\.value), ["A", "B"])
        XCTAssertEqual(radios[0].detail, "the first")
        XCTAssertEqual(boxes.map(\.value), ["lint", "test"])
        XCTAssertEqual(form.fields[1].kind, .text)
        XCTAssertEqual(form.fields[3].kind, .text)
    }

    func testFieldsKeepNumericOrderPastNine() throws {
        var properties: JSON = [:]
        for index in [0, 2, 10, 9] { properties["question_\(index)"] = ["type": "string"] as JSON }
        let form = try XCTUnwrap(ElicitationForm.parse(["mode": "form", "message": "m", "requestedSchema": ["type": "object", "properties": properties]]))
        XCTAssertEqual(form.fields.map(\.id), ["question_0", "question_2", "question_9", "question_10"])
    }

    func testAcceptContentHasLabelsAndListsAndCustomOnlyWhenFilled() throws {
        let form = try XCTUnwrap(ElicitationForm.parse(askParams))
        let answers: ElicitationAnswers = ["question_0": .one("B"), "question_1": .many(["test", "lint"]), "question_1_custom": .text(" Both ")]
        let reply = ElicitationReply.accept(form.content(answers)).json
        XCTAssertEqual(reply["action"] as? String, "accept")
        let content = try XCTUnwrap(reply["content"] as? JSON)
        XCTAssertEqual(content["question_0"] as? String, "B")
        XCTAssertEqual(content["question_1"] as? [String], ["lint", "test"])
        XCTAssertEqual(content["question_1_custom"] as? String, "Both")
        XCTAssertNil(content["question_0_custom"])
    }

    func testSkipAndCancelRepliesCarryOnlyTheAction() {
        XCTAssertEqual(ElicitationReply.decline.json as NSDictionary, ["action": "decline"])
        XCTAssertEqual(ElicitationReply.cancel.json as NSDictionary, ["action": "cancel"])
    }

    func testUnsupportedSchemasAreNotParsed() {
        let nested: JSON = ["mode": "form", "message": "m", "requestedSchema": ["type": "object", "properties": ["x": ["type": "object"]]]]
        XCTAssertNil(ElicitationForm.parse(nested))
        XCTAssertNil(ElicitationForm.parse(["mode": "url", "message": "m", "url": "https://example.com"]))
        let objects: JSON = ["mode": "form", "message": "m", "requestedSchema": ["type": "object", "properties": ["x": ["type": "array", "items": ["type": "object"]]]]]
        XCTAssertNil(ElicitationForm.parse(objects))
    }

    func testGenericFieldsAndRequiredFieldsGateSubmit() throws {
        let params: JSON = ["mode": "form", "message": "Server settings", "requestedSchema": [
            "type": "object", "required": ["name"],
            "properties": ["name": ["type": "string"], "count": ["type": "integer"], "on": ["type": "boolean"],
                           "mode": ["type": "string", "enum": ["fast", "safe"], "enumNames": ["Fast", "Safe"]]]]]
        let form = try XCTUnwrap(ElicitationForm.parse(params))
        XCTAssertFalse(form.canSubmit([:]))
        XCTAssertFalse(form.canSubmit(["name": .text("x"), "count": .text("abc")]))
        let answers: ElicitationAnswers = ["name": .text("x"), "count": .text("3"), "on": .flag(true), "mode": .one("safe")]
        XCTAssertTrue(form.canSubmit(answers))
        let content = form.content(answers)
        XCTAssertEqual(content["count"] as? Int, 3)
        XCTAssertEqual(content["on"] as? Bool, true)
        XCTAssertEqual(form.lines(answers).first { $0.question == "mode" }?.answer, "Safe")
    }

    // MARK: Chat session

    func testSubmittingTheCardRepliesAndLeavesAReadOnlyRecord() throws {
        let session = ChatSession(restore: false)
        let form = try XCTUnwrap(ElicitationForm.parse(askParams))
        var reply: ElicitationReply?
        session.handleElicitation(form) { reply = $0 }
        let id = try XCTUnwrap(session.forms.first?.id)
        session.setAnswer(form: id, field: "question_0", .one("A"))
        session.submitForm(id)
        XCTAssertTrue(session.forms.isEmpty)
        XCTAssertEqual(reply, .accept(["question_0": "A"]))
        guard case .form(let record)? = session.items.last?.kind else { return XCTFail("no record") }
        XCTAssertFalse(record.skipped)
        XCTAssertEqual(record.lines.map(\.answer), ["A"])
    }

    func testSkippingTheCardDeclines() throws {
        let session = ChatSession(restore: false)
        var reply: ElicitationReply?
        session.handleElicitation(try XCTUnwrap(ElicitationForm.parse(askParams))) { reply = $0 }
        session.skipForm(try XCTUnwrap(session.forms.first?.id))
        XCTAssertEqual(reply, .decline)
        guard case .form(let record)? = session.items.last?.kind else { return XCTFail("no record") }
        XCTAssertTrue(record.skipped)
    }

    func testStopCancelsOpenForms() throws {
        let session = ChatSession(restore: false)
        var reply: ElicitationReply?
        session.handleElicitation(try XCTUnwrap(ElicitationForm.parse(askParams))) { reply = $0 }
        session.stop()
        XCTAssertEqual(reply, .cancel)
        XCTAssertTrue(session.forms.isEmpty)
    }

    func testAHiddenChatAnnouncesTheQuestion() throws {
        let session = ChatSession(restore: false)
        var announced: String?
        session.onFormNeeded = { _, detail in announced = detail }
        session.isVisible = false
        session.handleElicitation(try XCTUnwrap(ElicitationForm.parse(askParams))) { _ in }
        XCTAssertEqual(announced, "Please answer the following questions.")
    }
}
