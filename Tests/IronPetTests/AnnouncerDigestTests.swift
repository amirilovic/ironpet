import XCTest
@testable import IronPet

@MainActor
final class AnnouncerDigestTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_774_008_000)
    private var window: DateInterval { DateInterval(start: start, duration: 3600) }

    private func event(_ kind: ActivityEvent.Kind, _ ref: String, title: String? = nil, detail: String = "", url: URL? = nil,
                       extra: [String: String] = [:]) -> ActivityEvent {
        ActivityEvent(at: start.addingTimeInterval(60), kind: kind, ref: ref, title: title ?? ref, detail: detail, url: url, extra: extra)
    }

    private func text(_ events: [ActivityEvent]) -> String {
        let item = ActivityDigest.build(events: events, window: window).items[0]
        return Announcer.digestLine(item, petName: "Ghost").text
    }

    func testOneThingIsNamedAndSeveralAreCounted() {
        XCTAssertEqual(text([event(.sessionNeedsInput, "c:1", title: "demo-app")]), "demo-app is waiting for you")
        XCTAssertEqual(text([event(.sessionNeedsInput, "c:1"), event(.sessionNeedsInput, "c:2")]), "2 agents are waiting for you")
        XCTAssertEqual(text([event(.sessionFailed, "c:1", title: "api")]), "api failed")
        XCTAssertEqual(text([event(.sessionFailed, "c:1"), event(.sessionFailed, "c:2")]), "2 agents failed")
        XCTAssertEqual(text([event(.sessionDone, "c:1", title: "demo-app")]), "demo-app finished")
        XCTAssertEqual(text([event(.sessionDone, "c:1"), event(.sessionDone, "c:2")]), "2 agents finished")
        XCTAssertEqual(text([event(.alertOpened, "a", title: "Fix login", detail: "irtaza/ironpet #84", extra: ["label": "CI failed"])]),
                       "CI failed: irtaza/ironpet #84")
        XCTAssertEqual(text([event(.alertOpened, "a"), event(.alertOpened, "b"), event(.alertOpened, "c")]), "3 new alerts")
        XCTAssertEqual(text([event(.alertResolved, "a", title: "Fix login", detail: "irtaza/ironpet #84", extra: ["label": "CI failed"])]),
                       "Cleared: CI failed: irtaza/ironpet #84")
        XCTAssertEqual(text([event(.taskDue, "t", title: "Renew the domain")]), "Task due: Renew the domain")
        XCTAssertEqual(text([event(.taskDue, "t"), event(.taskDue, "u")]), "2 tasks due")
        XCTAssertEqual(text([event(.taskSuggested, "a"), event(.taskSuggested, "b"), event(.taskSuggested, "c")]), "3 suggested tasks")
        XCTAssertEqual(text([event(.meetingSummary, "/m/summary.md", title: "2026-11-17 10-00 Standup")]),
                       "Meeting summary ready: 2026-11-17 10-00 Standup")
        XCTAssertEqual(text([event(.chatFinished, "chat", title: "Ghost finished your task")]), "Ghost finished your task")
        XCTAssertEqual(text([event(.automationBubble, "n", title: "CI passed", detail: "Fix login\nirtaza/ironpet #84")]), "CI passed: Fix login")
        XCTAssertEqual(text([event(.automationBubble, "n", title: "Standup in 5 minutes")]), "Standup in 5 minutes")
        XCTAssertEqual(text([event(.automationBubble, "n"), event(.automationBubble, "m")]), "2 updates from automations")
        XCTAssertEqual(text([event(.init("task.handoff.done"), "h", title: "Handed-off task finished")]), "Handed-off task finished")
    }

    func testAtMostFiveLinesWithTheRestCounted() {
        let kinds: [ActivityEvent.Kind] = [.sessionNeedsInput, .sessionFailed, .alertOpened, .sessionDone, .taskDue, .taskSuggested, .meetingSummary]
        var events = kinds.map { event($0, $0.rawValue) }
        events.append(event(.taskSuggested, "second"))
        let digest = ActivityDigest.build(events: events, window: window)
        let bubble = Announcer.digestBubble(digest, id: "welcome-back", title: "Welcome back", subtitle: nil, petName: "Ghost",
                                            open: { _ in }, showAll: {})
        XCTAssertEqual(bubble.lines.count, 5)
        XCTAssertEqual(bubble.lines.last?.text, "and 4 more", "task due, two suggestions and the meeting")
        let fits = Announcer.digestBubble(ActivityDigest.build(events: Array(events.prefix(5)), window: window), id: "x", title: "t",
                                          subtitle: nil, petName: "Ghost", open: { _ in }, showAll: {})
        XCTAssertEqual(fits.lines.count, 5)
        XCTAssertFalse(fits.lines.contains { $0.text.hasPrefix("and ") })
        XCTAssertEqual(bubble.actions.map(\.title), ["Show all"])
        XCTAssertNotNil(bubble.expires)
    }

    func testLinesOpenTheirTargetAndTheRestShowsAll() {
        let url = URL(string: "https://github.com/x/y/pull/1")!
        let digest = ActivityDigest.build(events: [event(.alertOpened, "a", url: url), event(.init("other.kind"), "o")], window: window)
        var opened: [ActivityDigest.Target] = []
        var all = 0
        let bubble = Announcer.digestBubble(digest, id: "x", title: "t", subtitle: nil, petName: "Ghost",
                                            open: { opened.append($0) }, showAll: { all += 1 })
        bubble.lines[0].run()
        bubble.lines[1].run()
        XCTAssertEqual(opened, [.url(url)])
        XCTAssertEqual(all, 1, "a line with nothing to open shows the window")
    }

    func testAwayText() {
        XCTAssertEqual(Announcer.awayText(42 * 60), "While you were away (42 min)")
        XCTAssertEqual(Announcer.awayText(20), "While you were away (1 min)")
        XCTAssertEqual(Announcer.awayText(65 * 60), "While you were away (1 h 5 min)")
        XCTAssertEqual(Announcer.awayText(120 * 60), "While you were away (2 h)")
    }
}
