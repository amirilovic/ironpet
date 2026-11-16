import XCTest
@testable import IronPet

final class CaptureRulesTests: XCTestCase {
    private func engine() -> CapturePipeline {
        CapturePipeline(privacy: CapturePrivacy(), rules: CaptureRules(), store: CaptureStore.inMemory())
    }

    func testEveryBundledRuleLoads() {
        let report = CaptureRules().report()
        let bundled = report.filter { $0.origin == .bundled }
        XCTAssertEqual(bundled.count, BundledCaptureRules.rules.count)
        XCTAssertEqual(bundled.filter { $0.status != .active }.map { "\($0.name): \($0.error ?? "")" }, [])
        XCTAssertEqual(BundledCaptureRules.rules.count, 24)
    }

    func testFixtureSetIsComplete() {
        XCTAssertEqual(CaptureFixtures.names.count, 58)
        let items = CaptureFixtures.names.filter { (CaptureFixtures.expected($0) as? [String: Any])?["thread_key"] != nil }
        XCTAssertGreaterThan(items.count, 40, "most fixtures give an item, so the comparison is not empty")
        let goldens = ((try? FileManager.default.contentsOfDirectory(atPath: CaptureFixtures.directory.path)) ?? []).filter { $0.hasSuffix("-golden.json") }
        XCTAssertEqual(goldens.count, 38)
    }

    /// S2: every fixture gives the output lookback's own engine gave.
    func testRulesReproduceLookbackOutputForEveryFixture() throws {
        let pipeline = engine()
        var failures: [String] = []
        for name in CaptureFixtures.names {
            let snapshot = try XCTUnwrap(CaptureFixtures.snapshot(name), name)
            let want = CaptureFixtures.expected(name)
            let got: Any?
            switch try? pipeline.parse(snapshot) {
            case .item(let item)?: got = CaptureFixtures.canonical(item)
            case .refuse(let reason)?: got = ["refuse": reason]
            case .notHandled?: got = NSNull()
            case nil: got = ["error": true]
            }
            if !((got as? NSObject) ?? NSNull()).isEqual((want as? NSObject) ?? NSNull()) { failures.append(name) }
        }
        XCTAssertEqual(failures, [], "of \(CaptureFixtures.names.count) fixtures")
    }

    /// The goldens recorded before the port: where lookback itself still matches one, ironpet must too.
    func testRulesReproduceTheGoldens() throws {
        let pipeline = engine()
        var checked = 0
        var failures: [String] = []
        for name in CaptureFixtures.names {
            guard let golden = CaptureFixtures.goldenContent(name), let snapshot = CaptureFixtures.snapshot(name) else { continue }
            guard let want = CaptureFixtures.expected(name) as? [String: Any], let content = want["content"],
                  let lookbackData = try? JSONSerialization.data(withJSONObject: content),
                  let lookbackContent = try? JSONDecoder().decode(CaptureContent.self, from: lookbackData), lookbackContent == golden else { continue }
            checked += 1
            guard case .item(let item)? = try? pipeline.parse(snapshot), item.content == golden else { failures.append(name); continue }
        }
        XCTAssertEqual(failures, [])
        XCTAssertGreaterThan(checked, 20, "goldens that lookback itself still matches")
    }

    func testUserRuleReplacesABundledOneAndABrokenOneIsReported() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "export const meta = { api: 1, kind: 'parser', match: { bundleIds: ['com.example.x'] } };\nexport function parse(s, ctx) { return { refuse: 'mine' }; }"
            .write(to: folder.appendingPathComponent("notes.js"), atomically: true, encoding: .utf8)
        try "export const meta = { api: 2 };".write(to: folder.appendingPathComponent("broken.js"), atomically: true, encoding: .utf8)
        try "export const meta = { api: 1, kind: 'parser' }; export function parse() { return null; }"
            .write(to: folder.appendingPathComponent("generic.js"), atomically: true, encoding: .utf8)
        try "this is not javascript (".write(to: folder.appendingPathComponent("slack.js"), atomically: true, encoding: .utf8)
        let set = CaptureRuleSet(folder: folder)
        let byName = Dictionary(grouping: set.report(), by: \.name)
        XCTAssertEqual(byName["notes"]?.first { $0.origin == .user }?.status, .active)
        XCTAssertEqual(byName["notes"]?.first { $0.origin == .bundled }?.status, .overridden)
        XCTAssertEqual(byName["broken"]?.first?.status, .error)
        XCTAssertEqual(byName["slack"]?.first { $0.origin == .user }?.status, .error)
        XCTAssertEqual(byName["slack"]?.first { $0.origin == .bundled }?.status, .active, "the bundled rule stays in force")
    }

    func testARuleThatLoopsForeverIsStopped() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "export const meta = { api: 1, kind: 'transform' };\nexport function transform(item) { while (true) {} }"
            .write(to: folder.appendingPathComponent("spin.js"), atomically: true, encoding: .utf8)
        let rules = CaptureRules(set: CaptureRuleSet(folder: folder, limits: .init(timeSeconds: 0.2, memoryBytes: 32 * 1024 * 1024)))
        XCTAssertThrowsError(try rules.invoke(rule: "spin", function: "transform", input: "{}")) {
            XCTAssertTrue($0.localizedDescription.contains("time limit"), $0.localizedDescription)
        }
        XCTAssertEqual(rules.report().first { $0.name == "spin" }?.status, .error)
    }

    func testBundledRulesSourceIsUpToDate() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for rule in BundledCaptureRules.rules {
            let text = try String(contentsOf: root.appendingPathComponent("capture-rules/\(rule.name).js"), encoding: .utf8)
            XCTAssertEqual(text.hasSuffix("\n") ? String(text.dropLast()) : text, rule.source, "\(rule.name): run scripts/gen_capture_rules.py")
        }
    }
}
