import XCTest
@testable import IronPet

/// Real-use cases from the installed build: duplicates in one batch, interface text taken for work, invented due dates and quotes that are
/// only a fragment of the question.
final class CaptureProposalChecksTests: XCTestCase {
    private func item(_ id: Int64, _ body: String, app: String = "Band") -> CaptureStore.Item {
        CaptureStore.Item(id: id, threadId: id, threadKey: "k\(id)", threadTitle: "t", app: "app.getband.agent", appName: app, kind: "conversation", at: Date(),
                          version: 1, body: body, state: "ready")
    }

    private func proposals(_ answer: String, items: [CaptureStore.Item], tasks: [CaptureTask] = []) -> [CaptureProposal] {
        CaptureAnalyzer.proposals(from: answer, items: items, tasks: tasks, store: CaptureStore.inMemory())
    }

    // MARK: Duplicates

    func testTheSamePRAsATaskAndAFollowUpIsOneSuggestion() {
        let body = "Agent: PR #4641 (SSP-11671) is ready.\nAgent: Should I rebase or merge to fix the PR #4641 history?"
        let answer = """
            {"new_tasks":[{"title":"Review PR #4641 (SSP-11671) and merge once CI is green","source_items":[1],"quote":"PR #4641 (SSP-11671) is ready."}],
             "follow_ups":[{"title":"Choose rebase or merge to fix the PR #4641 history","source_items":[1],"quote":"Should I rebase or merge to fix the PR #4641 history?"}]}
            """
        let out = proposals(answer, items: [item(1, body)])
        XCTAssertEqual(out.count, 1, "\(out.map(\.title))")
        XCTAssertEqual(out.first?.kind, .newTask)
        XCTAssertEqual(out.first?.sources, [1])
    }

    func testDuplicatesWithoutANumberMergeWhenTheTitlesAreClose() {
        let body = "Ana: Please send the quarterly report to finance.\nAna: Did you send the quarterly report to finance?"
        let answer = """
            {"new_tasks":[{"title":"Send the quarterly report to finance","source_items":[1],"quote":"Please send the quarterly report to finance."}],
             "follow_ups":[{"title":"Send quarterly report to finance","source_items":[1],"quote":"Did you send the quarterly report to finance?"}]}
            """
        XCTAssertEqual(proposals(answer, items: [item(1, body)]).count, 1)
        let different = """
            {"new_tasks":[{"title":"Send the quarterly report to finance","source_items":[1],"quote":"Please send the quarterly report to finance."},
                          {"title":"Book the dentist","source_items":[2],"quote":"Book the dentist"}]}
            """
        XCTAssertEqual(proposals(different, items: [item(1, body), item(2, "Me: Book the dentist")]).count, 2, "different things stay apart")
    }

    func testASuggestionIsMatchedAgainstOpenTasksByTicketOrPRNumber() {
        let tasks = [CaptureTask(id: "review-pr", title: "Review PR #4641 and merge", notes: "SSP-11671", due: nil)]
        let answer = """
            {"follow_ups":[{"title":"Decide how to fix the history of pull request 4641","source_items":[1],"quote":"Should I rebase or merge to fix the PR #4641 history?"}]}
            """
        XCTAssertTrue(proposals(answer, items: [item(1, "Agent: Should I rebase or merge to fix the PR #4641 history?")], tasks: tasks).isEmpty)
        let other = """
            {"follow_ups":[{"title":"Reply to Dana about the offsite","source_items":[1],"quote":"Can you reply about the offsite?"}]}
            """
        XCTAssertEqual(proposals(other, items: [item(1, "Dana: Can you reply about the offsite?")], tasks: tasks).count, 1)
    }

    func testANewTalkAboutDoneWorkIsNotHiddenUnlessTheTitleIsTheSame() {
        let done = [CaptureTask(id: "old", title: "Review PR #4641", notes: "", due: nil, isDone: true)]
        let answer = """
            {"follow_ups":[{"title":"Answer whether PR #4641 needs a revert","source_items":[1],"quote":"Does PR #4641 need a revert?"}]}
            """
        XCTAssertEqual(proposals(answer, items: [item(1, "Agent: Does PR #4641 need a revert?")], tasks: done).count, 1)
    }

    // MARK: Interface text

    func testAButtonLabelAndAnAgentErrorAreNotTasks() {
        let body = "Retry last message\nSend\nStop\nError: the agent stopped (rate limit)"
        for quote in ["Retry last message", "Send", "Stop", "Error: the agent stopped (rate limit)"] {
            let answer = """
                {"new_tasks":[{"title":"Retry the stabilise-flaky-tests agent","source_items":[1],"quote":"\(quote)"}]}
                """
            XCTAssertTrue(proposals(answer, items: [item(1, body)]).isEmpty, quote)
        }
        // A real sentence that starts with a label word is fine.
        let real = """
            {"new_tasks":[{"title":"Send the invoice","source_items":[1],"quote":"Send the invoice to Dana"}]}
            """
        XCTAssertEqual(proposals(real, items: [item(1, "Ana: Send the invoice to Dana")]).count, 1)
    }

    // MARK: Due dates

    func testADueDateNeedsADateInTheText() {
        let body = "Agent: Do you want to resolve the Better Stack patterns?"
        let answer = """
            {"follow_ups":[{"title":"Answer whether to resolve the Better Stack patterns","due":"2026-11-23","source_items":[1],"quote":"Do you want to resolve the Better Stack patterns?"}]}
            """
        let out = proposals(answer, items: [item(1, body)])
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out.first?.due, "there is no date in the source")
    }

    func testStatedAndRelativeDatesAreKept() {
        func due(_ text: String, _ value: String) -> String? {
            let answer = """
                {"new_tasks":[{"title":"Do the thing","due":"\(value)","source_items":[1],"quote":"\(text)"}]}
                """
            return proposals(answer, items: [item(1, "Ana: \(text)")]).first?.due
        }
        XCTAssertEqual(due("Please send it by 2026-11-23.", "2026-11-23"), "2026-11-23")
        XCTAssertEqual(due("Please send it by Nov 23.", "2026-11-23"), "2026-11-23")
        XCTAssertEqual(due("Please send it by 23 November.", "2026-11-23"), "2026-11-23")
        XCTAssertEqual(due("Please send it by 23.11.", "2026-11-23"), "2026-11-23")
        XCTAssertEqual(due("Please send it tomorrow.", "2026-11-17"), "2026-11-17")
        XCTAssertEqual(due("Please send it by Friday.", "2026-11-20"), "2026-11-20")
        XCTAssertEqual(due("Pošalji do petka.", "2026-11-20"), "2026-11-20")
        XCTAssertEqual(due("Please send it in 3 days.", "2026-11-19"), "2026-11-19")
        XCTAssertNil(due("Please send it by Nov 24.", "2026-11-23"), "a different day than the text says")
        XCTAssertNil(due("Please send it soon.", "2026-11-23"))
    }

    func testAnUpdateDoesNotMoveADueDateTheTextDoesNotState() {
        let tasks = [CaptureTask(id: "t1", title: "File taxes", notes: "", due: nil)]
        let answer = """
            {"updates":[{"task_id":"t1","due":"2026-12-01","source_items":[1],"quote":"Have you started the tax filing?"}]}
            """
        XCTAssertTrue(proposals(answer, items: [item(1, "Ana: Have you started the tax filing?")], tasks: tasks).isEmpty, "nothing else changes")
    }

    // MARK: Quotes

    func testAFragmentOfAQuestionBecomesTheWholeQuestion() {
        let body = "Agent: I finished the first PR. Do you want me to merge it now, or wait and open the other two once the build is green?"
        let answer = """
            {"follow_ups":[{"title":"Decide on the other two PRs","source_items":[1],"quote":"the other two once the build is green?"}]}
            """
        let out = proposals(answer, items: [item(1, body)])
        XCTAssertEqual(out.first?.quote, "Do you want me to merge it now, or wait and open the other two once the build is green?")
    }

    func testAQuoteThatIsNotInTheCapturedTextDropsTheSuggestion() {
        let answer = """
            {"new_tasks":[{"title":"Wire the money","source_items":[1],"quote":"Please wire the money today"}]}
            """
        XCTAssertTrue(proposals(answer, items: [item(1, "Ana: See you at lunch")]).isEmpty)
        let none = """
            {"new_tasks":[{"title":"Wire the money","source_items":[1]}]}
            """
        XCTAssertTrue(proposals(none, items: [item(1, "Ana: Please wire the money")]).isEmpty, "a suggestion without a quote is not backed")
    }

    func testTheQuoteMayDifferInCaseAndPunctuation() {
        let answer = """
            {"new_tasks":[{"title":"Send the report","source_items":[1],"quote":"please send the report"}]}
            """
        XCTAssertEqual(proposals(answer, items: [item(1, "Ana: Please, send the report!")]).first?.quote, "Please, send the report!")
    }

    // MARK: False drops and false merges

    func testDifferentThingsWithSimilarTitlesStayApart() {
        let body = "Dana: Reply about the offsite.\nDana: Reply about the budget."
        let answer = """
            {"new_tasks":[{"title":"Reply to Dana about the offsite","source_items":[1],"quote":"Reply about the offsite."},
                          {"title":"Reply to Dana about the budget","source_items":[1],"quote":"Reply about the budget."},
                          {"title":"Review PR #4641 for payments","source_items":[1],"quote":"Reply about the budget."},
                          {"title":"Review PR #4642 for payments","source_items":[1],"quote":"Reply about the budget."}]}
            """
        XCTAssertEqual(proposals(answer, items: [item(1, body)]).count, 4)
        let tasks = [CaptureTask(id: "t", title: "Review PR #4641 for payments", notes: "", due: nil)]
        let other = """
            {"new_tasks":[{"title":"Review PR #4642 for payments","source_items":[1],"quote":"Reply about the budget."}]}
            """
        XCTAssertEqual(proposals(other, items: [item(1, body)], tasks: tasks).count, 1)
    }

    func testAnIdentifierInTheQuoteOnlyDoesNotMerge() {
        let body = "Ana: Merge #4641 after #4700 lands.\nBen: Please book the room."
        let answer = """
            {"new_tasks":[{"title":"Book the room","source_items":[1],"quote":"Please book the room."}],
             "follow_ups":[{"title":"Merge the payments change","source_items":[1],"quote":"Merge #4641 after #4700 lands."}]}
            """
        XCTAssertEqual(proposals(answer, items: [item(1, body)]).count, 2)
        XCTAssertTrue(CaptureProposalChecks.identifiers("UTF-8 and SHA-256").isEmpty)
    }

    func testTwoMeetingsOnDifferentDaysStayApart() {
        let body = "Cal: Team sync Mon 23 Nov at 10:00\nCal: Team sync Wed 25 Nov at 10:00"
        let answer = """
            {"calendar":[{"title":"Team sync","start":"2026-11-23T10:00","source_items":[1],"quote":"Team sync Mon 23 Nov at 10:00"},
                         {"title":"Team sync","start":"2026-11-25T10:00","source_items":[1],"quote":"Team sync Wed 25 Nov at 10:00"}]}
            """
        XCTAssertEqual(proposals(answer, items: [item(1, body)]).count, 2)
    }

    func testARealSentenceWithALabelOrErrorWordIsKept() {
        let body = "Ana: Please try again with the new export.\nBen: Errors in the report need a fix by Friday.\nCy: Show more detail in the summary."
        for quote in ["Please try again with the new export.", "Errors in the report need a fix by Friday.", "Show more detail in the summary."] {
            let answer = """
                {"new_tasks":[{"title":"Do it","source_items":[1],"quote":"\(quote)"}]}
                """
            XCTAssertEqual(proposals(answer, items: [item(1, body)]).count, 1, quote)
        }
        XCTAssertTrue(CaptureProposalChecks.isInterfaceText(quote: "Send Stop", title: "x"))
    }

    func testAQuoteAcrossTwoLinesAndASentenceWithADotInsideAreKept() {
        let body = "Ana: Please send the signed contract to\nlegal before the audit.\nBen: See example.com for the form, then file it."
        let answer = """
            {"new_tasks":[{"title":"Send contract","source_items":[1],"quote":"send the signed contract to legal before the audit"},
                          {"title":"File the form","source_items":[1],"quote":"then file it"}]}
            """
        let out = proposals(answer, items: [item(1, body)])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.last?.quote, "See example.com for the form, then file it.")
    }

    func testRelativeDaysInOtherLanguages() {
        XCTAssertTrue(CaptureProposalChecks.dueIsStated("2026-11-17", in: "Envoyez-le demain"))
        XCTAssertTrue(CaptureProposalChecks.dueIsStated("2026-12-17", in: "Bis zum 17. Dezember"))
        XCTAssertFalse(CaptureProposalChecks.dueIsStated("2026-11-17", in: "Please review the design"))
    }

    func testThePromptStatesTheRules() {
        let text = CaptureAnalyzer.prompt(items: [item(1, "Ana: hi")], now: Date())
        for phrase in ["One suggestion per underlying thing", "Interface text is not a message", "Retry last message", "whole question word for word",
                       "Set due only when the text states a date", "Never guess a date"] {
            XCTAssertTrue(text.contains(phrase), phrase)
        }
    }
}
