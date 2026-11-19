import XCTest
@testable import IronPet

/// Drives alerts and bubbles only through `IronPetAPI`. The stores are passed to the test helper only to put sample data in them,
/// the way an automation or the announcer would.
@MainActor
final class AlertsBubblesAPITests: XCTestCase {
    private var events: APIEventBus!
    private var seen: [APIEvent] = []
    private var signals: SignalStore!
    private var bubbles: BubbleStore!
    private var api: IronPetAPI!

    override func setUp() async throws {
        events = APIEventBus()
        seen = []
        events.subscribe { [unowned self] in seen.append($0) }
        signals = SignalStore()
        bubbles = BubbleStore()
        api = APITestSupport.makeAPI(events: events, signals: signals, bubbles: bubbles)
    }

    private func alert(_ id: String, ask: String? = nil, mood: PetMood = .failed) -> Signal {
        Signal(id: id, title: "PR \(id)", subtitle: "you/repo", url: URL(string: "https://example.com/\(id)"), label: "CI failed",
               symbol: "xmark", mood: mood, ask: ask)
    }

    func testAlertsListGetAndDismiss() throws {
        signals.add(alert("a"), notify: false)
        signals.add(alert("b", mood: .needsInput), notify: false)
        XCTAssertEqual(api.alerts.list().map(\.id), ["b", "a"])
        XCTAssertEqual(api.alerts.summary?.mood, .needsInput)
        XCTAssertEqual(try api.alerts.get("a").title, "PR a")
        try api.alerts.dismiss("a")
        XCTAssertEqual(api.alerts.list().map(\.id), ["b"])
        XCTAssertThrowsError(try api.alerts.dismiss("a")) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
        api.alerts.dismissAll()
        XCTAssertTrue(api.alerts.list().isEmpty)
        XCTAssertNil(api.alerts.summary)
    }

    func testAskHandsTheAlertsPromptToTheChat() throws {
        signals.add(alert("a", ask: "Why is CI failing?"), notify: false)
        signals.add(alert("b"), notify: false)
        var asked: [String] = []
        XCTAssertThrowsError(try api.alerts.ask("a")) { XCTAssertEqual(($0 as? APIError)?.code, .unavailable) }
        api.alerts.askHandler = { asked.append($0) }
        try api.alerts.ask("a")
        XCTAssertEqual(asked, ["Why is CI failing?"])
        XCTAssertThrowsError(try api.alerts.ask("b")) { XCTAssertEqual(($0 as? APIError)?.code, .invalid) }
    }

    func testAlertChangesArriveOnTheBus() throws {
        signals.add(alert("a"), notify: false)
        try api.alerts.dismiss("a")
        XCTAssertEqual(seen.map(\.kind), [.alertsChanged, .alertsChanged])
    }

    func testAlertRoundTripsAsJSON() throws {
        signals.add(alert("a", ask: "Why?"), notify: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode([Signal].self, from: encoder.encode(api.alerts.list()))
        XCTAssertEqual(back.first?.id, "a")
        XCTAssertEqual(back.first?.mood, .failed)
    }

    func testPressingABubbleButtonRunsItsActionAndClosesTheBubble() throws {
        var approved = 0, denied = 0
        bubbles.show(Bubble(id: "ask", symbol: "hand.raised", tint: .orange, title: "Allow?", actions: [
            .init(title: "Allow", style: .primary) { approved += 1 },
            .init(title: "Deny", style: .destructive) { denied += 1 }]))
        let info = try XCTUnwrap(api.bubbles.list().first)
        XCTAssertEqual(info.actions.map(\.title), ["Allow", "Deny"])
        XCTAssertEqual(info.actions.map(\.style), ["primary", "destructive"])
        try api.bubbles.press(PressBubbleRequest(bubble: "ask", action: info.actions[1].id))
        XCTAssertEqual([approved, denied], [0, 1])
        XCTAssertTrue(api.bubbles.list().isEmpty, "a pressed bubble closes")
    }

    func testPressingALineAndTheBubbleItself() throws {
        var opened: [String] = []
        bubbles.show(Bubble(id: "summary", symbol: "list.bullet", tint: .blue, title: "Back", lines: [
            .init(symbol: "x", tint: .red, text: "One alert") { opened.append("line") }]))
        bubbles.show(Bubble(id: "tap", symbol: "star", tint: .blue, title: "Tap me", onTap: { opened.append("tap") }))
        bubbles.show(Bubble(id: "plain", symbol: "star", tint: .blue, title: "Nothing"))
        let line = try XCTUnwrap(api.bubbles.list().first { $0.id == "summary" }?.lines.first)
        try api.bubbles.press(PressBubbleRequest(bubble: "summary", line: line.id))
        try api.bubbles.press(PressBubbleRequest(bubble: "tap"))
        XCTAssertEqual(opened, ["line", "tap"])
        XCTAssertThrowsError(try api.bubbles.press(PressBubbleRequest(bubble: "plain"))) { XCTAssertEqual(($0 as? APIError)?.code, .invalid) }
        XCTAssertThrowsError(try api.bubbles.press(PressBubbleRequest(bubble: "gone"))) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
        XCTAssertThrowsError(try api.bubbles.press(PressBubbleRequest(bubble: "plain", action: "nope"))) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
    }

    func testDismissAndShownEvents() throws {
        bubbles.show(Bubble(id: "x", symbol: "star", tint: .blue, title: "X"))
        try api.bubbles.dismiss("x")
        XCTAssertThrowsError(try api.bubbles.dismiss("x")) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
        XCTAssertEqual(seen.map(\.kind), [.bubbleShown, .bubbleDismissed])
        XCTAssertEqual(seen.map(\.id), ["x", "x"])
    }

    func testExpiryAndTheBubbleLimitPublishDismissals() {
        bubbles.show(Bubble(id: "short", symbol: "star", tint: .blue, title: "S", expires: Date(timeIntervalSince1970: 10)))
        bubbles.sweep(now: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(seen.map(\.kind), [.bubbleShown, .bubbleDismissed])
        seen = []
        for i in 0...BubbleStore.limit { bubbles.show(Bubble(id: "b\(i)", symbol: "star", tint: .blue, title: "B")) }
        XCTAssertEqual(seen.filter { $0.kind == .bubbleDismissed }.count, 1, "the bubble pushed out by the limit is reported")
    }

    func testBubbleInfoRoundTripsAsJSON() throws {
        bubbles.show(Bubble(id: "x", symbol: "star", tint: .blue, title: "X", body: "Body", onTap: {}))
        let info = try XCTUnwrap(api.bubbles.list().first)
        XCTAssertEqual(try JSONDecoder().decode(BubbleInfo.self, from: JSONEncoder().encode(info)), info)
        XCTAssertTrue(info.tappable)
    }
}
