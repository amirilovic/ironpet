import XCTest
@testable import IronPet

final class LinkLayoutTests: XCTestCase {
    private func text(_ markdown: String) throws -> AttributedString {
        try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }

    func testLinkGetsARectAndPlainTextDoesNot() throws {
        let source = try text("plain words here [site](https://example.com) and more plain words")
        let rects = LinkLayout.linkRects(in: LinkLayout.attributed(source, size: 13.5, lineSpacing: 0), width: 400)
        XCTAssertEqual(rects.count, 1)
        // The link starts after "plain words here " and ends before " and more", so it sits inside the line.
        XCTAssertGreaterThan(rects[0].minX, 60)
        XCTAssertLessThan(rects[0].maxX, 200)
        XCTAssertGreaterThan(rects[0].width, 10)
    }

    func testTextWithoutLinksHasNoRects() throws {
        let source = try text("nothing to click here")
        XCTAssertTrue(LinkLayout.linkRects(in: LinkLayout.attributed(source, size: 13.5, lineSpacing: 0), width: 400).isEmpty)
    }

    func testLinkThatWrapsGetsOneRectPerLine() throws {
        let source = try text("[a link with many words that has to wrap over lines](https://example.com)")
        let rects = LinkLayout.linkRects(in: LinkLayout.attributed(source, size: 13.5, lineSpacing: 0), width: 80)
        XCTAssertGreaterThan(rects.count, 1)
    }

    func testFilePathBecomesALinkRect() throws {
        let cache = PathCache()
        cache.prime("/etc/hosts", .file)
        let linked = FilePathLinks.link(AttributedString("see /etc/hosts now"), cache: cache)
        XCTAssertEqual(LinkLayout.linkRects(in: LinkLayout.attributed(linked, size: 13.5, lineSpacing: 0), width: 400).count, 1)
    }
}
