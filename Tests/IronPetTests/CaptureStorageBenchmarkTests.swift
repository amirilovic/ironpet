import XCTest
@testable import IronPet

/// S0: what the tree store costs, per fixture, against today's flat text. Prints a table, and writes it to the file named by
/// `IRONPET_S0_REPORT` when set.
final class CaptureStorageBenchmarkTests: XCTestCase {
    private func bytes(_ entries: [CaptureTree.Entry], known: inout Set<String>) -> (rows: Int, bytes: Int, lzfse: Int) {
        var rows = 0, total = 0
        var pack = ""
        for e in entries where known.insert(e.hash).inserted { rows += 1; total += e.hash.utf8.count + e.data.utf8.count; pack += e.hash + e.data + "\n" }
        let packed = (try? (Data(pack.utf8) as NSData).compressed(using: .lzfse) as Data)?.count ?? 0
        return (rows, total, packed)
    }

    private func flat(_ root: AXNode, previous: [String]?) -> Int {
        let lines = CaptureText.lines(in: root)
        guard let previous else { return lines.joined(separator: "\n").utf8.count }
        return (CaptureDiff.fresh(previous: previous, current: lines) ?? "").utf8.count
    }

    func testReportStorage() {
        struct Case { let name: String; let first: AXNode; let plusOne: AXNode; let typing: AXNode }
        let cases = [
            Case(name: "chat-A", first: TreeFixtures.discord(messages: TreeFixtures.messages(62)),
                 plusOne: TreeFixtures.discord(messages: TreeFixtures.messages(63)),
                 typing: TreeFixtures.discord(messages: TreeFixtures.messages(62), draft: "sounds g")),
            Case(name: "chat-B", first: TreeFixtures.slack(messages: TreeFixtures.messages(60)),
                 plusOne: TreeFixtures.slack(messages: TreeFixtures.messages(61)),
                 typing: TreeFixtures.slack(messages: TreeFixtures.messages(60), draft: "sounds g")),
            Case(name: "mail", first: TreeFixtures.gmail(mails: TreeFixtures.mails(50)),
                 plusOne: TreeFixtures.gmail(mails: TreeFixtures.mails(51)),
                 typing: TreeFixtures.gmail(mails: TreeFixtures.mails(50), reply: "Thanks, I will")),
            Case(name: "page", first: TreeFixtures.article(), plusOne: TreeFixtures.article(paragraphs: 121), typing: TreeFixtures.article()),
        ]
        var report = "fixture | elements | blocks | label% | domid% | tree first | tree +1 | tree typing | flat first | flat +1 | flat typing\n"
        for c in cases {
            let clean: (String) -> String = { CaptureRedactor.redact($0).text }
            let a = CaptureTree.prepare(c.first, clean: clean), b = CaptureTree.prepare(c.plusOne, clean: clean), t = CaptureTree.prepare(c.typing, clean: clean)
            var known = Set<String>()
            let first = bytes(a.entries, known: &known)
            let second = bytes(b.entries, known: &known)
            let typed = bytes(t.entries, known: &known)
            let blocks = CaptureBlocks.extract(a.tree)
            let labelled = blocks.filter { !$0.label.isEmpty }.count, withId = blocks.filter(\.stable).count
            let pct = { (n: Int) in blocks.isEmpty ? "n/a" : "\(100 * n / blocks.count)%" }
            let lines = CaptureText.lines(in: c.first)
            report += "\(c.name) | \(a.elements) | \(blocks.count) | \(pct(labelled)) | \(pct(withId)) | \(first.bytes) B/\(first.rows) rows (lzfse pack \(first.lzfse)) | "
                + "\(second.bytes) B/\(second.rows) rows (lzfse pack \(second.lzfse)) | \(typed.bytes) B/\(typed.rows) rows | \(flat(c.first, previous: nil)) B | "
                + "\(flat(c.plusOne, previous: lines)) B | \(flat(c.typing, previous: lines)) B\n"
        }
        print(report)
        if let path = ProcessInfo.processInfo.environment["IRONPET_S0_REPORT"] { try? report.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
