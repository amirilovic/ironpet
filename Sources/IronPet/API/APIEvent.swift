import Foundation

/// What changed. A client that gets one of these reads the area again through the API. The event carries an id
/// only when one thing changed (a task id, an alert id), so every event stays small and has no private text in it.
enum APIEventKind: String, Codable, CaseIterable {
    case tasksChanged = "tasks.changed"
    case suggestionsChanged = "suggestions.changed"
    case chatItem = "chat.item"
    case chatState = "chat.state"
    case agentsChanged = "agents.changed"
    case alertsChanged = "alerts.changed"
    case bubbleShown = "bubble.shown"
    case bubbleDismissed = "bubble.dismissed"
    case automationsChanged = "automations.changed"
    case meetingsChanged = "meetings.changed"
    case settingsChanged = "settings.changed"
    case petMood = "pet.mood"
    case assetsChanged = "assets.changed"
}

struct APIEvent: Codable, Equatable {
    /// Counts up from 1 for the life of the app. A client that reconnects passes the last `seq` it saw.
    let seq: Int
    let at: Date
    let kind: APIEventKind
    /// The thing that changed, when it is one thing.
    let id: String?
}

/// The one event stream. Stores publish into it, and clients subscribe to it. It keeps the last `capacity` events so a client
/// that was away can ask for what it missed.
@MainActor
final class APIEventBus {
    /// Handle for one subscription. `cancel()` stops delivery.
    @MainActor
    final class Subscription {
        fileprivate let token = UUID()
        private weak var bus: APIEventBus?
        /// True when the buffer no longer held every event after the `seq` the client gave. The client missed some
        /// and has to read the whole state again.
        let gap: Bool

        fileprivate init(bus: APIEventBus, gap: Bool) {
            self.bus = bus
            self.gap = gap
        }

        func cancel() { bus?.handlers[token] = nil }
    }

    /// Kinds whose events replace an earlier buffered event with the same id.
    private static let coalesces: Set<APIEventKind> = [.chatItem, .chatState]
    /// How far back the buffer looks for the event to replace.
    private static let coalesceWindow = 64

    let capacity: Int
    private(set) var lastSeq = 0
    private var buffer: [APIEvent] = []
    private var handlers: [UUID: (APIEvent) -> Void] = [:]
    private let now: () -> Date

    init(capacity: Int = 500, now: @escaping () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.now = now
    }

    func publish(_ kind: APIEventKind, id: String? = nil) {
        lastSeq += 1
        let event = APIEvent(seq: lastSeq, at: now(), kind: kind, id: id)
        // Streamed text changes one message hundreds of times. A client only needs to know that it changed since it last looked, so
        // the buffer keeps the newest event for each message (and for each part of the chat state) instead of every one.
        // Live subscribers still get every event. Without this a few seconds of streaming would push every other event out.
        if Self.coalesces.contains(kind), let id,
           let earlier = buffer[max(0, buffer.count - Self.coalesceWindow)...].lastIndex(where: { $0.kind == kind && $0.id == id }) {
            buffer.remove(at: earlier)
        }
        buffer.append(event)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        for handler in Array(handlers.values) { handler(event) }
    }

    /// The events with a `seq` above `seq`, oldest first, and whether older ones were already dropped.
    func replay(after seq: Int) -> (events: [APIEvent], gap: Bool) {
        let missed = buffer.filter { $0.seq > seq }
        let oldest = buffer.first?.seq ?? (lastSeq + 1)
        // A `seq` above `lastSeq` comes from an earlier launch, whose numbers restarted: the client must re-read everything.
        return (missed, seq + 1 < oldest || seq > lastSeq)
    }

    /// Calls `handler` with every later event. With `after`, it first gets the buffered events above that `seq`, in order, before
    /// any new one, so a reconnecting client sees no hole and no repeat.
    @discardableResult
    func subscribe(after seq: Int? = nil, _ handler: @escaping (APIEvent) -> Void) -> Subscription {
        var gap = false
        if let seq {
            let missed = replay(after: seq)
            gap = missed.gap
            missed.events.forEach(handler)
        }
        let subscription = Subscription(bus: self, gap: gap)
        handlers[subscription.token] = handler
        return subscription
    }
}
