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

    func testOthersItemsAreWaitingOnTheirOwnerAndUnownedOnesAreLeftOut() {
        let suggested = ActionItems.suggestions(summary)
        XCTAssertEqual(suggested.map(\.title), ["Send the deck to Sam", "Review the budget", "Book the venue", "Fix login (the SSO one)",
                                                "Draft the agenda", "Call   the bank", "Pay the invoice"])
        XCTAssertEqual(suggested.map(\.waitingOn), [nil, "Them", "Priya", nil, nil, nil, nil])
        XCTAssertEqual(suggested[2].due, "Friday")
        XCTAssertEqual(ActionItems.suggestions("## Action items\n- [ ] Send the slides (owner: Ana, Me)\n").map(\.waitingOn), ["Ana"])
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
