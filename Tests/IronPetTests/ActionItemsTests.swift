import XCTest
@testable import IronPet

final class ActionItemsTests: XCTestCase {
    private let summary = """
        ## Summary
        We planned the launch.

        ## Decisions
        - [ ] Ship on Monday (owner: Me)

        ## Action items
        - [ ] Send the deck to Sam (owner: Me, due: 2026-11-20)
        - [ ] Review the budget (owner: Them)
        - [ ] Book the venue (owner: Priya, due: Friday)
        - [ ] Follow up later
        * [ ] Fix login (the SSO one) (owner: me)
        - [x] Draft the agenda (owner: ME, due: tomorrow)
           - [ ]    Call   the bank   (  owner:  Me ,  due:  Monday  )
        - [ ] Call Bob (re: invoice)
        - [ ] Pay the invoice (owner: Me, due: Nov 20, 2026)

        ## Notes
        - [ ] Not an action item (owner: Me)
        """

    func testParsesOwnersAndDues() {
        XCTAssertEqual(ActionItems.parse(summary), [
            .init(title: "Send the deck to Sam", owner: "Me", due: "2026-11-20"),
            .init(title: "Review the budget", owner: "Them", due: nil),
            .init(title: "Book the venue", owner: "Priya", due: "Friday"),
            .init(title: "Follow up later", owner: nil, due: nil),
            .init(title: "Fix login (the SSO one)", owner: "me", due: nil),
            .init(title: "Draft the agenda", owner: "ME", due: "tomorrow"),
            .init(title: "Call   the bank", owner: "Me", due: "Monday"),
            .init(title: "Call Bob (re: invoice)", owner: nil, due: nil),
            .init(title: "Pay the invoice", owner: "Me", due: "Nov 20, 2026"),
        ])
    }

    func testMineKeepsOnlyMyItemsInAnyCase() {
        let mine = ActionItems.suggestions(summary).filter { $0.waitingOn == nil }
        XCTAssertEqual(mine.map(\.title), ["Send the deck to Sam", "Fix login (the SSO one)", "Draft the agenda", "Call   the bank",
                                           "Pay the invoice"])
        XCTAssertEqual(mine.map(\.due), ["2026-11-20", nil, "tomorrow", "Monday", "Nov 20, 2026"])
    }

    func testOthersItemsAreSuggestedOnlyWhenTheUserWaitsOnThem() {
        let text = """
        ## Action items
        - [ ] Send the budget (owner: Me)
        - [ ] Deliver the contract (owner: Ana, waiting: yes)
        - [ ] Refactor the parser (owner: Joonas)
        - [ ] Book the venue (owner: Priya, waiting: no)
        """
        let suggested = ActionItems.suggestions(text)
        XCTAssertEqual(suggested.map(\.title), ["Send the budget", "Deliver the contract"])
        XCTAssertEqual(suggested.map(\.waitingOn), [nil, "Ana"])
    }

    func testASummaryWithoutWaitingSuggestsOnlyMyItems() {
        let suggested = ActionItems.suggestions(summary)
        XCTAssertEqual(suggested.map(\.title), ["Send the deck to Sam", "Fix login (the SSO one)", "Draft the agenda", "Call   the bank",
                                                "Pay the invoice"])
        XCTAssertEqual(suggested.compactMap(\.waitingOn), [])
    }

    func testWaitingIsReadInAnyOrderWithOwnerAndDue() {
        let text = """
        ## Action items
        - [ ] A (waiting: yes, owner: Ana, due: Nov 20, 2026)
        - [ ] B (owner: Ana, due: Nov 20, 2026, waiting: yes)
        - [ ] C (due: Friday, waiting: yes, owner: Ana)
        - [ ] D (owner: Ana, waiting: no)
        """
        let items = ActionItems.parse(text)
        XCTAssertEqual(items.map(\.waiting), [true, true, true, false])
        XCTAssertEqual(items.map(\.due), ["Nov 20, 2026", "Nov 20, 2026", "Friday", nil])
        XCTAssertEqual(items.map(\.owner), ["Ana", "Ana", "Ana", "Ana"])
    }

    func testOpenItemsStayTheUsersOwnWhateverWaitingSays() {
        let text = "## Action items\n- [ ] Mine (owner: Me)\n- [ ] Theirs (owner: Ana, waiting: yes)\n- [ ] Nobody's\n"
        XCTAssertEqual(ActionItems.openItems(text).map(\.title), ["Mine", "Nobody's"])
    }

    func testPromptTextAsksForWaitingOnlyOnOthersItems() async {
        let prompt = await MeetingController.summaryPrompt(transcript: "x")
        XCTAssertTrue(prompt.contains("waiting: yes"))
        XCTAssertTrue(prompt.contains("never add it to an item owned by Me"))
    }

    func testNoneAndMissingSectionGiveNothing() {
        XCTAssertEqual(ActionItems.parse("## Summary\nHi.\n\n## Action items\nNone.\n"), [])
        XCTAssertEqual(ActionItems.parse("## Summary\nHi.\n\n## Decisions\n- [ ] Ship it (owner: Me)\n"), [])
        XCTAssertEqual(ActionItems.parse(""), [])
    }

    func testOnlyTheActionItemsSectionCounts() {
        let text = "## Decisions\n- [ ] A (owner: Me)\n### Action Items\n- [ ] B (owner: Me)\n# Next\n- [ ] C (owner: Me)\n"
        XCTAssertEqual(ActionItems.suggestions(text).map(\.title), ["B"])
    }

    func testIgnoresPlainBulletsAndEmptyBoxes() {
        let text = "## Action items\n- Not a checkbox (owner: Me)\n- [ ]\n- [ ]   \n- [ ] Real (owner: Me)\n"
        XCTAssertEqual(ActionItems.parse(text).map(\.title), ["Real"])
    }

    func testOwnerListKeepsTheFirstName() {
        XCTAssertEqual(ActionItems.parse("## Action items\n- [ ] Plan the offsite (owner: Me, Sam)\n"),
                       [.init(title: "Plan the offsite", owner: "Me", due: nil)])
    }

    func testBlankDueIsNoDue() {
        XCTAssertEqual(ActionItems.parse("## Action items\n- [ ] Write notes (owner: Me, due: )\n"),
                       [.init(title: "Write notes", owner: "Me", due: nil)])
    }
}
