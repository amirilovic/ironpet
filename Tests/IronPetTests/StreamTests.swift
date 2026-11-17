import XCTest
@testable import IronPet

private let testEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

/// A pid that no longer exists.
private func gone(_ pid: pid_t) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

@MainActor
private func waitUntil(_ message: String, timeout: TimeInterval = 5, _ check: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !check(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    XCTAssertTrue(check(), "timed out waiting for \(message)", file: file, line: line)
}

private func stream(_ id: String = "s", command: String, createdBy: String = "user", action: Automation.Action = .init(type: "bubble", title: "event"),
                    _ configure: (inout Automation.Trigger) -> Void = { _ in }) -> Automation {
    var trigger = Automation.Trigger(type: "stream", command: command)
    configure(&trigger)
    return Automation(id: id, name: id, trigger: trigger, action: action, createdBy: createdBy)
}

// MARK: - The engine alone

@MainActor
final class StreamEngineTests: XCTestCase {
    var dir: URL!
    var engine: StreamEngine!
    var fired: [(item: [String: Any], count: Int)] = []
    var logs: [(outcome: String, summary: String, detail: String)] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        engine = StreamEngine()
        engine.enabled = true
        engine.environment = { testEnvironment }
        engine.limits.grace = 0.3
        engine.fire = { [unowned self] _, item, count, done in fired.append((item, count)); done() }
        engine.onLog = { [unowned self] _, outcome, summary, detail, _ in
            logs.append((outcome, summary, detail))
            XCTAssertLessThanOrEqual(engine.runningCount, 1, "never two copies")
        }
    }

    override func tearDown() async throws {
        engine.shutdown(timeout: 3)
        try? FileManager.default.removeItem(at: dir)
    }

    private func pid(in name: String) -> pid_t? {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func numbers() -> [Int] { fired.compactMap { ($0.item["n"] as? NSNumber)?.intValue } }

    // S1
    func testEachJSONLineFiresInOrder() async {
        let command = #"sh -c 'for i in 1 2 3; do echo "{\"n\":$i}"; sleep 0.2; done; sleep 30'"#
        engine.sync([stream(command: command) { $0.mode = "json"; $0.id = "n" }], mayRun: { _ in true })
        await waitUntil("three events") { numbers().count >= 3 }
        XCTAssertEqual(numbers(), [1, 2, 3])
        XCTAssertEqual(engine.status("s"), .running)
        XCTAssertNotNil(engine.lastEvent("s"))
    }

    func testARepeatedIDDoesNotFireAgainButANewVersionDoes() async {
        let command = #"printf '{"n":1,"v":1}\n{"n":2,"v":1}\n{"n":1,"v":1}\n{"n":2,"v":2}\n'; sleep 30"#
        engine.sync([stream(command: command) { $0.mode = "json"; $0.id = "n"; $0.version = "v" }], mayRun: { _ in true })
        await waitUntil("the events") { fired.reduce(0) { $0 + $1.count } >= 3 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        // The repeated 1 never reaches the action. The burst merges into the first event and the newest of the rest.
        XCTAssertEqual(fired.reduce(0) { $0 + $1.count }, 3)
        XCTAssertEqual(fired.last.flatMap { ($0.item["v"] as? NSNumber)?.intValue }, 2)
    }

    func testLinesModeGivesItemLineAndFilterKeepsMatches() async {
        let command = "printf 'info one\\nerror two\\ninfo three\\nerror four\\n'; sleep 30"
        engine.sync([stream(command: command) { $0.when = "contains(line, 'error')" }], mayRun: { _ in true })
        await waitUntil("two events") { fired.count >= 2 }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fired.compactMap { $0.item["line"] as? String }, ["error two", "error four"])
    }

    func testItemsExpressionTurnsOneLineIntoSeveralEvents() async {
        let command = #"echo '{"files":[{"p":"a"},{"p":"b"}]}'; sleep 30"#
        engine.sync([stream(command: command) { $0.mode = "json"; $0.items = "files" }], mayRun: { _ in true })
        await waitUntil("events") { fired.count >= 1 }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fired.reduce(0) { $0 + $1.count }, 2)
    }

    // S2
    func testDebounceFiresOnceWithTheLastItemAndTheCount() async {
        let command = #"i=1; while [ $i -le 10 ]; do echo "{\"n\":$i}"; i=$((i+1)); sleep 0.04; done; sleep 30"#
        engine.sync([stream(command: command) { $0.mode = "json"; $0.debounceSeconds = 1 }], mayRun: { _ in true })
        await waitUntil("the debounced fire", timeout: 6) { !fired.isEmpty }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(numbers(), [10])
        XCTAssertEqual(fired.first?.count, 10)
    }

    // S3
    func testAnImmediateExitIsRestartedWithGrowingBackoffAndLogged() async {
        engine.limits.minBackoff = 0.05
        engine.limits.maxBackoff = 0.4
        engine.sync([stream(command: "exit 1")], mayRun: { _ in true })
        await waitUntil("four starts") { logs.filter { $0.summary.hasPrefix("started") }.count >= 4 }
        let delays = logs.compactMap { entry -> Double? in
            guard entry.summary.hasPrefix("restarting in "), let text = entry.summary.split(separator: " ").dropFirst(2).first else { return nil }
            return Double(text)
        }
        XCTAssertGreaterThanOrEqual(delays.count, 3)
        XCTAssertEqual(Array(delays.prefix(3)), [0.05, 0.1, 0.2])
        XCTAssertTrue(logs.contains { $0.outcome == "failed" && $0.summary.contains("exit code 1") })
    }

    func testALongRunResetsTheBackoff() async {
        engine.limits.minBackoff = 0.05
        engine.limits.healthyRun = 0.2
        engine.sync([stream(command: "sleep 0.3")], mayRun: { _ in true })
        await waitUntil("three restarts") { logs.filter { $0.summary.hasPrefix("restarting in") }.count >= 3 }
        let delays = logs.filter { $0.summary.hasPrefix("restarting in") }.map(\.summary)
        XCTAssertEqual(Set(delays).count, 1, "every run was long enough, so the delay stays at the minimum: \(delays)")
    }

    // S4
    private func startWithChild(_ extra: String = "") async -> (pid: pid_t, child: pid_t) {
        let command = "\(extra)sleep 60 & echo $! > '\(dir.path)/child.pid'; echo $$ > '\(dir.path)/self.pid'; wait"
        engine.sync([stream(command: command)], mayRun: { _ in true })
        await waitUntil("both pids") { pid(in: "child.pid") != nil && pid(in: "self.pid") != nil }
        return (pid(in: "self.pid") ?? 0, pid(in: "child.pid") ?? 0)
    }

    private func assertGone(_ pids: (pid: pid_t, child: pid_t), file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("the process and its child to be gone", timeout: 5, { gone(pids.pid) && gone(pids.child) }, file: file, line: line)
    }

    func testPausingStopsTheProcessAndItsChildren() async {
        let pids = await startWithChild()
        XCTAssertFalse(gone(pids.child))
        engine.sync([stream { $0 }.paused()], mayRun: { _ in true })
        await assertGone(pids)
        await waitUntil("status stopped") { engine.status("s") == .stopped }
    }

    func testDeletingStopsTheProcessAndItsChildren() async {
        let pids = await startWithChild()
        engine.sync([], mayRun: { _ in true })
        await assertGone(pids)
    }

    func testAnApprovalThatGoesAwayStopsIt() async {
        let pids = await startWithChild()
        engine.sync([stream(command: "unused")], mayRun: { _ in false })
        await assertGone(pids)
    }

    func testUpdatingRestartsWithTheNewCommandAndNeverTwoCopies() async {
        let pids = await startWithChild()
        engine.sync([stream(command: "echo '{\"n\":7}'; sleep 60") { $0.mode = "json" }], mayRun: { _ in true })
        await assertGone(pids)
        await waitUntil("the new command's event") { numbers() == [7] }
        XCTAssertEqual(engine.runningCount, 1)
    }

    func testShutdownStopsACommandThatIgnoresSIGTERM() async {
        let pids = await startWithChild("trap '' TERM; ")
        let started = Date()
        engine.shutdown(timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "quitting does not hang on a stuck child")
        await assertGone(pids)
    }

    func testTerminateKillsAChildThatIgnoresSIGTERMAfterTheGraceTime() async {
        let pids = await startWithChild("trap '' TERM; ")
        engine.sync([], mayRun: { _ in true })
        await assertGone(pids)
    }

    func testChildrenLeftBehindByAnExitingCommandAreStopped() async {
        engine.limits.minBackoff = 30
        let command = "sleep 60 & echo $! > '\(dir.path)/child.pid'; exit 0"
        engine.sync([stream(command: command)], mayRun: { _ in true })
        await waitUntil("the child pid") { pid(in: "child.pid") != nil }
        guard let child = pid(in: "child.pid") else { return }
        await waitUntil("the orphan to be stopped", timeout: 5) { gone(child) }
    }

    // S6
    func testActionsNeverOverlapAndOnlyTheNewestPendingEventFires() async {
        var active = 0, overlapped = false
        engine.fire = { [unowned self] _, item, count, done in
            fired.append((item, count))
            active += 1
            if active > 1 { overlapped = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { active -= 1; done() }
        }
        let command = #"echo '{"n":1}'; sleep 0.3; for i in 2 3 4 5 6; do echo "{\"n\":$i}"; done; sleep 60"#
        engine.sync([stream(command: command) { $0.mode = "json" }], mayRun: { _ in true })
        await waitUntil("the second fire", timeout: 8) { fired.count >= 2 }
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(numbers(), [1, 6], "the newest pending event only")
        XCTAssertEqual(fired.last?.count, 5)
        XCTAssertFalse(overlapped)
    }

    // Limits
    func testEventsOverTheRateAreDroppedAndLogged() async {
        engine.limits.summaryInterval = 0.1
        let command = "i=0; while [ $i -lt 100 ]; do echo line$i; i=$((i+1)); done; sleep 30"
        engine.sync([stream(command: command)], mayRun: { _ in true })
        await waitUntil("the drop summary") { logs.contains { $0.summary.contains("dropped") } }
        XCTAssertEqual(fired.reduce(0) { $0 + $1.count }, engine.limits.maxEventsPerSecond)
        XCTAssertTrue(logs.contains { $0.detail.contains("over 20 events a second") })
    }

    func testALineOverTheCapIsDroppedAndTheNextOneStillFires() async {
        engine.limits.maxLine = 1000
        engine.limits.summaryInterval = 0.1
        let command = "head -c 5000 /dev/zero | tr '\\\\0' x; echo; echo ok; sleep 30"
        engine.sync([stream(command: command)], mayRun: { _ in true })
        await waitUntil("the ok event") { fired.contains { $0.item["line"] as? String == "ok" } }
        XCTAssertEqual(fired.count, 1)
        await waitUntil("the drop summary") { logs.contains { $0.detail.contains("line over 1000 bytes") } }
    }

    func testStderrGoesToTheLogAndIsNotAnEvent() async {
        engine.limits.summaryInterval = 0.1
        engine.sync([stream(command: "echo oops >&2; echo fine; sleep 30")], mayRun: { _ in true })
        await waitUntil("the stderr log and the event") { logs.contains { $0.detail.contains("oops") } && !fired.isEmpty }
        XCTAssertEqual(fired.compactMap { $0.item["line"] as? String }, ["fine"])
    }

    func testNothingStartsUntilEnabled() {
        engine.enabled = false
        engine.sync([stream(command: "sleep 30")], mayRun: { _ in true })
        XCTAssertEqual(engine.runningCount, 0)
        XCTAssertEqual(engine.status("s"), .stopped)
    }

    func testAnUnchangedDefinitionKeepsTheSameProcess() async {
        engine.sync([stream(command: "sleep 30")], mayRun: { _ in true })
        let first = engine.pid("s")
        engine.sync([stream(command: "sleep 30")], mayRun: { _ in true })
        XCTAssertNotNil(first)
        XCTAssertEqual(engine.pid("s"), first)
    }
}

private extension Automation {
    func paused() -> Automation { var copy = self; copy.enabled = false; return copy }
}

private func stream(_ configure: (inout Automation.Trigger) -> Void) -> Automation { stream(command: "x", configure) }

// MARK: - Coalescing

@MainActor
final class EventCoalescerTests: XCTestCase {
    func testDebounceWaitsForQuietAndKeepsTheLatest() async {
        let c = EventCoalescer(debounce: 0.2)
        var got: [(Int, Int)] = []
        c.fire = { event, count, done in got.append((event["n"] as? Int ?? 0, count)); done() }
        for n in 1...5 { c.submit(["n": n]); try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(got.isEmpty)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(got.map(\.0), [5])
        XCTAssertEqual(got.map(\.1), [5])
    }

    func testThrottleLimitsFiresToOnePerWindow() async {
        let c = EventCoalescer(throttle: 0.4)
        var got: [(Int, Int)] = []
        c.fire = { event, count, done in got.append((event["n"] as? Int ?? 0, count)); done() }
        c.submit(["n": 1])
        c.submit(["n": 2])
        c.submit(["n": 3])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(got.map(\.0), [1])
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(got.map(\.0), [1, 3])
        XCTAssertEqual(got.map(\.1), [1, 2])
    }

    func testResetDropsAPendingEvent() async {
        let c = EventCoalescer(debounce: 0.2)
        var got = 0
        c.fire = { _, _, done in got += 1; done() }
        c.submit(["n": 1])
        c.reset()
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(got, 0)
    }

    func testJMESTruthiness() {
        XCTAssertFalse(JMES.truthy(nil))
        XCTAssertFalse(JMES.truthy(""))
        XCTAssertFalse(JMES.truthy([Any]()))
        XCTAssertFalse(JMES.truthy([String: Any]()))
        XCTAssertFalse(JMES.truthy(false))
        XCTAssertTrue(JMES.truthy(0))
        XCTAssertTrue(JMES.truthy(NSNumber(value: 0)))
        XCTAssertFalse(JMES.truthy(NSNumber(value: false)))
        XCTAssertTrue(JMES.truthy("x"))
        XCTAssertTrue(JMES.truthy(true))
    }
}

// MARK: - Through the service

@MainActor
final class StreamAutomationTests: AutomationTestCase {
    override func setUp() async throws {
        try await super.setUp()
    }

    private func rig(_ list: [Automation]) -> Rig {
        let rig = makeRig(list)
        rig.engine.streams.environment = { testEnvironment }
        rig.engine.streams.limits.grace = 0.3
        addTeardownBlock { @MainActor in rig.service.stop() }
        return rig
    }

    // S5
    func testAnAgentsStreamDoesNotStartUntilApproved() async throws {
        let rig = rig([])
        rig.engine.streams.environment = { testEnvironment }
        let created = await rig.service.call("create", ["name": "Watch", "id": "watch", "trigger": ["type": "stream", "command": "sleep 30"],
                                                        "action": ["type": "bubble", "title": "x"]], by: "agent:mcp")
        if case .failure(let error) = created { return XCTFail(error.message) }
        XCTAssertEqual(rig.engine.streams.runningCount, 0)
        guard case .success(let value) = await rig.service.call("get", ["id": "watch"], by: "agent:mcp"), let detail = value as? [String: Any] else { return XCTFail() }
        XCTAssertEqual(detail["approval"] as? String, "pending")
        XCTAssertEqual(detail["stream"] as? String, "stopped")
        XCTAssertEqual(rig.service.approvalDetail(rig.store.automations[0]), "sleep 30")
        rig.service.approve("watch")
        XCTAssertEqual(rig.engine.streams.runningCount, 1)
        guard case .success(let after) = await rig.service.call("get", ["id": "watch"], by: "agent:mcp"), let running = after as? [String: Any] else { return XCTFail() }
        XCTAssertEqual(running["stream"] as? String, "running")
        XCTAssertNil(running["approval"])
    }

    func testChangingTheCommandStopsItUntilApprovedAgain() async throws {
        let rig = rig([stream(command: "sleep 30", createdBy: "agent:mcp")])
        rig.service.approve("s")
        XCTAssertEqual(rig.engine.streams.runningCount, 1)
        let old = try XCTUnwrap(rig.engine.streams.pid("s"))
        _ = await rig.service.call("update", ["id": "s", "changes": ["trigger": ["command": "sleep 31"]]], by: "agent:mcp")
        await until("the old process to go") { gone(old) && rig.engine.streams.runningCount == 0 }
        XCTAssertEqual(rig.engine.streams.status("s"), .stopped)
        XCTAssertTrue(rig.service.needsApproval(rig.store.automations[0]))
        rig.service.approve("s")
        XCTAssertEqual(rig.engine.streams.status("s"), .running)
    }

    func testAUsersOwnStreamStartsWithoutApproval() {
        let rig = rig([stream(command: "sleep 30")])
        XCTAssertEqual(rig.engine.streams.runningCount, 1)
    }

    func testPausingAndResumingThroughTheService() async throws {
        let rig = rig([stream(command: "sleep 30")])
        let pid = try XCTUnwrap(rig.engine.streams.pid("s"))
        _ = await rig.service.call("pause", ["id": "s"], by: "user")
        await until("the process to go") { gone(pid) }
        _ = await rig.service.call("resume", ["id": "s"], by: "user")
        await until("a new process") { rig.engine.streams.pid("s") != nil && rig.engine.streams.pid("s") != pid }
    }

    func testDeletingThroughTheServiceStopsIt() async throws {
        let rig = rig([stream(command: "sleep 30")])
        let pid = try XCTUnwrap(rig.engine.streams.pid("s"))
        _ = await rig.service.call("delete", ["id": "s"], by: "user")
        await until("the process to go") { gone(pid) }
    }

    func testStoppingTheServiceStopsEveryStreamAndItsChildren() async throws {
        let command = "sleep 60 & echo $! > '\(dir.path)/child.pid'; wait"
        let rig = rig([stream(command: command)])
        let pid = try XCTUnwrap(rig.engine.streams.pid("s"))
        await until("the child pid") { FileManager.default.fileExists(atPath: self.dir.appendingPathComponent("child.pid").path) }
        let child = try XCTUnwrap(pid_t((try String(contentsOf: dir.appendingPathComponent("child.pid"), encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
        rig.service.stop()
        await until("both to be gone") { gone(pid) && gone(child) }
    }

    func testAnEventRunsTheActionWithItemAndCount() async {
        let rig = rig([])
        var ran: [String] = []
        rig.service.runShell = { command, _ in ran.append(command); return CommandResult(code: 0, stdout: "ok") }
        let a = stream(command: #"echo '{"name":"a.pdf"}'; sleep 30"#, action: .init(type: "shell", command: "echo {{item.name}} {{count}}")) { $0.mode = "json" }
        try? rig.store.replace([a])
        await until("the shell action") { ran.count == 1 }
        XCTAssertEqual(ran, ["echo 'a.pdf' 1"])
        XCTAssertTrue(rig.engine.state.history("s").contains { $0.outcome == "ok" })
    }

    func testAnEventBubbleUsesTheCountAndLastEvent() async {
        let a = stream(command: #"for i in 1 2 3; do echo "{\"n\":$i}"; done; sleep 30"#,
                       action: .init(type: "bubble", title: "{{count}} files, last {{item.n}}")) { $0.mode = "json"; $0.debounceSeconds = 0.3 }
        let rig = rig([a])
        await until("the bubble") { rig.notices.all.contains { $0.title == "3 files, last 3" } }
    }

    // S7
    func testValidationNamesTheBadField() async {
        let rig = rig([])
        func create(_ trigger: [String: Any]) async -> String {
            let result = await rig.service.call("create", ["name": "T", "trigger": trigger, "action": ["type": "bubble", "title": "x"]], by: "user")
            if case .failure(let error) = result { return error.message }
            return ""
        }
        let missing = await create(["type": "stream"])
        XCTAssertTrue(missing.contains("trigger.command is required"), missing)
        let empty = await create(["type": "stream", "command": "  "])
        XCTAssertTrue(empty.contains("trigger.command is empty"), empty)
        let mode = await create(["type": "stream", "command": "x", "mode": "text"])
        XCTAssertTrue(mode.contains("trigger.mode must be one of lines, json"), mode)
        let debounce = await create(["type": "stream", "command": "x", "debounceSeconds": -1])
        XCTAssertTrue(debounce.contains("trigger.debounceSeconds cannot be negative"), debounce)
        let throttle = await create(["type": "stream", "command": "x", "throttleSeconds": -2])
        XCTAssertTrue(throttle.contains("trigger.throttleSeconds cannot be negative"), throttle)
        let when = await create(["type": "stream", "command": "x", "mode": "json", "when": "[?"])
        XCTAssertTrue(when.contains("trigger.when is not valid JMESPath"), when)
        let id = await create(["type": "stream", "command": "x", "id": "n"])
        XCTAssertTrue(id.contains("trigger.id needs \"mode\": \"json\""), id)
        let source = await create(["type": "stream", "command": "x", "source": ["type": "shell", "command": "y"]])
        XCTAssertTrue(source.contains("trigger.source does not apply to stream"), source)
        let elsewhere = await create(["type": "interval", "minutes": 5, "command": "x"])
        XCTAssertTrue(elsewhere.contains("trigger.command only applies to stream triggers"), elsewhere)
        let secret = await create(["type": "stream", "command": "curl -H 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123' x"])
        XCTAssertTrue(secret.contains("secret"), secret)
        let digest = await rig.service.call("create", ["name": "D", "trigger": ["type": "stream", "command": "x"], "action": ["type": "digest", "digest": "brief"]], by: "user")
        if case .success = digest { XCTFail("a digest action is not for streams") }
    }

    func testTheFswatchExampleIsAccepted() async throws {
        let rig = rig([])
        let example: [String: Any] = [
            "name": "New PDFs in Downloads",
            "trigger": ["type": "stream", "command": "fswatch --event Created ~/Downloads | grep --line-buffered '[.]pdf$'",
                        "mode": "lines", "debounceSeconds": 2],
            "action": ["type": "bubble", "title": "{{count}} new PDF(s)", "body": "{{item.line}}"],
        ]
        let result = await rig.service.call("create", example, by: "agent:mcp")
        if case .failure(let error) = result { XCTFail(error.message) }
        XCTAssertEqual(rig.store.automations.first?.trigger.type, "stream")
        XCTAssertEqual(rig.engine.streams.runningCount, 0, "waits for approval")
    }

    func testAStreamRoundTripsThroughTheFile() throws {
        let a = stream(command: "tail -f log", createdBy: "agent:mcp") { $0.mode = "json"; $0.when = "level=='error'"; $0.debounceSeconds = 2; $0.throttleSeconds = 10 }
        let data = try JSONEncoder().encode(AutomationFile(automations: [a]))
        let (parsed, errors) = AutomationValidator.parse(data)
        XCTAssertEqual(errors, [])
        XCTAssertEqual(parsed, [a])
    }

    func testAFileFromBeforeStillLoadsUnchanged() {
        let json = #"{"automations":[{"id":"p","name":"P","trigger":{"type":"poll","minutes":5,"source":{"type":"shell","command":"echo []"},"id":"id"},"action":{"type":"bubble","title":"x"}},{"id":"i","name":"I","trigger":{"type":"interval","minutes":45},"action":{"type":"bubble","title":"y"}}]}"#
        let (parsed, errors) = AutomationValidator.parse(Data(json.utf8))
        XCTAssertEqual(errors, [])
        XCTAssertEqual(parsed.count, 2)
        XCTAssertNil(parsed[0].trigger.command)
        let encoded = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(parsed[0].trigger))) as? [String: Any] ?? [:]
        XCTAssertEqual(Set(encoded.keys), ["type", "minutes", "source", "id"], "no stream keys appear in an old trigger")
    }
}
