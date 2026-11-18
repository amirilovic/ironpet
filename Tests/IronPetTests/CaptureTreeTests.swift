import XCTest
@testable import IronPet

/// S1 to S4: the tree store, the blocks found in it, and drafts. The windows are synthetic (`TreeFixtures`).
final class CaptureTreeTests: XCTestCase {
    private var store: CaptureStore!
    private let app = CaptureApp(bundleId: "test.chat", name: "Chat")
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        store = CaptureFixtures.store()
    }

    @discardableResult
    private func ingest(_ tree: AXNode, at offset: TimeInterval = 0, title: String = "#general") throws -> CaptureStore.IngestResult {
        let (lines, inputs) = CaptureText.read(in: tree)
        return try store.ingest(app: app, title: title, url: nil, trigger: .typingPause, lines: lines, inputLines: inputs, tree: tree, now: t0.addingTimeInterval(offset))
    }

    private func count(_ table: String) throws -> Int {
        Int(try store.database.read { try $0.rows("SELECT COUNT(*) FROM \(table)") }[0][0] as? Int64 ?? 0)
    }

    private func prepared(_ tree: AXNode) -> CaptureTree.Prepared { CaptureTree.prepare(tree, clean: { CaptureRedactor.redact($0).text }) }

    // MARK: S1

    func testSecureFieldsKeepOnlyRoleHiddenElementsAndSecretsAreNotStored() throws {
        let tree = AXNode(role: "Window", children: [
            AXNode(role: "TextField", value: "hunter2", description: "Password", children: [AXNode(role: "StaticText", value: "dots")]).with(subrole: "SecureTextField"),
            AXNode(role: "StaticText", value: "hidden words", hidden: true),
            AXNode(role: "Group", hidden: true, children: [AXNode(role: "StaticText", value: "also hidden")]),
            AXNode(role: "StaticText", value: "token ghp_" + String(repeating: "a1B2", count: 10)),
            AXNode(role: "StaticText", value: "visible words"),
        ])
        try ingest(tree)
        let stored = try store.database.read { try $0.rows("SELECT data FROM capture_node") }.compactMap { $0[0] as? String }.joined(separator: "\n")
        XCTAssertFalse(stored.contains("hunter2"))
        XCTAssertFalse(stored.contains("Password"), "a secure field keeps role and subrole only")
        XCTAssertFalse(stored.contains("dots"))
        XCTAssertFalse(stored.contains("hidden"))
        XCTAssertFalse(stored.contains("ghp_"))
        XCTAssertTrue(stored.contains("[redacted:github-token]"))
        XCTAssertTrue(stored.contains("visible words"))
        XCTAssertTrue(stored.contains("SecureTextField"))
    }

    func testIdenticalSubtreesAreStoredOnce() throws {
        let same = AXNode(role: "Group", children: [AXNode(role: "StaticText", value: "same"), AXNode(role: "Button", title: "Go")])
        let tree = AXNode(role: "Window", children: [same, same, AXNode(role: "Group", children: [same])])
        let result = prepared(tree)
        XCTAssertEqual(result.entries.count, 5, "StaticText, Button, the shared group, the group around it, the window")
        XCTAssertEqual(Set(result.entries.map(\.hash)).count, result.entries.count)
        try ingest(tree)
        XCTAssertEqual(try count("capture_node"), result.entries.count)
        XCTAssertEqual(try store.database.read { try $0.rows("SELECT root FROM capture") }[0][0] as? String, result.root, "the capture holds the root hash")
    }

    // MARK: S2

    func testANewMessageWritesOnlyItsPathAndBothCapturesReassembleExactly() throws {
        let a = TreeFixtures.discord(messages: TreeFixtures.messages(62))
        let b = TreeFixtures.discord(messages: TreeFixtures.messages(63))
        guard case .stored(let first) = try ingest(a, at: 0) else { return XCTFail() }
        let firstRows = store.lastNodeWrites
        guard case .stored(let second) = try ingest(b, at: 60) else { return XCTFail() }
        XCTAssertGreaterThan(firstRows, 500)
        XCTAssertLessThan(store.lastNodeWrites, 60, "the new message's subtree and the ancestors above it")
        XCTAssertEqual(store.tree(ofCapture: first), prepared(a).tree)
        XCTAssertEqual(store.tree(ofCapture: second), prepared(b).tree)
    }

    func testReassemblyOfALargeWindowTakesMilliseconds() throws {
        let a = TreeFixtures.discord(messages: TreeFixtures.messages(62))
        guard case .stored(let id) = try ingest(a) else { return XCTFail() }
        let start = Date()
        XCTAssertNotNil(store.tree(ofCapture: id))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25)
    }

    // MARK: S3

    func testAFollowUpMessageIsLabelledWithItsAuthorThoughItsSubtreeHasNone() throws {
        let messages = TreeFixtures.messages(6)
        let followUp = messages[1]
        XCTAssertTrue(followUp.followUp)
        let blocks = CaptureBlocks.extract(prepared(TreeFixtures.discord(messages: messages)).tree).filter { !$0.label.isEmpty }
        let block = try XCTUnwrap(blocks.first { $0.label.contains(followUp.text) })
        XCTAssertTrue(block.label.hasPrefix(followUp.author), block.label)
        XCTAssertEqual(block.when, "Wednesday, 18. November 2026 at \(followUp.time)")
        XCTAssertEqual(block.identity, "d:chat-messages-c1-\(followUp.id)")
        XCTAssertEqual(block.container, "Messages in #general")
        XCTAssertFalse(block.text.contains("Reply"), "control labels that every message repeats are not content")
        XCTAssertFalse(block.text.contains("Message Actions"))
    }

    func testBlocksWithoutAnAccessibleNameGetALineBuiltFromTheirOwnText() {
        let tree = prepared(TreeFixtures.slack(messages: TreeFixtures.messages(6))).tree
        let blocks = CaptureBlocks.extract(tree).filter { $0.container == "general" }
        XCTAssertEqual(blocks.count, 6)
        let unnamed = blocks[1]
        XCTAssertTrue(unnamed.label.contains(TreeFixtures.messages(6)[1].text), unnamed.label)
        XCTAssertFalse(unnamed.label.contains("Add reaction"), "a control label the siblings repeat is left out")
        XCTAssertTrue(unnamed.stable == false)
        XCTAssertTrue(unnamed.identity.hasPrefix("t:"))
    }

    func testMailRowsAreBlocksWithTheirPageIdAndAFullDate() throws {
        let tree = prepared(TreeFixtures.gmail(mails: TreeFixtures.mails(6))).tree
        let rows = CaptureBlocks.extract(tree).filter { $0.container == "Inbox" }
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows[0].identity, "d::0a")
        XCTAssertEqual(rows[0].when, TreeFixtures.mails(1)[0].date)
        XCTAssertFalse(rows[0].text.contains("Select"))
    }

    func testAWindowWithNoBlocksHasNone() {
        XCTAssertEqual(CaptureBlocks.extract(prepared(TreeFixtures.article()).tree), [])
    }

    func testABlockSeenWithinSevenDaysIsNotNewAndChangedTextWithTheSameIdIsEdited() throws {
        let chat = TreeFixtures.discord(messages: TreeFixtures.messages(5))
        guard case .stored = try ingest(chat, at: 0) else { return XCTFail() }
        XCTAssertEqual(try ingest(TreeFixtures.discord(messages: TreeFixtures.messages(5)), at: 600), .unchanged)
        // The same messages after a scroll: nothing is new.
        XCTAssertEqual(try ingest(TreeFixtures.discord(messages: Array(TreeFixtures.messages(5).dropFirst(2))), at: 900), .unchanged)
        var edited = TreeFixtures.messages(5)
        edited[3].text = "changed my mind about lunch"
        guard case .stored = try ingest(TreeFixtures.discord(messages: edited), at: 1200) else { return XCTFail("an edit is a change") }
        let kinds = store.changes().map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .new }.count, 5)
        XCTAssertEqual(kinds.filter { $0 == .edited }.count, 1)
        // Eight days later the same messages count as new again, and one more.
        guard case .stored = try ingest(TreeFixtures.discord(messages: edited + TreeFixtures.messages(1, from: 5)), at: 8 * 86_400) else { return XCTFail() }
        XCTAssertEqual(store.changes().count, 6 + 6)
    }

    func testScrollingBackStoresNoCaptureRow() throws {
        let all = TreeFixtures.messages(30)
        try ingest(TreeFixtures.discord(messages: Array(all.suffix(10))), at: 0)
        try ingest(TreeFixtures.discord(messages: Array(all.prefix(20))), at: 10)
        let rows = try count("capture")
        for step in 1...4 { try ingest(TreeFixtures.discord(messages: Array(all[(step * 2)..<(step * 2 + 20)])), at: 20 + Double(step)) }
        XCTAssertEqual(try count("capture"), rows, "every message was seen already, so scrolling over them stores nothing")
    }

    // MARK: S4

    func testATypingBurstUpdatesOneDraftAndTheSentMessageMarksItSent() throws {
        let sent = "sounds good, see you at ten"
        let base = TreeFixtures.messages(8)
        guard case .stored = try ingest(TreeFixtures.discord(messages: base), at: 0) else { return XCTFail() }
        let captures = try count("capture"), nodes = try count("capture_node")
        for step in 1...7 {
            let draft = String(sent.prefix(step * 4))
            XCTAssertEqual(try ingest(TreeFixtures.discord(messages: base, draft: draft), at: Double(step) * 1.5), .unchanged)
        }
        XCTAssertEqual(try count("capture"), captures, "a typing burst stores no capture")
        XCTAssertEqual(try count("capture_node"), nodes)
        XCTAssertEqual(try count("capture_draft"), 1, "one row per input field")
        let drafts = store.changes().filter { $0.kind == .draft }
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].label, String(sent.prefix(28)))
        XCTAssertEqual(drafts[0].container, "Message #general")

        var after = base
        var message = TreeFixtures.messages(1, from: 8)[0]
        message.text = sent
        after.append(message)
        guard case .stored = try ingest(TreeFixtures.discord(messages: after), at: 20) else { return XCTFail("the sent message is stored") }
        let changes = store.changes()
        XCTAssertEqual(changes.last?.kind, .sent)
        XCTAssertTrue(changes.last?.label.contains(sent) == true)
        XCTAssertFalse(changes.contains { $0.kind == .draft }, "a sent draft is no longer listed as a draft")
        XCTAssertEqual(try store.database.read { try $0.rows("SELECT status FROM capture_draft") }[0][0] as? String, "sent")
    }

    func testAClearedDraftWithNoMatchingMessageIsDiscarded() throws {
        let base = TreeFixtures.messages(4)
        try ingest(TreeFixtures.discord(messages: base), at: 0)
        try ingest(TreeFixtures.discord(messages: base, draft: "never mind"), at: 5)
        try ingest(TreeFixtures.discord(messages: base), at: 10)
        var more = base
        more += TreeFixtures.messages(1, from: 4)
        guard case .stored = try ingest(TreeFixtures.discord(messages: more), at: 400) else { return XCTFail() }
        XCTAssertEqual(store.changes().last?.kind, .new)
        XCTAssertEqual(try store.database.read { try $0.rows("SELECT status FROM capture_draft") }[0][0] as? String, "discarded")
    }

    // MARK: Retention

    func testPruningDeletesOldCapturesAndTheNodesNoRemainingCaptureReaches() throws {
        let day: TimeInterval = 86_400
        let old = TreeFixtures.discord(messages: TreeFixtures.messages(10))
        let recent = TreeFixtures.discord(messages: TreeFixtures.messages(10, from: 5))
        try ingest(old, at: -40 * day)
        try ingest(TreeFixtures.discord(messages: TreeFixtures.messages(2), draft: "old draft"), at: -39 * day, title: "#other")
        guard case .stored(let keptId) = try ingest(recent, at: -1 * day) else { return XCTFail() }
        let before = try count("capture_node")
        XCTAssertEqual(store.prune(olderThanDays: 30, now: t0), 2)
        XCTAssertEqual(try count("capture"), 1)
        XCTAssertEqual(try count("capture_node"), prepared(recent).entries.count, "only the nodes the remaining capture reaches are left")
        XCTAssertLessThan(try count("capture_node"), before)
        XCTAssertEqual(store.tree(ofCapture: keptId), prepared(recent).tree, "what stays still reassembles exactly")
        XCTAssertEqual(try count("capture_draft"), 0)
        XCTAssertTrue(store.changes().allSatisfy { $0.seen >= t0.addingTimeInterval(-30 * day) })
    }
}

private extension AXNode {
    func with(subrole: String) -> AXNode {
        var copy = self
        copy.subrole = subrole
        return copy
    }
}
