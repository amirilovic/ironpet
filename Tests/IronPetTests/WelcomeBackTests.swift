import XCTest
@testable import IronPet

@MainActor
final class WelcomeBackTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_774_008_000)
    private let threshold: TimeInterval = 300

    // MARK: Away tracker

    func testShortIdleStaysPresent() {
        var tracker = AwayTracker()
        XCTAssertNil(tracker.sample(now: start, idleSeconds: 299, threshold: threshold, present: false))
        XCTAssertNil(tracker.awaySince)
    }

    func testIdleAtTheThresholdLeavesFromTheLastInput() {
        var tracker = AwayTracker()
        _ = tracker.sample(now: start.addingTimeInterval(300), idleSeconds: 298, threshold: threshold, present: false)
        let now = start.addingTimeInterval(302)
        XCTAssertEqual(tracker.sample(now: now, idleSeconds: 300, threshold: threshold, present: false), .left(since: start.addingTimeInterval(2)))
        XCTAssertNil(tracker.sample(now: now.addingTimeInterval(2), idleSeconds: 302, threshold: threshold, present: false), "still away")
        let back = now.addingTimeInterval(600)
        XCTAssertEqual(tracker.sample(now: back, idleSeconds: 1, threshold: threshold, present: false),
                       .returned(since: start.addingTimeInterval(2), at: back))
        XCTAssertNil(tracker.awaySince)
    }

    func testASleepGapStartsAtTheLastSampleBeforeIt() {
        var tracker = AwayTracker()
        _ = tracker.sample(now: start, idleSeconds: 0, threshold: threshold, present: false)
        let woke = start.addingTimeInterval(3600)
        XCTAssertEqual(tracker.sample(now: woke, idleSeconds: 3600, threshold: threshold, present: false), .left(since: start))
        XCTAssertEqual(tracker.sample(now: woke.addingTimeInterval(2), idleSeconds: 0, threshold: threshold, present: false),
                       .returned(since: start, at: woke.addingTimeInterval(2)))

        var typing = AwayTracker()
        _ = typing.sample(now: start, idleSeconds: 0, threshold: threshold, present: false)
        XCTAssertEqual(typing.sample(now: woke, idleSeconds: 2, threshold: threshold, present: false), .returned(since: start, at: woke),
                       "woke and already typing")
    }

    func testPresenceNeverLeavesAndCancelsAStretch() {
        var tracker = AwayTracker()
        XCTAssertNil(tracker.sample(now: start, idleSeconds: 900, threshold: threshold, present: true))
        XCTAssertNotNil(tracker.sample(now: start.addingTimeInterval(2), idleSeconds: 902, threshold: threshold, present: false))
        XCTAssertNil(tracker.sample(now: start.addingTimeInterval(4), idleSeconds: 904, threshold: threshold, present: true))
        XCTAssertNil(tracker.awaySince)
        XCTAssertNil(tracker.sample(now: start.addingTimeInterval(6), idleSeconds: 1, threshold: threshold, present: false), "no return after a call")
    }

    func testAThresholdChangeAppliesOnTheNextSample() {
        var tracker = AwayTracker()
        XCTAssertNil(tracker.sample(now: start, idleSeconds: 400, threshold: 600, present: false))
        XCTAssertNotNil(tracker.sample(now: start.addingTimeInterval(2), idleSeconds: 402, threshold: 300, present: false))
    }

    // MARK: Coordinator

    private final class Clock {
        var now: Date
        var idle: TimeInterval = 0
        var locked = false
        var present = false
        var enabled = true
        init(_ now: Date) { self.now = now }
    }

    private struct Fixture {
        let clock: Clock
        let log: ActivityLog
        let bubbles: BubbleStore
        let welcome: WelcomeBack
        var shown: [(ActivityDigest, TimeInterval)] { shownBox.value }
        let shownBox: Box
    }

    private final class Box { var value: [(ActivityDigest, TimeInterval)] = [] }

    private func fixture(live: ActivityDigest.LiveState = .init()) throws -> Fixture {
        let clock = Clock(start)
        let log = ActivityLog(database: try Database(path: nil, migrations: AppMigrations.all), now: { clock.now })
        let bubbles = BubbleStore()
        bubbles.now = { clock.now }
        var env = WelcomeBack.Environment()
        env.now = { clock.now }
        env.idleSeconds = { clock.idle }
        env.isScreenLocked = { clock.locked }
        env.isPresent = { clock.present }
        env.isEnabled = { clock.enabled }
        env.threshold = { 300 }
        let welcome = WelcomeBack(log: log, bubbles: bubbles, env: env)
        welcome.live = { live }
        let box = Box()
        welcome.show = { digest, away in
            box.value.append((digest, away))
            bubbles.show(Bubble(id: WelcomeBack.bubbleID, symbol: "sun.max.fill", tint: .accentColor, title: "Welcome back",
                                expires: clock.now.addingTimeInterval(180)))
        }
        welcome.tick()
        return Fixture(clock: clock, log: log, bubbles: bubbles, welcome: welcome, shownBox: box)
    }

    /// Last input at the start, counted away after 5 minutes, `during` 10 minutes in, back at 15 minutes.
    private func awayAndBack(_ f: Fixture, during: () -> Void) {
        f.clock.now = f.clock.now.addingTimeInterval(300)
        f.clock.idle = 300
        f.welcome.tick()
        f.clock.now = f.clock.now.addingTimeInterval(300)
        during()
        f.clock.now = f.clock.now.addingTimeInterval(300)
        f.clock.idle = 0
        f.welcome.tick()
    }

    private func done(_ f: Fixture, _ id: String) {
        f.log.record(ActivityEvent(at: f.clock.now, kind: .sessionDone, ref: id, title: "demo-app"))
        f.bubbles.show(Bubble(id: "session:\(id)", symbol: "checkmark", tint: .green, title: "demo-app: Done",
                              expires: f.clock.now.addingTimeInterval(15)))
    }

    func testReturnShowsOneSummaryAndFoldsTheBubblesItCovers() throws {
        let f = try fixture(live: .init(sessions: ["claude:1": .sessionDone, "claude:2": .sessionDone]))
        f.bubbles.show(Bubble(id: "say", symbol: "pawprint", tint: .accentColor, title: "Before", expires: start.addingTimeInterval(9999)))
        awayAndBack(f) {
            done(f, "claude:1")
            done(f, "claude:2")
            f.bubbles.show(Bubble(id: "approval:x", symbol: "hand.raised.fill", tint: .orange, title: "Allow?"))
        }
        XCTAssertEqual(f.shown.count, 1)
        XCTAssertEqual(f.shown.first?.0.items.first?.count, 2)
        XCTAssertEqual(f.shown.first?.1, 900, "counted from the last input, not from when the idle time crossed the threshold")
        XCTAssertEqual(Set(f.bubbles.bubbles.map(\.id)), ["say", "approval:x", WelcomeBack.bubbleID],
                       "the done bubbles fold in; the answer-needed one and the older one stay")
    }

    func testNothingInTheWindowShowsNothing() throws {
        let f = try fixture()
        awayAndBack(f) {}
        XCTAssertTrue(f.shown.isEmpty)
        XCTAssertEqual(f.welcome.lastDigest?.isEmpty, true)
    }

    func testOneItemWhoseBubbleIsStillUpShowsNothing() throws {
        let f = try fixture(live: .init(sessions: ["claude:1": .sessionDone]))
        awayAndBack(f) { done(f, "claude:1") }
        XCTAssertTrue(f.shown.isEmpty)
        XCTAssertEqual(f.bubbles.bubbles.map(\.id), ["session:claude:1"])
    }

    func testOneItemWhoseBubbleExpiredIsSummarized() throws {
        let f = try fixture(live: .init(sessions: ["claude:1": .sessionDone]))
        awayAndBack(f) {
            done(f, "claude:1")
            f.bubbles.sweep(now: f.clock.now.addingTimeInterval(60))
        }
        XCTAssertEqual(f.shown.count, 1)
    }

    func testTheSwitchOffShowsNothing() throws {
        let f = try fixture(live: .init(sessions: ["claude:1": .sessionDone, "claude:2": .sessionDone]))
        f.clock.enabled = false
        awayAndBack(f) { done(f, "claude:1"); done(f, "claude:2") }
        XCTAssertTrue(f.shown.isEmpty)
        XCTAssertEqual(f.bubbles.bubbles.count, 2, "nothing folded")
    }

    func testALockedScreenWaitsForUnlock() throws {
        let f = try fixture(live: .init(sessions: ["claude:1": .sessionDone, "claude:2": .sessionDone]))
        f.clock.locked = true
        awayAndBack(f) { done(f, "claude:1"); done(f, "claude:2") }
        XCTAssertTrue(f.shown.isEmpty)
        XCTAssertNotNil(f.welcome.pendingSince)
        f.clock.locked = false
        f.clock.now = f.clock.now.addingTimeInterval(2)
        f.welcome.tick()
        XCTAssertEqual(f.shown.count, 1)
        XCTAssertNil(f.welcome.pendingSince)
    }

    func testAMeetingThroughTheStretchShowsNothing() throws {
        let f = try fixture(live: .init(sessions: ["claude:1": .sessionDone, "claude:2": .sessionDone]))
        f.clock.present = true
        awayAndBack(f) { done(f, "claude:1"); done(f, "claude:2") }
        XCTAssertTrue(f.shown.isEmpty)
    }

    func testADailyBriefOnScreenOrRecentSkipsTheSummary() throws {
        let f = try fixture(live: .init(sessions: ["claude:1": .sessionDone, "claude:2": .sessionDone]))
        awayAndBack(f) {
            done(f, "claude:1"); done(f, "claude:2")
            f.bubbles.show(Bubble(id: "digest:brief", symbol: "sun.horizon", tint: .accentColor, title: "Morning brief"))
        }
        XCTAssertTrue(f.shown.isEmpty, "on screen")

        f.bubbles.dismiss("digest:brief")
        f.clock.now = f.clock.now.addingTimeInterval(20 * 60)
        f.welcome.summarize(DateInterval(start: start, end: f.clock.now))
        XCTAssertTrue(f.shown.isEmpty, "shown 20 minutes ago")

        f.clock.now = f.clock.now.addingTimeInterval(11 * 60)
        f.welcome.summarize(DateInterval(start: start, end: f.clock.now))
        XCTAssertEqual(f.shown.count, 1, "over 30 minutes ago")
    }

    func testATaskDueBubbleOnScreenKeepsTasksOutOfTheSummary() throws {
        let f = try fixture(live: .init(sessions: ["claude:1": .sessionDone, "claude:2": .sessionDone], dueTasks: ["renew"]))
        awayAndBack(f) {
            done(f, "claude:1"); done(f, "claude:2")
            f.log.record(ActivityEvent(at: f.clock.now, kind: .taskDue, ref: "renew", title: "Renew"))
            f.bubbles.show(Bubble(id: Announcer.tasksDueID, symbol: "calendar", tint: .accentColor, title: "Due today: Renew"))
        }
        XCTAssertEqual(f.shown.first?.0.items.map(\.kind), [.sessionDone])
        XCTAssertTrue(f.bubbles.bubbles.contains { $0.id == Announcer.tasksDueID })
    }

    func testLiveStateComesFromTheStores() {
        var waiting = AgentSession(id: "codex:1", source: .codex)
        waiting.status = .needsInput
        var running = AgentSession(id: "pi:2", source: .pi)
        running.status = .running
        let signal = Signal(id: "a", title: "t", subtitle: "", url: nil, label: "CI failed", symbol: "x", mood: .failed)
        let due = TaskItem(id: "due", title: "Due", notes: "", status: .backlog, source: .chat, due: start, links: [], created: start, updated: start, closed: nil)
        var closed = due
        closed = TaskItem(id: "closed", title: "Closed", notes: "", status: .done, source: .chat, due: start, links: [], created: start, updated: start, closed: start)
        let later = TaskItem(id: "later", title: "Later", notes: "", status: .backlog, source: .chat, due: start.addingTimeInterval(86_400), links: [],
                             created: start, updated: start, closed: nil)
        let suggestion = TaskSuggestion(id: "s", title: "S", origin: .meeting(URL(fileURLWithPath: "/m")), created: start)
        let live = WelcomeBack.liveState(sessions: [waiting, running], signals: [signal], tasks: [due, closed, later], suggestions: [suggestion], now: start)
        XCTAssertEqual(live.sessions, ["codex:1": .sessionNeedsInput])
        XCTAssertEqual(live.openAlerts, ["a"])
        XCTAssertEqual(live.dueTasks, ["due"])
        XCTAssertEqual(live.waitingSuggestions, ["s"])
    }

    func testBubbleIDsMatchWhatTheAppShows() {
        func id(_ kind: ActivityEvent.Kind, _ ref: String) -> String { WelcomeBack.bubbleID(for: ActivityEvent(kind: kind, ref: ref, title: "")) }
        XCTAssertEqual(id(.sessionFailed, "claude:1"), "session:claude:1")
        XCTAssertEqual(id(.alertOpened, "automation:gh:1"), "signal:automation:gh:1")
        XCTAssertEqual(id(.automationBubble, "automation:gh:abcd1234"), "automation:gh:abcd1234")
        XCTAssertEqual(id(.taskDue, "x"), Announcer.tasksDueID)
        XCTAssertEqual(id(.meetingSummary, "/m/summary.md"), "meeting-summary")
        XCTAssertEqual(id(.chatFinished, "chat"), "chat")
    }

    // MARK: Bubble store

    func testShowRecordsWhenAndPrefixesFindTheLatest() {
        let store = BubbleStore()
        var now = start
        store.now = { now }
        store.show(Bubble(id: "digest:brief", symbol: "a", tint: .accentColor, title: "a"))
        now = start.addingTimeInterval(60)
        store.show(Bubble(id: "digest:recap", symbol: "a", tint: .accentColor, title: "a"))
        XCTAssertEqual(store.shownAt["digest:brief"], start)
        XCTAssertEqual(store.lastShown(prefix: "digest:"), start.addingTimeInterval(60))
        now = start.addingTimeInterval(120)
        store.show(Bubble(id: "digest:brief", symbol: "a", tint: .accentColor, title: "a"))
        XCTAssertEqual(store.shownAt["digest:brief"], now, "showing again restamps")
        now = start.addingTimeInterval(2 * 3600)
        store.show(Bubble(id: "other", symbol: "a", tint: .accentColor, title: "a"))
        XCTAssertNil(store.lastShown(prefix: "digest:"), "forgotten after an hour")
    }
}
