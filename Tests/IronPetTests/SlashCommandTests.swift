import XCTest
@testable import IronPet

@MainActor
final class SlashCommandTests: XCTestCase {
    private let list = [
        SlashCommand(name: "review", detail: "Review code"),
        SlashCommand(name: "init", detail: "Set up", hint: "path"),
        SlashCommand(name: "compact", detail: "Shrink context"),
    ]

    func testParsesUpdate() throws {
        let json = #"[{"name":"review","description":"Review code"},{"name":"init","description":"Set up","input":{"hint":"path"}},{"name":"compact","description":"Shrink"}]"#
        let parsed = SlashCommand.parse(try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]])
        XCTAssertEqual(parsed.map(\.name), ["review", "init", "compact"])
        XCTAssertEqual(parsed[1].hint, "path")
        XCTAssertEqual(parsed[0].detail, "Review code")
    }

    func testFilteringAndVisibility() {
        XCTAssertEqual(SlashCommand.matches(for: "/", in: list).count, 3)
        XCTAssertEqual(SlashCommand.matches(for: "/co", in: list).map(\.name), ["compact"])
        XCTAssertEqual(SlashCommand.matches(for: "/IN", in: list).map(\.name), ["init"])
        // prefix first, then substring: "/e" prefixes nothing, substring hits review
        XCTAssertEqual(SlashCommand.matches(for: "/i", in: list).map(\.name), ["init", "review"])
        XCTAssertTrue(SlashCommand.matches(for: "hello /co", in: list).isEmpty)
        XCTAssertTrue(SlashCommand.matches(for: "/compact foo", in: list).isEmpty)
        XCTAssertTrue(SlashCommand.matches(for: "/compact ", in: list).isEmpty)
    }

    func testSelectionWraps() {
        var state = SlashPopupState()
        state.move(-1, count: 3)
        XCTAssertEqual(state.selection, 2)
        state.move(1, count: 3)
        XCTAssertEqual(state.selection, 0)
    }

    func testSessionCompletionAndEscape() {
        let session = ChatSession(restore: false)
        session.receiveCommands(list)
        session.input = "/co"
        XCTAssertEqual(session.slashMatches.map(\.name), ["compact"])
        XCTAssertTrue(session.completeSlash())
        XCTAssertEqual(session.input, "/compact ")
        XCTAssertTrue(session.slashMatches.isEmpty)
        XCTAssertFalse(session.completeSlash())

        session.input = "/"
        XCTAssertTrue(session.dismissSlash())
        XCTAssertEqual(session.input, "/")
        XCTAssertTrue(session.slashMatches.isEmpty)
        XCTAssertFalse(session.dismissSlash())
        session.inputChanged(from: "/", to: "/r")
        session.input = "/r"
        XCTAssertEqual(session.slashMatches.map(\.name), ["review"])
    }

    func testPerAgentCache() {
        let defaults = UserDefaults(suiteName: "slash-\(UUID().uuidString)")!
        SlashCommand.store(list, for: "a", defaults: defaults)
        XCTAssertEqual(SlashCommand.cached(for: "a", defaults: defaults), list)
        XCTAssertTrue(SlashCommand.cached(for: "b", defaults: defaults).isEmpty)
    }
}
