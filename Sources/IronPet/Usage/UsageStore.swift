import Foundation

/// The parts of ironpet that run an agent or a transcription request themselves. Anything ironpet only launches or watches
/// (Band agents, Claude Code or Codex sessions reported through hooks, automation shell commands) has no feature here, so it
/// cannot be recorded.
enum UsageFeature: String, CaseIterable, Codable {
    case chat, automations, jobs, voiceMode, meetingSummary, voiceTranscription, meetingTranscription, memory

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .automations: return "Automations"
        case .jobs: return "Background jobs"
        case .voiceMode: return "Voice mode"
        case .meetingSummary: return "Meeting summaries"
        case .voiceTranscription: return "Voice transcription"
        case .meetingTranscription: return "Meeting transcription"
        case .memory: return "Memory"
        }
    }

    /// Agent features count turns and report tokens and cost. Transcription features count requests and report audio seconds.
    var isTranscription: Bool { self == .voiceTranscription || self == .meetingTranscription }
}

/// One agent turn or one transcription request. A nil number means the agent or provider did not report it, which is
/// different from zero. ironpet never estimates a missing number.
struct UsageEvent: Equatable {
    var at: Date
    var feature: UsageFeature
    var model: String
    /// Wall-clock length of an agent turn. Nil for transcription, whose length is only what the provider reports.
    var duration: TimeInterval?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var totalTokens: Int?
    /// Audio length the transcription provider reported.
    var audioSeconds: Double?
    var cost: Double?
    var currency: String?

    init(at: Date = Date(), feature: UsageFeature, model: String, duration: TimeInterval? = nil, inputTokens: Int? = nil,
         outputTokens: Int? = nil, cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil, totalTokens: Int? = nil,
         audioSeconds: Double? = nil, cost: Double? = nil, currency: String? = nil) {
        self.at = at
        self.feature = feature
        self.model = model
        self.duration = duration
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.audioSeconds = audioSeconds
        self.cost = cost
        self.currency = currency
    }
}

/// Totals for one feature and model over a range. Nil metrics were never reported in the range. `currency` is the one the
/// agent named with its cost.
struct UsageRow: Equatable, Identifiable {
    var feature: UsageFeature
    var model: String
    var currency: String?
    var requests: Int
    var duration: Double?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var totalTokens: Int?
    var audioSeconds: Double?
    var cost: Double?

    var id: String { "\(feature.rawValue)|\(model)" }
}

struct UsageDay: Equatable, Identifiable {
    var day: Date
    var requests: [UsageFeature: Int]
    /// Tokens the agents or providers reported that day, input plus output (or the reported total when that is all there is).
    var tokens: [UsageFeature: Int]
    /// Cost the agents reported in the bucket. Events without a cost add 0.
    var cost: [UsageFeature: Double] = [:]
    var id: Date { day }
}

struct UsageSummary: Equatable {
    var rows: [UsageRow]
    /// One entry per calendar day, or per hour of today when the summary is hourly. The name is kept for the daily case.
    var days: [UsageDay]
    var hourly = false
    /// Cost reported for the local day of `now`, whatever the range.
    var todayCost = 0.0
    /// Events in the range that reported no cost. The cost chart counts them as 0.
    var uncostedEvents = 0
    var rangeCost: Double { rows.reduce(0) { $0 + ($1.cost ?? 0) } }
    var hasCost: Bool { rows.contains { $0.cost != nil } }
}

/// ironpet's own usage history in `ironpet.db`. Nothing here leaves the machine. Writes happen on a background queue, once
/// per turn or request, so streaming never waits for the database.
final class UsageStore: @unchecked Sendable {
    /// The app's store. Nil until the app opens its database, so tests and previews record nothing unless they pass their own.
    nonisolated(unsafe) static var shared: UsageStore?

    /// Events older than this are deleted. The Usage tab shows 90 days at most, and the brief asks for a year of history.
    static let retentionDays = 400

    static let migrations: [Database.Migration] = [
        .init(100, "usage: events", sql: """
            CREATE TABLE usage_events(id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, feature TEXT NOT NULL, model TEXT NOT NULL,
                                      duration REAL, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
                                      cache_write_tokens INTEGER, total_tokens INTEGER, audio_seconds REAL, cost REAL, currency TEXT);
            CREATE INDEX usage_events_by_time ON usage_events(at);
            """),
        // The first turn after a resumed chat session was recorded with the session's lifetime cost. Only rows more than 20 times
        // their token-implied cost change, and they end up at that value, so running it again changes nothing.
        // Numbered 430, not 101: the database has one version for every feature (see `AppMigrations`), and installs were already at
        // 422 when this was added, so a number at or below that never runs on them. Keep it above every other migration.
        .init(430, "usage: correct chat cost recorded from a resumed session's lifetime total", sql: UsagePricing.correctionSQL),
    ]

    private let database: Database
    private let queue = DispatchQueue(label: "ironpet.usage", qos: .utility)
    /// Only touched on `queue`.
    private var lastPrune = Date.distantPast

    /// Why the database is unavailable, when usage is only in memory.
    var unavailable: String? { database.unavailableReason }

    init(database: Database) {
        self.database = database
        queue.async { [self] in prune() }
    }

    /// Deletes events past the retention limit, at most once a day, so an app that runs for months still trims the table.
    private func prune() {
        guard Date().timeIntervalSince(lastPrune) > 86_400 else { return }
        lastPrune = Date()
        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86_400).timeIntervalSince1970
        try? database.write { try $0.execute("DELETE FROM usage_events WHERE at < ?", [cutoff]) }
    }

    /// Queues the event for writing and returns at once.
    func record(_ event: UsageEvent) {
        queue.async { [self] in
            prune()
            do {
                try database.write { db in
                    try db.execute("""
                        INSERT INTO usage_events(at, feature, model, duration, input_tokens, output_tokens, cache_read_tokens,
                                                 cache_write_tokens, total_tokens, audio_seconds, cost, currency)
                        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, [event.at.timeIntervalSince1970, event.feature.rawValue, event.model, event.duration, event.inputTokens,
                              event.outputTokens, event.cacheReadTokens, event.cacheWriteTokens, event.totalTokens, event.audioSeconds,
                              event.cost, event.currency])
                }
            } catch {
                NSLog("ironpet: could not record usage: \(error.localizedDescription)")
            }
        }
    }

    /// Waits for queued writes. Tests call it before reading.
    func flush() { queue.sync {} }

    /// Totals per feature and model plus one entry per calendar day, for the last `days` days including today.
    /// `hourly` cuts the buckets by hour instead of by day, which only makes sense for one day.
    func summary(days: Int, hourly: Bool = false, now: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        flush()
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return UsageSummary(rows: [], days: []) }
        let from = start.timeIntervalSince1970
        let to = (calendar.date(byAdding: .day, value: 1, to: today) ?? now).timeIntervalSince1970
        var rows: [UsageRow] = []
        var requests: [Date: [UsageFeature: Int]] = [:]
        var tokens: [Date: [UsageFeature: Int]] = [:]
        var costs: [Date: [UsageFeature: Double]] = [:]
        var uncosted = 0
        var todayCost = 0.0
        let unit: Calendar.Component = hourly ? .hour : .day
        do {
            try database.read { db in
                for row in try db.rows("""
                    SELECT feature, model, MAX(currency), COUNT(*), SUM(duration), SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens),
                           SUM(cache_write_tokens), SUM(total_tokens), SUM(audio_seconds), SUM(cost)
                    FROM usage_events WHERE at >= ? AND at < ? GROUP BY feature, model ORDER BY feature, model
                    """, [from, to]) {
                    guard let feature = (row[0] as? String).flatMap(UsageFeature.init(rawValue:)) else { continue }
                    rows.append(UsageRow(feature: feature, model: row[1] as? String ?? "", currency: row[2] as? String,
                                         requests: Int(row[3] as? Int64 ?? 0), duration: row[4] as? Double,
                                         inputTokens: Self.int(row[5]), outputTokens: Self.int(row[6]), cacheReadTokens: Self.int(row[7]),
                                         cacheWriteTokens: Self.int(row[8]), totalTokens: Self.int(row[9]), audioSeconds: row[10] as? Double,
                                         cost: row[11] as? Double))
                }
                // Days are cut in Swift, not SQL, so they follow the same calendar as the range.
                if let sum = try db.rows("SELECT SUM(cost) FROM usage_events WHERE at >= ? AND at < ?",
                                           [calendar.startOfDay(for: now).timeIntervalSince1970,
                                            (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now).timeIntervalSince1970]).first {
                    todayCost = sum[0] as? Double ?? 0
                }
                for row in try db.rows("SELECT at, feature, input_tokens, output_tokens, total_tokens, cost FROM usage_events WHERE at >= ? AND at < ?",
                                       [from, to]) {
                    guard let at = row[0] as? Double, let feature = (row[1] as? String).flatMap(UsageFeature.init(rawValue:)) else { continue }
                    let date = Date(timeIntervalSince1970: at)
                    let day = calendar.dateInterval(of: unit, for: date)?.start ?? calendar.startOfDay(for: date)
                    if let cost = row[5] as? Double { costs[day, default: [:]][feature, default: 0] += cost } else { uncosted += 1 }
                    requests[day, default: [:]][feature, default: 0] += 1
                    let input = Self.int(row[2]), output = Self.int(row[3])
                    if let count = (input == nil && output == nil) ? Self.int(row[4]) : (input ?? 0) + (output ?? 0) {
                        tokens[day, default: [:]][feature, default: 0] += count
                    }
                }
            }
        } catch {
            NSLog("ironpet: could not read usage: \(error.localizedDescription)")
        }
        let buckets: [Date] = hourly
            ? (0..<24).compactMap { calendar.date(byAdding: .hour, value: $0, to: today) }
            : (0..<days).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let list = buckets.map {
            UsageDay(day: $0, requests: requests[$0] ?? [:], tokens: tokens[$0] ?? [:], cost: costs[$0] ?? [:])
        }
        return UsageSummary(rows: rows, days: list, hourly: hourly, todayCost: todayCost, uncostedEvents: uncosted)
    }

    private static func int(_ value: Database.Value) -> Int? { (value as? Int64).map(Int.init) }
}

/// Every feature's migrations, in the order the database applies them.
enum AppMigrations {
    static let all = AutomationState.migrations + UsageStore.migrations + TaskStore.migrations + CaptureStore.migrations + ActivityLog.migrations
        + JobService.migrations + MemoryIndex.migrations
}

// MARK: Agent usage

extension UsageEvent {
    /// Reads the `usage` object of a `session/prompt` response (ACP: `inputTokens`, `outputTokens`, `totalTokens`,
    /// `cachedReadTokens`, `cachedWriteTokens`). A key the agent leaves out stays nil.
    static func applyACPUsage(_ usage: JSON?, to event: inout UsageEvent) {
        guard let usage else { return }
        func number(_ key: String) -> Int? { (usage[key] as? NSNumber).map { $0.intValue } }
        event.inputTokens = number("inputTokens")
        event.outputTokens = number("outputTokens")
        event.cacheReadTokens = number("cachedReadTokens")
        event.cacheWriteTokens = number("cachedWriteTokens")
        event.totalTokens = number("totalTokens")
    }
}

// MARK: Transcription usage

/// What a transcription provider reported about one request.
struct TranscriptionUsage: Equatable {
    var audioSeconds: Double?
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?

    /// Reads the OpenAI `usage` object (`type` is `duration` or `tokens`), else the top-level `duration` of a `verbose_json`
    /// answer. Returns nil when the response reports neither. Accepts one JSON object or newline-delimited JSON.
    static func parse(_ data: Data) -> TranscriptionUsage? {
        for object in Transcriber.jsonObjects(data).reversed() {
            if let usage = object["usage"] as? [String: Any], let parsed = fromUsage(usage) { return parsed }
            if let seconds = (object["duration"] as? NSNumber)?.doubleValue, seconds >= 0 { return TranscriptionUsage(audioSeconds: seconds) }
        }
        return nil
    }

    private static func fromUsage(_ usage: [String: Any]) -> TranscriptionUsage? {
        switch usage["type"] as? String {
        case "duration":
            guard let seconds = (usage["seconds"] as? NSNumber)?.doubleValue else { return nil }
            return TranscriptionUsage(audioSeconds: seconds)
        case "tokens":
            let input = (usage["input_tokens"] as? NSNumber)?.intValue
            let output = (usage["output_tokens"] as? NSNumber)?.intValue
            let total = (usage["total_tokens"] as? NSNumber)?.intValue
            guard input != nil || output != nil || total != nil else { return nil }
            return TranscriptionUsage(inputTokens: input, outputTokens: output, totalTokens: total)
        default:
            return nil
        }
    }

    func event(feature: UsageFeature, model: String, at: Date = Date()) -> UsageEvent {
        UsageEvent(at: at, feature: feature, model: model, inputTokens: inputTokens, outputTokens: outputTokens, totalTokens: totalTokens,
                   audioSeconds: audioSeconds)
    }
}
