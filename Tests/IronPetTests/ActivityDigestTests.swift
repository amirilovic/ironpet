import XCTest
@testable import IronPet

final class ActivityDigestTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_774_008_000)
    private var window: DateInterval { DateInterval(start: start, duration: 3600) }

    private func event(_ kind: ActivityEvent.Kind, _ ref: String, minute: Double = 1, url: URL? = nil,
                       extra: [String: String] = [:]) -> ActivityEvent {
        ActivityEvent(at: start.addingTimeInterval(minute * 60), kind: kind, ref: ref, title: ref, url: url, extra: extra)
    }

    func testEmptyWindowGivesAnEmptyDigest() {
        let digest = ActivityDigest.build(events: [], window: window)
        XCTAssertTrue(digest.isEmpty)
        XCTAssertEqual(digest.count, 0)
    }

    func testWindowIncludesItsStartAndExcludesItsEnd() {
        let events = [event(.sessionDone, "before", minute: -1), event(.sessionDone, "first", minute: 0),
                      event(.sessionDone, "last", minute: 59.9), event(.sessionDone, "after", minute: 60)]
        let digest = ActivityDigest.build(events: events, window: window)
        XCTAssertEqual(digest.items.flatMap { $0.events.map(\.ref) }, ["last", "first"])
    }

    func testGroupsByKindKeepsTheLatestPerRefAndOrdersByUrgency() {
        let events = [
            event(.automationBubble, "ci-passed", minute: 1),
            event(.sessionDone, "claude:1", minute: 2),
            event(.sessionDone, "claude:1", minute: 9),
            event(.sessionDone, "cursor:2", minute: 5),
            event(.taskDue, "renew", minute: 3),
            event(.sessionNeedsInput, "codex:3", minute: 4),
            event(.alertOpened, "ci", minute: 6),
            event(.init("task.handoff.done"), "x", minute: 7),
            event(.alertResolved, "old-ci", minute: 8),
            event(.sessionFailed, "pi:4", minute: 8),
        ]
        let digest = ActivityDigest.build(events: events, window: window)
        XCTAssertEqual(digest.items.map(\.kind.rawValue), ["session.needsInput", "session.failed", "alert.opened", "session.done", "task.due",
                                                           "automation.bubble", "alert.resolved", "task.handoff.done"])
        let done = digest.items[3]
        XCTAssertEqual(done.events.map(\.ref), ["claude:1", "cursor:2"], "one per session, newest first")
        XCTAssertEqual(done.events.first?.at, start.addingTimeInterval(9 * 60))
        XCTAssertEqual(digest.count, 9)
    }

    func testWithoutLiveStateEverythingInTheWindowCounts() {
        let events = [event(.sessionDone, "s"), event(.alertOpened, "a"), event(.taskSuggested, "t"), event(.taskDue, "d")]
        XCTAssertEqual(ActivityDigest.build(events: events, window: window, live: nil).count, 4)
    }

    func testLiveStateDropsWhatTheUserAlreadyDealtWith() {
        let events = [
            event(.sessionDone, "acknowledged"), event(.sessionDone, "still-done"),
            event(.sessionNeedsInput, "answered"), event(.sessionNeedsInput, "waiting"),
            event(.alertOpened, "closed"), event(.alertOpened, "open"),
            event(.taskSuggested, "added"), event(.taskSuggested, "waiting-suggestion"),
            event(.taskDue, "done-task"), event(.taskDue, "due-task"),
            event(.automationBubble, "news"), event(.meetingSummary, "meeting"),
        ]
        let live = ActivityDigest.LiveState(sessions: ["still-done": .sessionDone, "answered": .sessionDone, "waiting": .sessionNeedsInput],
                                            openAlerts: ["open"], waitingSuggestions: ["waiting-suggestion"], dueTasks: ["due-task"])
        let digest = ActivityDigest.build(events: events, window: window, live: live)
        XCTAssertEqual(Set(digest.items.flatMap { $0.events.map(\.ref) }),
                       ["still-done", "waiting", "open", "waiting-suggestion", "due-task", "news", "meeting"])
    }

    func testExcludedKindsAreLeftOut() {
        let events = [event(.taskDue, "d"), event(.sessionDone, "s")]
        let live = ActivityDigest.LiveState(sessions: ["s": .sessionDone], dueTasks: ["d"], excluded: [.taskDue])
        XCTAssertEqual(ActivityDigest.build(events: events, window: window, live: live).items.map(\.kind), [.sessionDone])
    }

    func testTargetsOpenTheThingOrItsList() throws {
        let one = ActivityDigest.build(events: [event(.sessionDone, "claude:1", extra: ["workspace": "/w", "app": "com.x", "iterm": "w0"])],
                                       window: window)
        XCTAssertEqual(one.items.first?.target, .session(id: "claude:1", workspace: "/w", app: "com.x", iterm: "w0"))
        let two = ActivityDigest.build(events: [event(.sessionDone, "a"), event(.sessionDone, "b")], window: window)
        XCTAssertEqual(two.items.first?.target, .agents)

        let pr = URL(string: "https://github.com/x/y/pull/1")!
        XCTAssertEqual(ActivityDigest.build(events: [event(.alertOpened, "a", url: pr)], window: window).items.first?.target, .url(pr))
        XCTAssertEqual(ActivityDigest.build(events: [event(.alertOpened, "a", url: pr), event(.alertOpened, "b")], window: window).items.first?.target, .alerts)
        XCTAssertEqual(ActivityDigest.build(events: [event(.taskDue, "t")], window: window).items.first?.target, .tasks)
        let file = URL(fileURLWithPath: "/m/summary.md")
        XCTAssertEqual(ActivityDigest.build(events: [event(.meetingSummary, "m", url: file)], window: window).items.first?.target, .file(file))
        XCTAssertEqual(ActivityDigest.build(events: [event(.chatFinished, "chat")], window: window).items.first?.target, .chat)
        XCTAssertEqual(ActivityDigest.build(events: [event(.automationBubble, "n")], window: window).items.first?.target, .automations)
        XCTAssertNil(ActivityDigest.build(events: [event(.init("other.kind"), "o")], window: window).items.first?.target)
    }

    func testUrgencyIsWaitingFailedOrAFailingAlert() {
        func urgent(_ events: [ActivityEvent]) -> Bool { ActivityDigest.build(events: events, window: window).items.first?.isUrgent ?? false }
        XCTAssertTrue(urgent([event(.sessionNeedsInput, "s")]))
        XCTAssertTrue(urgent([event(.sessionFailed, "s")]))
        XCTAssertTrue(urgent([event(.alertOpened, "a", extra: ["mood": "failed"])]))
        XCTAssertFalse(urgent([event(.alertOpened, "a", extra: ["mood": "needsInput"])]))
        XCTAssertFalse(urgent([event(.sessionDone, "s")]))
    }
}
