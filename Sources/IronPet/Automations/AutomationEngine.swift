import CoreGraphics
import Foundation

/// Decides when each automation is due. It knows nothing about bubbles, agents or shells: it calls `onFire`, and the
/// caller runs the action. Time and idle state come in through `Environment`, so tests drive it with a fake clock.
///
/// `interval` automations on the `active` clock keep the reminder feel: time counts only while the user is at the
/// keyboard, a break of `idleResetMinutes` resets them, they may go out up to a quarter early while an agent works,
/// those close to due go out together, and nothing goes out while the user is busy with Ghost.
@MainActor
final class AutomationEngine {
    struct Environment {
        var now: () -> Date = { Date() }
        /// Seconds since the last keyboard or mouse event.
        var idleSeconds: () -> TimeInterval = {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        }
        /// An agent or a Ghost chat is running, a good moment to step away.
        var isAgentWorking: () -> Bool = { false }
        /// The user is mid-conversation with Ghost or an agent is waiting on them.
        var isBusy: () -> Bool = { false }
        var calendar: Calendar = .autoupdatingCurrent
    }

    struct Timing {
        var paused = false
        var idleResetMinutes: Double = 5
        var snoozeMinutes: Double = 10
    }

    /// One delivery. `batch` holds several automations when active reminders go out together.
    struct Fire {
        var automations: [Automation]
        var item: [String: Any]?
        var agentWorking: Bool
        /// The `daily` slot this delivery is for, when it has one.
        var slot: Date? = nil
        /// Run now from Settings, MCP or the CLI rather than the schedule.
        var manual = false
    }

    var env: Environment
    var timing: () -> Timing = { Timing() }
    var onFire: (Fire) -> Void = { _ in }
    /// A history line: automation id, outcome, text.
    var onRecord: (_ id: String, _ outcome: String, _ output: String) -> Void = { _, _, _ in }
    /// One line in the execution log for every poll or script run, quiet ones too: id, outcome, summary, detail, seconds taken.
    var onLog: (_ id: String, _ outcome: String, _ summary: String, _ detail: String, _ duration: TimeInterval) -> Void = { _, _, _, _, _ in }
    /// False while a poll command waits for the user's approval. Nothing runs until it is true.
    var mayRun: (Automation) -> Bool = { _ in true }
    /// What a script asked for. `firstRun` is true when the script had no saved state, so an alert can be recorded quietly.
    var onActions: (_ automation: Automation, _ actions: [[String: Any]], _ firstRun: Bool) -> Void = { _, _, _ in }
    /// Runs a script automation. Replaced in tests to avoid shell and network.
    var runScript: (_ script: String, _ state: String?) async throws -> AutomationScript.Output = { script, state in
        try await AutomationScript.run(script: script, state: state)
    }
    /// Runs a poll command. Replaced in tests.
    var runPoll: (Automation) async -> CommandResult = AutomationEngine.defaultRunPoll
    var state = AutomationState()

    private(set) var automations: [Automation] = []
    private var activeElapsed: [String: TimeInterval] = [:]
    private var wallLast: [String: Date] = [:]
    private var nextPollAt: [String: Date] = [:]
    private var onceFired: Set<String> = []
    private var polling: [String: Task<Void, Never>] = [:]
    private var lastTick: Date

    init(env: Environment = Environment()) {
        self.env = env
        lastTick = env.now()
    }

    // MARK: Configuration

    /// Replaces the list. Automations whose trigger did not change keep their timers.
    func set(_ list: [Automation]) {
        let old = Dictionary(uniqueKeysWithValues: automations.map { ($0.id, $0) })
        let now = env.now()
        for a in list {
            let before = old[a.id]
            if before?.trigger != a.trigger || before?.enabled != a.enabled {
                activeElapsed[a.id] = 0
                wallLast[a.id] = now
                nextPollAt[a.id] = nil
                if before?.trigger.at != a.trigger.at { onceFired.remove(a.id) }
            }
            if let before, !Self.sameExtraction(before.trigger, a.trigger) { state.forgetSeen(a.id); polling[a.id]?.cancel(); polling[a.id] = nil }
            // Turning a catch-up automation on, or changing its times, must not fire a slot that passed before that.
            // At launch (no `before`) the stored slot stands, so a slot missed while ironpet was not running catches up.
            if a.trigger.type == "daily", a.trigger.catchUpMinutes != nil,
               before.map({ $0.trigger != a.trigger || $0.enabled != a.enabled }) ?? (state.dailySlot(a.id) == nil),
               let latest = latestSlot(a, atOrBefore: now) {
                state.setDailySlot(a.id, latest)
            }
        }
        for gone in old.values where !list.contains(where: { $0.id == gone.id }) {
            activeElapsed[gone.id] = nil
            wallLast[gone.id] = nil
            nextPollAt[gone.id] = nil
            state.forget(gone.id)
            polling[gone.id]?.cancel()
            polling[gone.id] = nil
        }
        automations = list
    }

    /// What decides which items a poll sees. A change here makes every old item look new, so the seen set starts over.
    private static func sameExtraction(_ a: Automation.Trigger, _ b: Automation.Trigger) -> Bool {
        a.source == b.source && a.mode == b.mode && a.items == b.items && a.id == b.id
            && a.version == b.version
    }

    /// Pushes a reminder back so it is due again in the snooze time.
    func snooze(_ ids: [String]) {
        let seconds = timing().snoozeMinutes * 60
        let now = env.now()
        for id in ids {
            guard let a = automations.first(where: { $0.id == id }) else { continue }
            let interval = (a.trigger.minutes ?? 1) * 60
            if a.trigger.clock == "wall" { wallLast[id] = now.addingTimeInterval(seconds - interval) }
            else { activeElapsed[id] = max(0, interval - seconds) }
            state.setSnooze(id, due: now.addingTimeInterval(seconds))
        }
    }

    /// Puts snoozes saved before a restart back, so a snoozed reminder still comes when it was going to.
    func restoreSnoozes() {
        let now = env.now()
        for (id, due) in state.snoozes() {
            guard let a = automations.first(where: { $0.id == id }), a.trigger.type == "interval", due > now else { state.clearSnooze(id); continue }
            let interval = (a.trigger.minutes ?? 1) * 60
            if a.trigger.clock == "wall" { wallLast[id] = due.addingTimeInterval(-interval) }
            else { activeElapsed[id] = max(0, interval - due.timeIntervalSince(now)) }
        }
    }

    /// Starts the clock over, as if the automation had just fired.
    func reset(_ id: String) {
        activeElapsed[id] = 0
        wallLast[id] = env.now()
    }

    // MARK: Ticks

    /// Call about every 30 seconds. Time-based automations fire from here; polls start as tasks.
    func tick() {
        let now = env.now()
        let previous = lastTick
        lastTick = now
        let elapsed = max(0, now.timeIntervalSince(previous))
        let timing = timing()
        let breakReset = timing.idleResetMinutes * 60
        let away = env.idleSeconds() >= breakReset || elapsed >= breakReset
        let working = env.isAgentWorking()
        let enabled = automations.filter(\.enabled)

        if !timing.paused {
            if away {
                for key in activeElapsed.keys { activeElapsed[key] = 0 }
            } else {
                tickActive(enabled.filter(\.trigger.countsKeyboardTime), elapsed: elapsed, working: working)
            }
            for a in enabled {
                switch a.trigger.type {
                case "interval" where a.trigger.clock == "wall":
                    if now.timeIntervalSince(wallLast[a.id] ?? now) >= (a.trigger.minutes ?? 1) * 60 {
                        wallLast[a.id] = now
                        state.clearSnooze(a.id)
                        onFire(Fire(automations: [a], item: nil, agentWorking: working))
                    }
                case "daily" where a.trigger.catchUpMinutes != nil:
                    if let slot = catchUpSlot(a, now: now) {
                        state.setDailySlot(a.id, slot)
                        onFire(Fire(automations: [a], item: nil, agentWorking: working, slot: slot))
                    }
                case "daily":
                    if dailyDue(a, from: previous, to: now) { onFire(Fire(automations: [a], item: nil, agentWorking: working)) }
                case "once":
                    if !onceFired.contains(a.id), let at = a.trigger.at.flatMap(AutomationClock.parse), at <= now {
                        onceFired.insert(a.id)
                        onFire(Fire(automations: [a], item: nil, agentWorking: working))
                    }
                default:
                    break
                }
            }
        }
        for a in enabled where a.trigger.type == "poll" || a.trigger.type == "script" { startPollIfDue(a, now: now) }
    }

    private func tickActive(_ list: [Automation], elapsed: TimeInterval, working: Bool) {
        for a in list { activeElapsed[a.id, default: 0] += elapsed }
        func interval(_ a: Automation) -> TimeInterval { (a.trigger.minutes ?? 1) * 60 }
        let ready = list.filter { activeElapsed[$0.id, default: 0] >= interval($0) * (working ? 0.75 : 1) }
        guard !ready.isEmpty, !env.isBusy() else { return }
        let batch = list.filter { activeElapsed[$0.id, default: 0] >= interval($0) * 0.75 }
        for a in batch {
            activeElapsed[a.id] = 0
            state.clearSnooze(a.id)
        }
        onFire(Fire(automations: batch, item: nil, agentWorking: working))
    }

    private static let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// `hour:minute` on the wall clock of `day`, so 09:00 stays 09:00 on a day the clocks change. A time the clocks skip
    /// (02:30 when they go forward at 02:00) is the end of the gap, 03:00 (Calendar's `.nextTime`); a time that happens
    /// twice when they go back is the first one.
    func slot(on day: Date, hour: Int, minute: Int) -> Date? {
        env.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    /// The automation's slots on the day `offset` days from `date`'s, none when that weekday is not one of its days.
    private func slots(_ a: Automation, dayOffset offset: Int, from date: Date) -> [Date] {
        let calendar = env.calendar
        guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)),
              (a.trigger.weekdays ?? Self.weekdayNames).contains(Self.weekdayNames[calendar.component(.weekday, from: day) - 1])
        else { return [] }
        return (a.trigger.times ?? []).compactMap(AutomationClock.minutes(of:)).compactMap { slot(on: day, hour: $0 / 60, minute: $0 % 60) }
    }

    private func dailyDue(_ a: Automation, from previous: Date, to now: Date) -> Bool {
        let calendar = env.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: previous), to: calendar.startOfDay(for: now)).day ?? 0
        return (0...max(0, days)).contains { offset in slots(a, dayOffset: offset, from: previous).contains { $0 > previous && $0 <= now } }
    }

    /// The latest slot at or before `now` on an allowed weekday, looking back a week.
    func latestSlot(_ a: Automation, atOrBefore now: Date) -> Date? {
        for offset in 0...7 {
            if let best = slots(a, dayOffset: -offset, from: now).filter({ $0 <= now }).max() { return best }
        }
        return nil
    }

    /// The latest slot that has not fired yet, if it is no more than `catchUpMinutes` late. Older missed slots are dropped.
    /// At least 90 s, three ticks, so a slot on time always fires and `catchUpMinutes: 0` means no catch-up beyond that.
    private func catchUpSlot(_ a: Automation, now: Date) -> Date? {
        guard let latest = latestSlot(a, atOrBefore: now) else { return nil }
        if let last = state.dailySlot(a.id), latest <= last { return nil }
        return now.timeIntervalSince(latest) <= max((a.trigger.catchUpMinutes ?? 0) * 60, 90) ? latest : nil
    }

    /// When the automation is next due, for the settings list. Active reminders count keyboard time, so theirs is an estimate.
    func nextRun(_ a: Automation) -> Date? {
        guard a.enabled else { return nil }
        let now = env.now()
        switch a.trigger.type {
        case "interval":
            let seconds = (a.trigger.minutes ?? 1) * 60
            if a.trigger.clock == "wall" { return (wallLast[a.id] ?? now).addingTimeInterval(seconds) }
            return now.addingTimeInterval(max(0, seconds - activeElapsed[a.id, default: 0]))
        case "daily":
            for offset in 0...7 {
                if let best = slots(a, dayOffset: offset, from: now).filter({ $0 > now }).min() { return best }
            }
            return nil
        case "once":
            return onceFired.contains(a.id) ? nil : a.trigger.at.flatMap(AutomationClock.parse)
        default:
            return nextPollAt[a.id] ?? now
        }
    }

    /// Runs one poll now, whether or not it is due. Resolves when the run has finished.
    func pollNow(_ id: String) async {
        guard let a = automations.first(where: { $0.id == id && ($0.trigger.type == "poll" || $0.trigger.type == "script") }) else { return }
        await execute(poll: a, now: env.now())
    }

    /// Waits for polls that are running, for tests.
    func settle() async {
        for task in Array(polling.values) { await task.value }
    }

    // MARK: Polls

    private func startPollIfDue(_ a: Automation, now: Date) {
        guard polling[a.id] == nil, nextPollAt[a.id].map({ $0 <= now }) ?? true else { return }
        nextPollAt[a.id] = now.addingTimeInterval((a.trigger.minutes ?? 2) * 60)
        polling[a.id] = Task { [weak self] in
            await self?.execute(poll: a, now: now)
            self?.polling[a.id] = nil
        }
    }

    private func execute(script a: Automation) async {
        guard mayRun(a) else { return }
        let started = Date()
        let previous = state.scriptState(a.id)
        do {
            let output = try await runScript(a.trigger.script ?? "", previous)
            // A run that returned nothing before there was any state keeps the next run a first run.
            if !(previous == nil && output.state == "null") { state.setScriptState(a.id, output.state) }
            onActions(a, output.actions.map { $0.mapValues(\.value) }, previous == nil)
            let note = output.logs.isEmpty ? "" : ": " + output.logs.joined(separator: " | ")
            if !output.actions.isEmpty || !output.logs.isEmpty {
                onRecord(a.id, "ok", "\(output.actions.count) action\(output.actions.count == 1 ? "" : "s")" + note)
            }
            var detail: [String] = []
            if previous == nil { detail.append("first run, no saved state") }
            if !output.logs.isEmpty { detail.append("console.log:\n" + output.logs.map { "  " + $0 }.joined(separator: "\n")) }
            for action in output.actions {
                let type = action["type"]?.value as? String ?? "?"
                let label = [action["id"], action["title"], action["prompt"]].compactMap { $0?.value as? String }.joined(separator: " · ")
                detail.append("action \(type): \(label)" + (action["resolved"]?.value as? Bool == true ? " (resolved)" : ""))
            }
            detail.append("state: \(output.state.utf8.count) bytes")
            onLog(a.id, "ok", output.actions.isEmpty ? "no actions" : "\(output.actions.count) action\(output.actions.count == 1 ? "" : "s")",
                  detail.joined(separator: "\n"), Date().timeIntervalSince(started))
        } catch {
            onRecord(a.id, "failed", error.localizedDescription)
            onLog(a.id, "failed", error.localizedDescription, error.localizedDescription, Date().timeIntervalSince(started))
        }
    }

    private func execute(poll a: Automation, now: Date) async {
        if a.trigger.type == "script" { return await execute(script: a) }
        guard mayRun(a) else { return }
        let started = Date()
        func log(_ outcome: String, _ summary: String, _ detail: String = "") {
            onLog(a.id, outcome, summary, detail, Date().timeIntervalSince(started))
        }
        let result = await runPoll(a)
        let mode = a.trigger.mode ?? "json"
        if result.spawnError != nil || result.timedOut || (mode != "exit_code" && result.code != 0) {
            onRecord(a.id, "failed", result.summary)
            log("failed", result.summary, Self.describe(result))
            return
        }
        let items: [PollItem]
        do { items = try PollExtractor.items(from: result, trigger: a.trigger) } catch {
            onRecord(a.id, "failed", error.localizedDescription)
            log("failed", error.localizedDescription, error.localizedDescription + "\n" + Self.describe(result))
            return
        }
        var seen = state.seen(a.id) ?? SeenSet()
        let wasBaselined = seen.baselined
        var fresh = seen.apply(items, now: now)
        var outcome = "ok"
        var summary = fresh.isEmpty ? "no new items (\(items.count) seen)" : "\(fresh.count) new item\(fresh.count == 1 ? "" : "s")"
        if !wasBaselined {
            onRecord(a.id, "baseline", "\(items.count) existing item\(items.count == 1 ? "" : "s") recorded, nothing fired")
            outcome = "baseline"
            summary = "baseline: \(items.count) existing item\(items.count == 1 ? "" : "s") recorded, nothing fired"
        } else if !fresh.isEmpty, let cooldown = a.trigger.cooldownMinutes, cooldown > 0,
                  let last = seen.lastFired, now.timeIntervalSince(last) < cooldown * 60 {
            onRecord(a.id, "skipped", "cooldown: \(fresh.count) new item\(fresh.count == 1 ? "" : "s") dropped")
            outcome = "skipped"
            summary = "cooldown: \(fresh.count) new item\(fresh.count == 1 ? "" : "s") dropped"
            fresh = []
        }
        if !fresh.isEmpty { seen.lastFired = now }
        state.setSeen(a.id, seen)
        let working = env.isAgentWorking()
        for item in fresh.prefix(10) { onFire(Fire(automations: [a], item: item.value, agentWorking: working)) }
        if fresh.count > 10 { onRecord(a.id, "skipped", "\(fresh.count - 10) more new items were not shown") }
        let ids = (fresh.isEmpty ? items : fresh).prefix(30).map { "  " + $0.id }.joined(separator: "\n")
        log(outcome, summary, (fresh.isEmpty ? "items:" : "new items:") + "\n" + ids + "\n" + Self.describe(result))
    }

    /// Exit code and the start of the output, for the log.
    private static func describe(_ result: CommandResult) -> String {
        var lines = ["exit code: \(result.code.map(String.init) ?? "none")" + (result.timedOut ? " (timed out)" : "") + (result.truncated ? " (output cut off)" : "")]
        if let error = result.spawnError { lines.append("error: \(error)") }
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { lines.append("stderr:\n" + String(err.prefix(2000))) }
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { lines.append("stdout:\n" + String(out.prefix(3000))) }
        return lines.joined(separator: "\n")
    }

    /// Runs the source: a shell command or an HTTP GET (through curl, with `${ENV}` headers filled in).
    static func defaultRunPoll(_ a: Automation) async -> CommandResult {
        guard let source = a.trigger.source else { return CommandResult(spawnError: "no source") }
        let timeout = source.timeoutSeconds ?? 30
        let env = CommandRunner.defaultEnvironment()
        switch source.type {
        case "shell":
            return await CommandRunner.run(shell: source.command ?? "", timeout: timeout, environment: env)
        case "http":
            // Headers go in through stdin so a token never shows in the process list.
            var headers = ""
            for (name, value) in (source.headers ?? [:]).sorted(by: { $0.key < $1.key }) {
                let variable = String(value.dropFirst(2).dropLast())
                guard let resolved = env[variable] else { return CommandResult(spawnError: "environment variable \(variable) is not set") }
                headers += "\(name): \(resolved)\n"
            }
            let args = ["-sS", "-L", "--max-time", String(Int(timeout)), "--fail-with-body", "-H", "@-", "--", source.url ?? ""]
            return await CommandRunner.run(executable: "/usr/bin/curl", arguments: args, timeout: timeout + 5, environment: env, stdin: Data(headers.utf8))
        default:
            return CommandResult(spawnError: "unsupported source")
        }
    }
}
