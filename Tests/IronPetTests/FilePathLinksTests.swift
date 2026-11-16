import XCTest
@testable import IronPet

final class FilePathLinksTests: XCTestCase {
    private func paths(_ text: String) -> [String] { FilePathLinks.detect(in: text).map(\.path) }
    private func covered(_ text: String) -> [String] {
        FilePathLinks.detect(in: text).map { String(text[$0.range]) }
    }

    func testDetectionTable() {
        let home = NSHomeDirectory()
        let cases: [(String, [String], [String])] = [
            ("open /Users/a/b/brief.md now", ["/Users/a/b/brief.md"], ["/Users/a/b/brief.md"]),
            ("see /tmp/x/y.txt.", ["/tmp/x/y.txt"], ["/tmp/x/y.txt"]),
            ("a /tmp/x/y.txt, b", ["/tmp/x/y.txt"], ["/tmp/x/y.txt"]),
            ("(/tmp/x/y.txt)", ["/tmp/x/y.txt"], ["/tmp/x/y.txt"]),
            ("`/tmp/x/y.txt`", ["/tmp/x/y.txt"], ["/tmp/x/y.txt"]),
            ("\"/tmp/x/y.txt\"", ["/tmp/x/y.txt"], ["/tmp/x/y.txt"]),
            ("file is /tmp/x/y.txt:", ["/tmp/x/y.txt"], ["/tmp/x/y.txt"]),
            ("/Users/a/ChatSession.swift:644", ["/Users/a/ChatSession.swift"], ["/Users/a/ChatSession.swift:644"]),
            ("/Users/a/F.swift:644:9.", ["/Users/a/F.swift"], ["/Users/a/F.swift:644:9"]),
            ("/tmp/my\\ dir/a\\ b.md ok", ["/tmp/my dir/a b.md"], ["/tmp/my\\ dir/a\\ b.md"]),
            ("(see /tmp/dir (copy)/a.md)", ["/tmp/dir"], ["/tmp/dir"]),
            ("/tmp/dir(1)/a.md", ["/tmp/dir(1)/a.md"], ["/tmp/dir(1)/a.md"]),
            ("~/.ironpet/config.json", [home + "/.ironpet/config.json"], ["~/.ironpet/config.json"]),
            ("file:///tmp/a%20b/c.md", ["/tmp/a b/c.md"], ["file:///tmp/a%20b/c.md"]),
            ("/tmp", [], []),
            ("~/", [], []),
            ("https://example.com/a/b", [], []),
            ("docs/cv.md and a/b/c", [], []),
            ("and/or 3/4", [], []),
        ]
        for (text, expectedPaths, expectedCovered) in cases {
            XCTAssertEqual(paths(text), expectedPaths, text)
            XCTAssertEqual(covered(text), expectedCovered, text)
        }
    }

    func testOnlyExistingPathsBecomeLinks() {
        let cache = PathCache()
        cache.prime("/tmp/x/real.md", .file)
        cache.prime("/tmp/x/gone.md", .missing)
        let linked = FilePathLinks.link(AttributedString("a /tmp/x/real.md b /tmp/x/gone.md"), cache: cache)
        let urls = linked.runs.compactMap(\.link)
        XCTAssertEqual(urls, [URL(fileURLWithPath: "/tmp/x/real.md")])
    }

    func testLineSuffixLinksToTheFile() {
        let cache = PathCache()
        cache.prime("/tmp/x/F.swift", .file)
        let linked = FilePathLinks.link(AttributedString("at /tmp/x/F.swift:644."), cache: cache)
        XCTAssertEqual(linked.runs.compactMap(\.link), [URL(fileURLWithPath: "/tmp/x/F.swift")])
        let linkedText = linked.runs.filter { $0.link != nil }.map { String(linked[$0.range].characters) }
        XCTAssertEqual(linkedText, ["/tmp/x/F.swift:644"])
    }

    func testMarkdownLinksAndCodeSpans() {
        let cache = PathCache()
        cache.prime("/tmp/x/a.md", .file)
        let parsed = (try? AttributedString(markdown: "[/tmp/x/a.md](https://e.com) and `/tmp/x/a.md`",
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))!
        let linked = FilePathLinks.link(parsed, cache: cache)
        XCTAssertEqual(linked.runs.compactMap(\.link), [URL(string: "https://e.com")!, URL(fileURLWithPath: "/tmp/x/a.md")])
    }

    func testActionsForFilesAndFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let cache = PathCache()
        XCTAssertEqual(FilePathLinks.action(for: file, cache: cache), .open(file))
        XCTAssertEqual(FilePathLinks.action(for: dir, cache: cache), .revealFolder(dir))
        XCTAssertEqual(FilePathLinks.action(for: dir.appendingPathComponent("nope"), cache: cache), .ignore)
        XCTAssertEqual(FilePathLinks.action(for: URL(string: "https://example.com")!, cache: cache), .ignore)
    }

    func testAppsAndScriptsAreRevealedNotLaunched() {
        let cache = PathCache()
        let app = URL(fileURLWithPath: "/tmp/x/Foo.app")
        let script = URL(fileURLWithPath: "/tmp/x/run.command")
        cache.prime(app.path, .directory)
        cache.prime(script.path, .file)
        XCTAssertEqual(FilePathLinks.action(for: app, cache: cache), .showInFinder(app))
        XCTAssertEqual(FilePathLinks.action(for: script, cache: cache), .showInFinder(script))
    }

    func testRenderingNeverWaitsForTheDisk() {
        let cache = PathCache()
        let text = AttributedString((0..<500).map { "see /tmp/ironpet-none-\($0)/file.md" }.joined(separator: "\n"))
        let start = Date()
        _ = FilePathLinks.link(text, cache: cache)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}
