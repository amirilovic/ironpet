import XCTest
@testable import IronPet

/// Screen captures, desktop control, usage and the Today brief, each driven only through `IronPetAPI`.
@MainActor
final class ScreenDesktopUsageTodayAPITests: XCTestCase {
    private var api: IronPetAPI!
    private var captures: CaptureStore!
    private let slack = CaptureApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack", pid: 100)

    override func setUp() async throws {
        api = APITestSupport.makeAPI()
        captures = CaptureFixtures.store()
        api.attach(capture: CaptureService(store: captures, config: { Config().screenCapture }))
    }

    // MARK: Screen

    func testSearchRecentAndTextOfStoredCaptures() async throws {
        _ = try captures.ingest(app: slack, title: "Ana (DM)", url: nil, trigger: .typingPause, lines: ["Can you review PR 4649 before lunch?"], now: Date().addingTimeInterval(-60))
        let screen = try XCTUnwrap(api.screen)
        let recent = await screen.recent(limit: 10)
        XCTAssertEqual(recent.count, 1)
        let hits = try await screen.search(ScreenSearchRequest(query: "4649"))
        XCTAssertEqual(hits.first?.appName, "Slack")
        let text = await screen.captureText(try XCTUnwrap(hits.first?.id))
        XCTAssertTrue(try XCTUnwrap(text).contains("PR 4649"))
        let miss = try await screen.search(ScreenSearchRequest(query: "nothing like this"))
        XCTAssertTrue(miss.isEmpty)
        do { _ = try await screen.search(ScreenSearchRequest(query: "  ")); XCTFail("searched for nothing") } catch {
            XCTAssertEqual((error as? APIError)?.code, .invalid)
        }
    }

    func testPauseResumeAndClear() throws {
        _ = try captures.ingest(app: slack, title: "x", url: nil, trigger: .typingPause, lines: ["hello world"], now: Date())
        let screen = try XCTUnwrap(api.screen)
        XCTAssertThrowsError(try screen.pause(for: 0)) { XCTAssertEqual(($0 as? APIError)?.code, .invalid) }
        try screen.pause(for: 600)
        screen.resume()
        screen.clear()
        XCTAssertEqual(captures.captureCount, 0)
    }

    func testTheScreenToolsReadTheSameStore() throws {
        _ = try captures.ingest(app: slack, title: "x", url: nil, trigger: .typingPause, lines: ["deploy blocked on review"], now: Date())
        let screen = try XCTUnwrap(api.screen)
        guard case .success(let value) = screen.callTool("screen_search", ["query": "deploy"]), let result = value as? [String: Any] else { return XCTFail("search failed") }
        XCTAssertEqual(result["count"] as? Int, 1)
        guard case .failure = screen.callTool("screen_window", [:]) else { return XCTFail("a window read without id or since should fail") }
    }

    // MARK: Desktop

    func testDesktopControlIsOffUntilTheSettingIsOn() async throws {
        var deps = DesktopService.Dependencies(privacy: CapturePrivacy())
        deps.ax = IdleDesktopAX()
        deps.opener = IdleDesktopOpener()
        deps.enabled = { [unowned self] in api.settings.config.desktopControl.enabled }
        api.attach(desktop: DesktopService(deps))
        let desktop = try XCTUnwrap(api.desktop)
        XCTAssertFalse(desktop.enabled)
        do { try await desktop.press(ref: "e1"); XCTFail("pressed while off") } catch {
            XCTAssertEqual((error as? APIError)?.code, .unavailable)
        }
        api.settings.update { $0.desktopControl.enabled = true }
        XCTAssertTrue(desktop.enabled)
        do { try await desktop.press(ref: "e1"); XCTFail("pressed a missing element") } catch {
            XCTAssertEqual((error as? APIError)?.code, .failed)
        }
        if case .failure(let failure) = await desktop.callTool("desktop_status", [:]) { XCTAssertFalse(failure.message.isEmpty) }
    }

    // MARK: Usage

    func testUsageSummaryTotalsRecordedRequests() throws {
        let usage = try XCTUnwrap(api.usage)
        usage.record(UsageEvent(at: Date(), feature: .chat, model: "opus", duration: 10, inputTokens: 100, outputTokens: 20, cost: 0.5, currency: "USD"))
        usage.record(UsageEvent(at: Date(), feature: .chat, model: "opus", duration: 5, inputTokens: 50, outputTokens: 10, cost: 0.25, currency: "USD"))
        // Writes happen on a background queue; the summary waits for them.
        let summary = try usage.summary(UsageRequest(days: 7))
        XCTAssertEqual(summary.rows.first?.requests, 2)
        XCTAssertEqual(summary.rows.first?.cost ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertThrowsError(try usage.summary(UsageRequest(days: 0))) { XCTAssertEqual(($0 as? APIError)?.code, .invalid) }
        let decoded = try JSONDecoder().decode(UsageSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(decoded.rows.first?.model, "opus")
    }

    // MARK: Today

    func testTheBriefListsTasksThatNeedYou() throws {
        try api.tasks.create(CreateTaskRequest(title: "Approve the deploy", status: .needsYou, source: .agent))
        let brief = api.today.brief(BriefRequest(kind: .brief))
        XCTAssertFalse(brief.isEmpty)
        XCTAssertTrue(brief.sections.flatMap(\.items).contains { $0.title.contains("Approve the deploy") })
        let decoded = try JSONDecoder().decode(Brief.self, from: JSONEncoder().encode(brief))
        XCTAssertEqual(decoded.kind, .brief)
    }
}
