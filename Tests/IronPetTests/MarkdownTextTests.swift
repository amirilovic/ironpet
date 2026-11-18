import AppKit
import XCTest
@testable import IronPet

@MainActor
final class MarkdownTextTests: XCTestCase {
    private func attributed(_ markdown: String, find: ChatFind.RowHighlight? = nil) -> NSAttributedString {
        MarkdownText.attributed(Markdown.parse(markdown), size: 13.5, find: find)
    }

    private func copied(_ text: NSAttributedString, _ range: NSRange? = nil) -> String {
        MarkdownText.plainText(of: text, in: range ?? NSRange(location: 0, length: text.length))
    }

    func testBlocksOfOneRunShareOneString() {
        let text = attributed("# Title\n\nA paragraph.\n\n- one\n- two\n\n> quoted")
        XCTAssertEqual(copied(text), "Title\nA paragraph.\n- one\n- two\nquoted")
    }

    func testCopyKeepsListMarkersAndNesting() {
        let text = attributed("Intro\n\n1. first\n2. second\n3. third\n\n- bullet\n  - nested\n- [ ] todo\n- [x] done")
        XCTAssertEqual(copied(text), "Intro\n1. first\n2. second\n3. third\n- bullet\n  - nested\n- [ ] todo\n- [x] done")
    }

    func testSelectionFromParagraphIntoSecondItemCopiesWhatLiesBetween() throws {
        let text = attributed("Intro paragraph\n\n1. alpha\n2. beta\n3. gamma")
        let plain = text.string as NSString
        let end = plain.range(of: "beta").upperBound
        XCTAssertEqual(copied(text, NSRange(location: 6, length: end - 6)), "paragraph\n1. alpha\n2. beta")
    }

    func testSelectingAllInTheViewWritesMarkdownMarkersToThePasteboard() {
        let view = ChatTextView.make()
        view.setContent(attributed("Intro\n\n- one\n- two"))
        view.frame = CGRect(origin: .zero, size: view.fittingSize(forWidth: 300))
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.declareTypes(view.writablePasteboardTypes, owner: nil)
        XCTAssertTrue(view.writeSelection(to: board, types: view.writablePasteboardTypes))
        XCTAssertEqual(board.string(forType: .string), "Intro\n- one\n- two")
    }

    /// A real drag: mouse down in the paragraph, drag, mouse up inside the second list item.
    func testDraggingFromAParagraphIntoTheSecondItemSelectsAcrossBlocks() throws {
        let view = ChatTextView.make()
        let text = attributed("Intro paragraph\n\n- one\n- two\n- three")
        view.setContent(text)
        let size = view.fittingSize(forWidth: 300)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        view.frame = CGRect(origin: .zero, size: size)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        func point(of needle: String, trailing: Bool) -> CGPoint {
            let range = (text.string as NSString).range(of: needle)
            let screen = view.firstRect(forCharacterRange: NSRange(location: range.location + (trailing ? range.length - 1 : 0), length: 1), actualRange: nil)
            let inWindow = window.convertFromScreen(screen)
            return CGPoint(x: trailing ? inWindow.maxX - 1 : inWindow.minX + 1, y: inWindow.midY)
        }
        func event(_ type: NSEvent.EventType, _ location: CGPoint, _ number: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1)!
        }
        let start = point(of: "Intro", trailing: false)
        let end = point(of: "two", trailing: true)
        window.postEvent(event(.leftMouseDragged, CGPoint(x: end.x - 4, y: end.y), 2), atStart: false)
        window.postEvent(event(.leftMouseUp, end, 3), atStart: false)
        window.sendEvent(event(.leftMouseDown, start, 1))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.declareTypes(view.writablePasteboardTypes, owner: nil)
        XCTAssertTrue(view.writeSelection(to: board, types: view.writablePasteboardTypes))
        XCTAssertEqual(board.string(forType: .string), "Intro paragraph\n- one\n- two")
    }

    func testLongItemsWrapAtTheWidthWithAHangingIndent() {
        let text = attributed("- " + String(repeating: "word ", count: 40))
        let view = ChatTextView.make()
        view.setContent(text)
        let wide = view.fittingSize(forWidth: 520)
        let narrow = view.fittingSize(forWidth: 420)
        XCTAssertEqual(narrow.width, 420)
        XCTAssertGreaterThan(narrow.height, wide.height - 1)
        XCTAssertGreaterThan(wide.height, 40, "the item wraps to several lines instead of truncating")
        let style = text.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.firstLineHeadIndent, 0)
        XCTAssertEqual(style?.headIndent, 16, "bullet column 10 plus the 6 pt gap")
    }

    func testNestedItemsKeepTheirIndent() {
        let text = attributed("- top\n  - nested\n    - deeper")
        func head(_ needle: String) -> CGFloat {
            let at = (text.string as NSString).range(of: needle).location
            return (text.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? -1
        }
        XCTAssertEqual(head("top"), 0)
        XCTAssertEqual(head("nested"), 14)
        XCTAssertEqual(head("deeper"), 28)
    }

    func testTaskItemsShowACheckboxInsteadOfBrackets() {
        let text = attributed("- [x] done")
        XCTAssertFalse(text.string.contains("["))
        var attachments = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        XCTAssertEqual(attachments, 1)
    }

    func testFontsAndSizesMatchTheSwiftUIRendering() {
        let text = attributed("## Head\n\nBody with `code` and **bold**")
        func font(_ needle: String) -> NSFont? {
            text.attribute(.font, at: (text.string as NSString).range(of: needle).location, effectiveRange: nil) as? NSFont
        }
        XCTAssertEqual(font("Head")?.pointSize, 15.5)
        XCTAssertEqual(font("Body")?.pointSize, 13.5)
        XCTAssertTrue(font("code")?.isFixedPitch == true)
        XCTAssertEqual(font("code")?.pointSize, 13.5)
        XCTAssertTrue(NSFontManager.shared.traits(of: font("bold")!).contains(.boldFontMask))
    }

    func testLinksAndFilePathLinksKeepTheirURLs() {
        let cache = PathCache.shared
        cache.prime("/etc/hosts", .file)
        let text = attributed("See [site](https://example.com) and /etc/hosts now")
        func link(_ needle: String) -> URL? {
            text.attribute(.link, at: (text.string as NSString).range(of: needle).location, effectiveRange: nil) as? URL
        }
        XCTAssertEqual(link("site"), URL(string: "https://example.com"))
        XCTAssertEqual(link("/etc/hosts")?.path, "/etc/hosts")
        XCTAssertNil(link("See"))
    }

    func testFindHighlightsMatchesInParagraphsAndListItemsWithTheCurrentOneStronger() {
        let find = ChatFind.RowHighlight(query: "item", current: ChatFind.Match(item: UUID(), segment: 2, occurrence: 0))
        let text = attributed("An item in a paragraph\n\n- first item\n- second item", find: find)
        let plain = text.string as NSString
        func background(_ range: NSRange) -> NSColor? { text.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor }
        let paragraph = plain.range(of: "item")
        let first = plain.range(of: "item", options: [], range: NSRange(location: paragraph.upperBound, length: plain.length - paragraph.upperBound))
        let second = plain.range(of: "item", options: .backwards)
        XCTAssertEqual(background(paragraph), NSColor(ChatFind.highlightColor))
        XCTAssertEqual(background(first), NSColor(ChatFind.highlightColor))
        XCTAssertEqual(background(second), NSColor(ChatFind.currentColor), "segment 2 is the second list item")
        XCTAssertNil(background(NSRange(location: 0, length: 1)))
    }

    func testClickingAFileLinkOpensItAndOtherLinksAreLeftToTheSystem() {
        let cache = PathCache.shared
        cache.prime("/etc/hosts", .file)
        var opened: [URL] = []
        let saved = FilePathLinks.opener
        FilePathLinks.opener = { opened.append($0) }
        defer { FilePathLinks.opener = saved }
        let coordinator = MarkdownTextView.Coordinator()
        XCTAssertTrue(coordinator.textView(NSTextView(), clickedOnLink: URL(fileURLWithPath: "/etc/hosts"), at: 0))
        XCTAssertEqual(opened.map(\.path), ["/etc/hosts"])
    }

    func testLinkAttributesGiveThePointingHand() {
        let view = ChatTextView.make()
        XCTAssertEqual(view.linkTextAttributes?[.cursor] as? NSCursor, NSCursor.pointingHand)
        XCTAssertTrue(view.isSelectable)
        XCTAssertFalse(view.isEditable)
    }
}

private extension NSRange {
    var upperBound: Int { location + length }
}
