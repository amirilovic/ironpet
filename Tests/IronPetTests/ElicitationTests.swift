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

@MainActor
final class ElicitationPagerTests: XCTestCase {
    private func form(questions: Int, required: Set<String> = []) throws -> ElicitationForm {
        var properties: JSON = [:]
        for index in 0..<questions {
            properties["question_\(index)"] = ["type": "string", "title": "Q\(index)", "oneOf": [["const": "A", "title": "A"], ["const": "B", "title": "B"]]] as JSON
            properties["question_\(index)_custom"] = ["type": "string", "title": "Other"] as JSON
        }
        let schema: JSON = ["type": "object", "properties": properties, "required": Array(required)]
        return try XCTUnwrap(ElicitationForm.parse(["mode": "form", "message": "m", "requestedSchema": schema]))
    }

    func testEachQuestionIsOnePageWithItsOtherField() throws {
        let pages = try form(questions: 4).pages
        XCTAssertEqual(pages.count, 4)
        XCTAssertEqual(pages[1].map(\.id), ["question_1", "question_1_custom"])
    }

    func testFirstPageStartsWithBackDisabled() throws {
        let pager = ElicitationPager(pageCount: try form(questions: 4).pages.count)
        XCTAssertEqual(pager.label, "1 of 4")
        XCTAssertTrue(pager.isPaged)
        XCTAssertFalse(pager.canGoBack)
        XCTAssertTrue(pager.canGoForward)
    }

    func testMovingKeepsAnswersAndStopsAtTheEnds() throws {
        let form = try form(questions: 3)
        var pager = ElicitationPager(pageCount: form.pages.count)
        let answers: ElicitationAnswers = ["question_0": .one("A"), "question_1_custom": .text("mine")]
        pager.back()
        XCTAssertEqual(pager.index, 0)
        pager.forward(); pager.forward(); pager.forward()
        XCTAssertEqual(pager.label, "3 of 3")
        XCTAssertTrue(pager.isLast)
        pager.back()
        XCTAssertEqual(pager.index, 1)
        XCTAssertEqual(form.content(answers)["question_0"] as? String, "A")
        XCTAssertEqual(form.content(answers)["question_1_custom"] as? String, "mine")
    }

    func testFormsThatAreNotQuestionsStayOnOnePage() throws {
        let properties: JSON = ["name": ["type": "string"] as JSON, "age": ["type": "integer"] as JSON, "ok": ["type": "boolean"] as JSON]
        let form = try XCTUnwrap(ElicitationForm.parse(["mode": "form", "message": "m", "requestedSchema": ["type": "object", "properties": properties]]))
        XCTAssertEqual(form.pages.count, 1)
        XCTAssertEqual(form.pages[0].count, 3)
        XCTAssertFalse(ElicitationPager(pageCount: form.pages.count).isPaged)
        var mixed: JSON = ["question_0": ["type": "string"] as JSON, "question_1": ["type": "string"] as JSON, "extra": ["type": "string"] as JSON]
        mixed["question_2"] = ["type": "string"] as JSON
        let mixedForm = try XCTUnwrap(ElicitationForm.parse(["mode": "form", "message": "m", "requestedSchema": ["type": "object", "properties": mixed]]))
        XCTAssertEqual(mixedForm.pages.count, 1)
    }

    func testSingleQuestionIsNotPaged() throws {
        XCTAssertFalse(ElicitationPager(pageCount: try form(questions: 1).pages.count).isPaged)
    }

    func testSubmitPayloadIsTheSameAsForTheWholeForm() throws {
        let form = try form(questions: 4)
        let answers: ElicitationAnswers = ["question_0": .one("A"), "question_3": .one("B"), "question_2_custom": .text("x")]
        let content = form.content(answers)
        XCTAssertEqual(Set(content.keys), ["question_0", "question_3", "question_2_custom"])
        XCTAssertTrue(form.canSubmit(answers))
        XCTAssertNil(form.firstIncompletePage(answers))
    }

    func testSubmitJumpsToTheFirstUnansweredRequiredQuestion() throws {
        let form = try form(questions: 4, required: ["question_1", "question_3"])
        XCTAssertEqual(form.firstIncompletePage(["question_3": .one("A")]), 1)
        XCTAssertEqual(form.firstIncompletePage(["question_1": .one("A")]), 3)
    }
}
