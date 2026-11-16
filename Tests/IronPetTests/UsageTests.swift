import XCTest
@testable import IronPet

final class UsageTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// Noon on 2026-03-20.
    private let now = Date(timeIntervalSince1970: 1_774_008_000)

    private func daysAgo(_ days: Int, hour: Int = 9) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .hour, value: hour, to: calendar.date(byAdding: .day, value: -days, to: start)!)!
    }

    private func memoryStore() throws -> UsageStore {
        UsageStore(database: try Database(path: nil, migrations: AppMigrations.all))
    }

    // MARK: Aggregation (S5)

    func testTotalsPerFeatureAndModelAndPerDayMatchTheStoredEvents() throws {
        let store = try memoryStore()
        store.record(UsageEvent(at: daysAgo(0), feature: .chat, model: "opus", duration: 10, inputTokens: 100, outputTokens: 20, cost: 0.5, currency: "USD"))
        store.record(UsageEvent(at: daysAgo(0, hour: 11), feature: .chat, model: "opus", duration: 5, inputTokens: 50, outputTokens: 10, cost: 0.25, currency: "USD"))
        store.record(UsageEvent(at: daysAgo(3), feature: .chat, model: "sonnet", duration: 2))
        store.record(UsageEvent(at: daysAgo(20), feature: .chat, model: "opus", duration: 1, inputTokens: 7, outputTokens: 1))
        store.record(UsageEvent(at: daysAgo(60), feature: .automations, model: "sonnet", duration: 4))
        store.record(UsageEvent(at: daysAgo(1), feature: .voiceTranscription, model: "whisper-1", audioSeconds: 12.5))
        store.record(UsageEvent(at: daysAgo(1), feature: .meetingTranscription, model: "gpt-4o-transcribe", inputTokens: 300, outputTokens: 80, totalTokens: 380))

        let week = store.summary(days: 7, now: now, calendar: calendar)
        XCTAssertEqual(Set(week.rows.map(\.id)), ["chat|opus", "chat|sonnet", "voiceTranscription|whisper-1", "meetingTranscription|gpt-4o-transcribe"])
        let opus = try XCTUnwrap(week.rows.first { $0.model == "opus" })
        XCTAssertEqual(opus.requests, 2)
        XCTAssertEqual(opus.duration, 15)
        XCTAssertEqual(opus.inputTokens, 150)
        XCTAssertEqual(opus.outputTokens, 30)
        XCTAssertEqual(opus.cost ?? 0, 0.75, accuracy: 1e-9)
        let sonnet = try XCTUnwrap(week.rows.first { $0.model == "sonnet" })
        XCTAssertNil(sonnet.inputTokens, "nothing reported stays nil, not zero")
        XCTAssertNil(sonnet.cost)
        XCTAssertEqual(week.rows.first { $0.model == "whisper-1" }?.audioSeconds, 12.5)
        XCTAssertTrue(week.hasCost)

        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.days.last?.requests[.chat], 2)
        XCTAssertEqual(week.days.last?.tokens[.chat], 180)
        XCTAssertEqual(week.days[5].requests[.voiceTranscription], 1)
        XCTAssertEqual(week.days[5].tokens[.meetingTranscription], 380)
        XCTAssertNil(week.days[5].tokens[.voiceTranscription], "audio seconds are not tokens")
        XCTAssertEqual(week.days[3].requests[.chat], 1)

        let month = store.summary(days: 30, now: now, calendar: calendar)
        XCTAssertEqual(month.days.count, 30)
        XCTAssertEqual(month.rows.first { $0.model == "opus" }?.requests, 3)
        XCTAssertNil(month.rows.first { $0.feature == .automations })

        let quarter = store.summary(days: 90, now: now, calendar: calendar)
        XCTAssertEqual(quarter.rows.first { $0.feature == .automations }?.requests, 1)
        XCTAssertEqual(quarter.days.map(\.requests).flatMap(\.values).reduce(0, +), 7)
    }

    // MARK: Persistence (S7)

    func testRecordsSurviveReopeningTheDatabase() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-usage-\(UUID().uuidString)/ironpet.db")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = UsageStore(database: try Database(path: url, migrations: AppMigrations.all))
        first.record(UsageEvent(at: daysAgo(0), feature: .chat, model: "opus", duration: 3, inputTokens: 9))
        first.flush()

        let second = UsageStore(database: try Database(path: url, migrations: AppMigrations.all))
        let row = try XCTUnwrap(second.summary(days: 7, now: now, calendar: calendar).rows.first)
        XCTAssertEqual(row.model, "opus")
        XCTAssertEqual(row.inputTokens, 9)
    }

    func testEventsOlderThanTheRetentionAreDeletedWhenTheStoreOpens() throws {
        let database = try Database(path: nil, migrations: AppMigrations.all)
        let old = Date().addingTimeInterval(-Double(UsageStore.retentionDays + 5) * 86_400).timeIntervalSince1970
        let kept = Date().addingTimeInterval(-370 * 86_400).timeIntervalSince1970
        for at in [old, kept] {
            try database.write { try $0.execute("INSERT INTO usage_events(at, feature, model) VALUES(?, 'chat', 'm')", [at]) }
        }
        let store = UsageStore(database: database)
        store.flush()
        let count = try database.read { try $0.rows("SELECT COUNT(*) FROM usage_events").first?.first as? Int64 }
        XCTAssertEqual(count, 1, "a year of history stays")
    }

    func testUsageMigrationDoesNotDisturbAutomationTables() throws {
        let database = try Database(path: nil, migrations: AppMigrations.all)
        XCTAssertEqual(database.schemaVersion, AppMigrations.all.map(\.version).max())
        XCTAssertNoThrow(try database.read { try $0.rows("SELECT COUNT(*) FROM automation_runs") })
    }

    // MARK: Transcription usage (S4)

    private func parse(_ json: String) -> TranscriptionUsage? { TranscriptionUsage.parse(Data(json.utf8)) }

    func testDurationUsageObject() {
        XCTAssertEqual(parse(#"{"text":"hi","usage":{"type":"duration","seconds":7}}"#), TranscriptionUsage(audioSeconds: 7))
    }

    func testTokenUsageObject() {
        let json = #"{"text":"hi","usage":{"type":"tokens","input_tokens":14,"output_tokens":3,"total_tokens":17,"input_token_details":{"audio_tokens":12,"text_tokens":2}}}"#
        XCTAssertEqual(parse(json), TranscriptionUsage(inputTokens: 14, outputTokens: 3, totalTokens: 17))
    }

    func testVerboseJSONDurationAlone() {
        XCTAssertEqual(parse(#"{"text":"hi","duration":4.25,"segments":[]}"#), TranscriptionUsage(audioSeconds: 4.25))
    }

    func testNoUsageAndNoDurationMeansNothingToRecord() {
        XCTAssertNil(parse(#"{"text":"hi"}"#))
        XCTAssertNil(parse(#"{"text":"hi","usage":{"type":"unknown"}}"#))
        XCTAssertNil(parse("not json"))
    }

    func testNewlineDelimitedAnswerUsesTheObjectThatReportsUsage() {
        XCTAssertEqual(parse("{\"text\":\"a\"}\n{\"text\":\"b\",\"usage\":{\"type\":\"duration\",\"seconds\":2}}\n"), TranscriptionUsage(audioSeconds: 2))
    }

    func testEventCarriesTheRequestModelAndOnlyReportedNumbers() {
        let event = TranscriptionUsage(audioSeconds: 7).event(feature: .voiceTranscription, model: "whisper-1", at: now)
        XCTAssertEqual(event, UsageEvent(at: now, feature: .voiceTranscription, model: "whisper-1", audioSeconds: 7))
        XCTAssertNil(event.duration)
    }

    // MARK: Formatting

    func testNotReportedPrintsADashAndZeroPrintsZero() {
        XCTAssertEqual(UsageFormat.count(nil), "–")
        XCTAssertEqual(UsageFormat.count(0), "0")
        XCTAssertEqual(UsageFormat.cost(nil, currency: nil), "–")
        XCTAssertEqual(UsageFormat.time(nil), "–")
    }
}
