import XCTest
@testable import IronPet

final class ChatFindTests: XCTestCase {
    private lazy var items: [ChatSession.Item] = [
            .init(kind: .user("Please Deploy the app")),
            .init(kind: .tool("Ran `deploy.sh`", ok: true)),
            .init(kind: .assistant("Done. **Deploy** finished, then DEPLOY again.\n\n- déploy check\n\n```\nnpm run deploy\n```")),
            .init(kind: .screenshot("/tmp/x.png")),
            .init(kind: .error("deploy failed")),
    ]

    private func transcript() -> [ChatSession.Item] { items }

    func testRangesAreCaseAndDiacriticInsensitive() {
        XCTAssertEqual(ChatFind.ranges(of: "deploy", in: "Deploy, DEPLOY and déploy"), [0..<6, 8..<14, 19..<25])
        XCTAssertEqual(ChatFind.ranges(of: "aa", in: "aaaa"), [0..<2, 2..<4])
        XCTAssertTrue(ChatFind.ranges(of: "", in: "abc").isEmpty)
    }

    func testCountsAcrossUserAssistantAndToolRows() {
        let matches = ChatFind.matches(query: "deploy", in: transcript())
        // user 1, tool 1, assistant paragraph 2 + list 1 + code 1, error 1
        XCTAssertEqual(matches.count, 7)
        XCTAssertEqual(matches.map(\.item), [items[0].id, items[1].id, items[2].id, items[2].id, items[2].id, items[2].id, items[4].id])
    }

    func testMarkdownMarkersAreNotSearchable() {
        let items: [ChatSession.Item] = [.init(kind: .assistant("**bold** and `code`"))]
        XCTAssertTrue(ChatFind.matches(query: "**", in: items).isEmpty)
        XCTAssertEqual(ChatFind.matches(query: "bold and", in: items).count, 1)
    }

    func testNoMatchLabel() {
        XCTAssertEqual(ChatFind.matches(query: "zzz", in: transcript()), [])
        XCTAssertEqual(ChatFind.label(query: "zzz", count: 0, index: nil), "No results")
        XCTAssertEqual(ChatFind.label(query: "", count: 0, index: nil), "")
        XCTAssertEqual(ChatFind.label(query: "a", count: 12, index: 2), "3 of 12")
        XCTAssertNil(ChatFind.step(from: nil, count: 0, by: 1))
    }

    func testStepWrapsAtBothEnds() {
        XCTAssertEqual(ChatFind.step(from: nil, count: 5, by: 1), 0)
        XCTAssertEqual(ChatFind.step(from: nil, count: 5, by: -1), 4)
        XCTAssertEqual(ChatFind.step(from: 4, count: 5, by: 1), 0)
        XCTAssertEqual(ChatFind.step(from: 0, count: 5, by: -1), 4)
        XCTAssertEqual(ChatFind.step(from: 2, count: 5, by: 1), 3)
    }

    func testStreamingKeepsCurrentMatch() {
        var items = transcript()
        let before = ChatFind.matches(query: "deploy", in: items)
        let current = before[2]
        items.append(.init(kind: .assistant("one more deploy")))
        let after = ChatFind.matches(query: "deploy", in: items)
        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertEqual(ChatFind.reconcile(current: current, in: after), 2)
        XCTAssertEqual(ChatFind.reconcile(current: nil, in: after), 0)
        XCTAssertNil(ChatFind.reconcile(current: current, in: []))
    }

    func testVanishedCurrentMatchKeepsThePlaceInsteadOfJumpingToTheFirst() {
        let items = transcript()
        let matches = ChatFind.matches(query: "deploy", in: items)
        let gone = ChatFind.Match(item: UUID(), segment: 0, occurrence: 0)
        XCTAssertEqual(ChatFind.reconcile(current: gone, previousIndex: 3, in: matches), 3)
        XCTAssertEqual(ChatFind.reconcile(current: gone, previousIndex: 99, in: matches), matches.count - 1)
    }

    func testRangesAreCharacterOffsetsForRepeatedMatches() {
        XCTAssertEqual(ChatFind.ranges(of: "ab", in: "xabyABz ab"), [1..<3, 4..<6, 8..<10])
    }

    func testOnlyRowsWithMatchesGetHighlights() {
        let items = transcript()
        let matches = ChatFind.matches(query: "deploy", in: items)
        let current = matches[1]
        let rows = ChatFind.highlights(query: "deploy", matches: matches, current: current)
        XCTAssertNil(rows[items[3].id])
        XCTAssertEqual(rows[items[1].id]?.current, current)
        XCTAssertNil(rows[items[0].id]?.current)
        XCTAssertEqual(rows.count, 4)
    }
}
