import XCTest
@testable import IronPet

@MainActor
final class APIEventTests: XCTestCase {
    func testSequenceCountsUpFromOne() {
        let bus = APIEventBus()
        var seen: [APIEvent] = []
        bus.subscribe { seen.append($0) }
        bus.publish(.tasksChanged, id: "a")
        bus.publish(.alertsChanged)
        XCTAssertEqual(seen.map(\.seq), [1, 2])
        XCTAssertEqual(seen.map(\.kind), [.tasksChanged, .alertsChanged])
        XCTAssertEqual(seen.first?.id, "a")
        XCTAssertNil(seen.last?.id)
    }

    func testReconnectGetsMissedEventsThenLiveOnesWithoutRepeat() {
        let bus = APIEventBus()
        bus.publish(.tasksChanged)
        bus.publish(.chatItem)
        bus.publish(.settingsChanged)
        var seen: [Int] = []
        let subscription = bus.subscribe(after: 1) { seen.append($0.seq) }
        XCTAssertFalse(subscription.gap)
        bus.publish(.petMood)
        XCTAssertEqual(seen, [2, 3, 4])
    }

    func testSubscribingWithoutSeqSkipsHistory() {
        let bus = APIEventBus()
        bus.publish(.tasksChanged)
        var seen: [Int] = []
        bus.subscribe { seen.append($0.seq) }
        XCTAssertTrue(seen.isEmpty)
    }

    func testBufferKeepsOnlyCapacityAndReportsAGap() {
        let bus = APIEventBus(capacity: 3)
        for _ in 0..<5 { bus.publish(.agentsChanged) }
        let replay = bus.replay(after: 0)
        XCTAssertEqual(replay.events.map(\.seq), [3, 4, 5])
        XCTAssertTrue(replay.gap)
        XCTAssertFalse(bus.replay(after: 2).gap)
        var seen: [Int] = []
        let subscription = bus.subscribe(after: 1) { seen.append($0.seq) }
        XCTAssertTrue(subscription.gap)
        XCTAssertEqual(seen, [3, 4, 5])
    }

    func testSeqFromAnEarlierLaunchReportsAGap() {
        let bus = APIEventBus()
        bus.publish(.agentsChanged)
        XCTAssertTrue(bus.replay(after: 900).gap)
        XCTAssertFalse(bus.replay(after: 1).gap)
        XCTAssertTrue(APIEventBus().replay(after: 10).gap)
    }

    func testStreamedChatEventsKeepOneBufferedEventPerMessageAndLeaveOthersAlone() {
        let bus = APIEventBus(capacity: 30)
        bus.publish(.tasksChanged, id: "t1")
        var live = 0
        bus.subscribe { _ in live += 1 }
        for _ in 0..<1_000 { bus.publish(.chatItem, id: "reply") }
        bus.publish(.chatItem, id: "other")
        bus.publish(.chatState, id: "status")
        bus.publish(.chatState, id: "status")
        XCTAssertEqual(live, 1_003, "a live subscriber hears every event")
        let buffered = bus.replay(after: 0).events
        XCTAssertEqual(buffered.map(\.kind), [.tasksChanged, .chatItem, .chatItem, .chatState])
        XCTAssertEqual(buffered.map(\.id), ["t1", "reply", "other", "status"])
        XCTAssertEqual(buffered.map(\.seq), buffered.map(\.seq).sorted(), "still in order")
        XCTAssertFalse(bus.replay(after: 0).gap)
    }

    func testMergingAnEventIntoANewerOneIsNotAGap() {
        let bus = APIEventBus(capacity: 30)
        bus.publish(.chatItem, id: "reply")
        bus.publish(.chatItem, id: "reply")
        bus.publish(.chatItem, id: "reply")
        XCTAssertEqual(bus.replay(after: 0).events.map(\.seq), [3])
        XCTAssertFalse(bus.replay(after: 0).gap, "seq 1 and 2 were merged into 3, so the client missed nothing")
    }

    func testChatEventsWithoutAnIdAreNeverMerged() {
        let bus = APIEventBus()
        bus.publish(.chatItem)
        bus.publish(.chatItem)
        XCTAssertEqual(bus.replay(after: 0).events.count, 2)
    }

    func testCancelStopsDelivery() {
        let bus = APIEventBus()
        var count = 0
        let subscription = bus.subscribe { _ in count += 1 }
        bus.publish(.bubbleShown)
        subscription.cancel()
        bus.publish(.bubbleShown)
        XCTAssertEqual(count, 1)
    }

    func testEventsRoundTripAsJSON() throws {
        let event = APIEvent(seq: 7, at: Date(timeIntervalSince1970: 1_800_000_000), kind: .meetingsChanged, id: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(APIEvent.self, from: encoder.encode(event))
        XCTAssertEqual(back, event)
        XCTAssertTrue(String(decoding: try encoder.encode(event), as: UTF8.self).contains("meetings.changed"))
    }

    func testErrorKeepsCodeAndMessage() throws {
        let error = APIError.notFound("no task with id \"x\"")
        let back = try JSONDecoder().decode(APIError.self, from: JSONEncoder().encode(error))
        XCTAssertEqual(back, error)
        XCTAssertEqual(error.localizedDescription, "no task with id \"x\"")
        XCTAssertEqual(APIError.wrap(error), error)
    }
}

/// Each store publishes the events its area owns, with a `seq` that keeps counting.
@MainActor
final class APIStoreEventTests: XCTestCase {
    private var bus: APIEventBus!
    private var seen: [APIEvent] = []

    override func setUp() async throws {
        bus = APIEventBus()
        seen = []
        bus.subscribe { [unowned self] in seen.append($0) }
    }

    func testTaskStorePublishesTasksAndSuggestions() throws {
        let store = TaskStore(database: APITestSupport.memoryDatabase(), keepDoneDays: { 30 })
        store.events = bus
        let task = try store.create(title: "Write the plan", source: .user, by: "test")
        try store.close(task.id, by: "test")
        store.suggest([(title: "Send the notes", due: nil, waitingOn: nil)], meeting: URL(fileURLWithPath: "/tmp/meeting-a"))
        XCTAssertEqual(seen.map(\.kind), [.tasksChanged, .tasksChanged, .suggestionsChanged])
        XCTAssertEqual(seen.first?.id, task.id)
        XCTAssertNil(seen.last?.id)
        XCTAssertEqual(seen.map(\.seq), [1, 2, 3])
    }

    func testSignalStorePublishesAlerts() {
        let store = SignalStore()
        store.events = bus
        store.add(Signal(id: "ci", title: "CI failed", subtitle: "", url: nil, label: "CI", symbol: "x", mood: .failed, ask: nil), notify: false)
        store.dismiss("ci")
        XCTAssertEqual(seen.map(\.kind), [.alertsChanged, .alertsChanged])
    }

    func testSessionStorePublishesAgents() {
        let store = SessionStore()
        store.events = bus
        store.apply(HookEvent(source: .claude, name: "UserPromptSubmit", payload: ["session_id": "s1"], origin: SessionOrigin()))
        XCTAssertEqual(seen.map(\.kind), [.agentsChanged])
    }

    func testBubbleStorePublishesTheShownBubble() {
        let store = BubbleStore()
        store.events = bus
        store.show(Bubble(id: "hello", symbol: "star", tint: .blue, title: "Hello"))
        XCTAssertEqual(seen.map(\.kind), [.bubbleShown])
        XCTAssertEqual(seen.first?.id, "hello")
    }

    func testMeetingControllerPublishesMeetings() {
        let controller = MeetingController()
        controller.events = bus
        controller.isEnabled = { true }
        controller.meetingConfig = { Config.Meetings() }
        controller.runningApps = { [] }
        controller.showPicker()
        XCTAssertTrue(seen.contains { $0.kind == .meetingsChanged })
    }
}
