import Foundation

extension JMES {
    /// JMESPath truthiness: false, null, an empty string, list or object are false. Everything else, including 0, is true.
    static func truthy(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull: return false
        case let n as NSNumber:
            // JSONSerialization numbers bridge to Bool for 0 and 1, so check for a real boolean first.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            return true
        case let b as Bool: return b
        case let s as String: return !s.isEmpty
        case let l as [Any]: return !l.isEmpty
        case let d as [String: Any]: return !d.isEmpty
        default: return true
        }
    }
}

/// Runs the `stream` triggers: one long-running shell command per automation, whose output lines become events.
///
/// A line goes through the parser (the poll extractor, one line at a time), the `when` filter, the rate limit, the seen set
/// and an `EventCoalescer` (debounce, throttle, one action at a time). The engine starts the command when the automation is
/// enabled and approved, stops it when that stops being true or the definition changes, and restarts it with a growing delay
/// when it exits. It never runs two copies of the same automation.
@MainActor
final class StreamEngine {
    enum Status: String { case running, restarting, stopped }

    struct Limits {
        var minBackoff: TimeInterval = 1
        var maxBackoff: TimeInterval = 300
        /// A run at least this long resets the backoff.
        var healthyRun: TimeInterval = 60
        /// SIGTERM, then SIGKILL after this long.
        var grace: TimeInterval = 2
        var maxLine = 64 * 1024
        var maxEventsPerSecond = 20
        /// How often dropped events and stderr are summarised in the log.
        var summaryInterval: TimeInterval = 1
        var maxSeen = 5000
    }

    var limits = Limits()
    var now: () -> Date = { Date() }
    var environment: () -> [String: String] = { CommandRunner.defaultEnvironment() }
    /// Runs the action for one event. `done` must be called when the action has finished.
    var fire: (_ automation: Automation, _ item: [String: Any], _ count: Int, _ done: @escaping () -> Void) -> Void = { _, _, _, done in done() }
    /// A line for the history: automation id, outcome, text.
    var onRecord: (_ id: String, _ outcome: String, _ text: String) -> Void = { _, _, _ in }
    /// A line for the execution log: id, outcome, summary, detail, seconds taken.
    var onLog: (_ id: String, _ outcome: String, _ summary: String, _ detail: String, _ duration: TimeInterval) -> Void = { _, _, _, _, _ in }
    var loadSeen: (_ id: String) -> SeenSet? = { _ in nil }
    var saveSeen: (_ id: String, _ set: SeenSet) -> Void = { _, _ in }

    private final class Slot {
        let id: String
        /// The definition the running process was started for.
        var running: Automation
        /// What should run now. Nil means stop.
        var desired: Automation?
        var process: StreamProcess?
        var startedAt: Date?
        var backoff: TimeInterval
        var restart: DispatchWorkItem?
        var stopping = false
        var lastEvent: Date?
        var lastFired: Date?
        var seen = SeenSet(baselined: true)
        var seenDirty = false
        var lastSeenSave = Date.distantPast
        var windowStart = Date.distantPast
        var windowCount = 0
        var drops: [String: Int] = [:]
        var stderr: [String] = []
        var summary: DispatchWorkItem?
        let coalescer: EventCoalescer
        /// Bumped on every start, so output of an old process is ignored.
        var generation = 0

        init(id: String, automation: Automation, backoff: TimeInterval, coalescer: EventCoalescer) {
            self.id = id
            self.running = automation
            self.backoff = backoff
            self.coalescer = coalescer
        }
    }

    private var slots: [String: Slot] = [:]
    /// Nothing starts until this is true, so the approval check can be wired first.
    var enabled = false

    // MARK: Control

    /// Makes the running commands match `list`: starts the enabled and approved ones, stops the others, and restarts the ones
    /// whose definition changed (after the old one has exited).
    func sync(_ list: [Automation], mayRun: (Automation) -> Bool) {
        let wanted = enabled
            ? Dictionary(uniqueKeysWithValues: list.filter { $0.trigger.type == "stream" && $0.enabled && mayRun($0) }.map { ($0.id, $0) })
            : [:]
        for slot in Array(slots.values) where wanted[slot.id] == nil {
            slot.desired = nil
            reconcile(slot)
        }
        for (id, automation) in wanted {
            let slot = slots[id] ?? makeSlot(automation)
            if slot.desired != automation {
                if !Self.sameExtraction(slot.running.trigger, automation.trigger) { slot.seen = SeenSet(baselined: true); slot.seenDirty = false }
                slot.desired = automation
                slot.coalescer.debounce = automation.trigger.debounceSeconds ?? 0
                slot.coalescer.throttle = automation.trigger.throttleSeconds ?? 0
            }
            reconcile(slot)
        }
    }

    func status(_ id: String) -> Status {
        guard let slot = slots[id] else { return .stopped }
        if slot.process != nil { return .running }
        return slot.desired != nil ? .restarting : .stopped
    }

    func lastEvent(_ id: String) -> Date? { slots[id]?.lastEvent }

    /// The pid of the running command, for tests.
    func pid(_ id: String) -> pid_t? { slots[id]?.process?.pid }

    /// Number of commands running now, for tests.
    var runningCount: Int { slots.values.filter { $0.process != nil }.count }

    /// Stops every command and waits (up to `timeout`) for them to go. For app quit and for tests: it must not hang on a
    /// command that ignores SIGTERM, so it sends SIGKILL when the time is up.
    func shutdown(timeout: TimeInterval = 2) {
        enabled = false
        let processes = slots.values.compactMap(\.process)
        for process in processes { process.terminate() }
        for slot in slots.values {
            slot.desired = nil
            slot.restart?.cancel()
            slot.restart = nil
            slot.coalescer.reset()
            slot.summary?.cancel()
            flushSeen(slot, force: true)
        }
        let deadline = Date().addingTimeInterval(timeout)
        for process in processes { process.waitForGroup(until: deadline) }
    }

    // MARK: Lifecycle

    private func makeSlot(_ automation: Automation) -> Slot {
        let coalescer = EventCoalescer(debounce: automation.trigger.debounceSeconds ?? 0,
                                       throttle: automation.trigger.throttleSeconds ?? 0, now: { [unowned self] in now() })
        let slot = Slot(id: automation.id, automation: automation, backoff: limits.minBackoff, coalescer: coalescer)
        slot.seen = loadSeen(automation.id) ?? SeenSet()
        slot.seen.baselined = true
        slot.lastFired = slot.seen.lastFired
        coalescer.fire = { [weak self, weak slot] event, count, done in
            guard let self, let slot else { return done() }
            slot.lastFired = self.now()
            self.fire(slot.running, event, count, done)
        }
        slots[automation.id] = slot
        return slot
    }

    /// Takes the next step toward `desired`: stop a command that should not run, wait for it to exit, then start.
    private func reconcile(_ slot: Slot) {
        if let process = slot.process {
            if slot.desired != slot.running || slot.desired == nil, !slot.stopping {
                slot.stopping = true
                slot.coalescer.reset()
                onLog(slot.id, "ok", "stopping", slot.desired == nil ? "stopped: turned off, deleted or not approved" : "stopped: the definition changed", 0)
                process.terminate()
            }
            return
        }
        guard let desired = slot.desired else {
            slot.restart?.cancel()
            slot.restart = nil
            flushSeen(slot, force: true)
            slots[slot.id] = nil
            return
        }
        if slot.restart != nil {
            // Waiting for backoff. A changed definition starts straight away.
            guard slot.running != desired else { return }
            slot.restart?.cancel()
            slot.restart = nil
            slot.backoff = limits.minBackoff
        }
        start(slot, desired)
    }

    private func start(_ slot: Slot, _ automation: Automation) {
        slot.running = automation
        slot.generation += 1
        let generation = slot.generation
        slot.stopping = false
        let id = slot.id
        do {
            let process = try StreamProcess(
                command: automation.trigger.command ?? "", environment: environment(), maxLine: limits.maxLine, grace: limits.grace,
                onLine: { [weak self, weak slot] line in
                    guard let self, let slot, slot.generation == generation else { return }
                    handle(line: line, slot)
                },
                onStderr: { [weak self, weak slot] line in
                    guard let self, let slot, slot.generation == generation else { return }
                    noteStderr(line, slot)
                },
                onLong: { [weak self, weak slot] in
                    guard let self, let slot, slot.generation == generation else { return }
                    drop("line over \(limits.maxLine) bytes", slot)
                },
                onExit: { [weak self, weak slot] exit in
                    guard let self, let slot, slot.generation == generation else { return }
                    exited(slot, exit)
                })
            slot.process = process
            slot.startedAt = now()
            onRecord(id, "ok", "stream started")
            onLog(id, "ok", "started (pid \(process.pid))", "command: \(automation.trigger.command ?? "")", 0)
        } catch {
            slot.process = nil
            onRecord(id, "failed", error.localizedDescription)
            onLog(id, "failed", error.localizedDescription, error.localizedDescription, 0)
            scheduleRestart(slot, ranFor: 0, reason: error.localizedDescription)
        }
    }

    private func exited(_ slot: Slot, _ exit: StreamProcess.Exit) {
        let ranFor = slot.startedAt.map { now().timeIntervalSince($0) } ?? 0
        slot.process = nil
        slot.startedAt = nil
        flushSummary(slot)
        flushSeen(slot, force: true)
        let wasStopping = slot.stopping
        slot.stopping = false
        let text = "exited with \(exit.summary) after \(Self.seconds(ranFor))"
        if wasStopping || slot.desired == nil {
            onRecord(slot.id, "ok", "stream stopped (\(exit.summary))")
            onLog(slot.id, "ok", "stopped", text, ranFor)
        } else {
            onRecord(slot.id, exit.clean ? "ok" : "failed", "stream " + text)
            onLog(slot.id, exit.clean ? "ok" : "failed", text, text, ranFor)
        }
        if wasStopping || slot.desired != slot.running {
            reconcile(slot)
        } else {
            scheduleRestart(slot, ranFor: ranFor, reason: exit.summary)
        }
    }

    private func scheduleRestart(_ slot: Slot, ranFor: TimeInterval, reason: String) {
        if ranFor >= limits.healthyRun { slot.backoff = limits.minBackoff }
        let delay = slot.backoff
        slot.backoff = min(slot.backoff * 2, limits.maxBackoff)
        onRecord(slot.id, "skipped", "restarting in \(Self.seconds(delay)) (\(reason))")
        onLog(slot.id, "skipped", "restarting in \(Self.seconds(delay))", "reason: \(reason)", 0)
        let item = DispatchWorkItem { [weak self, weak slot] in
            MainActor.assumeIsolated {
                guard let self, let slot else { return }
                slot.restart = nil
                self.reconcile(slot)
            }
        }
        slot.restart = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: Events

    private func handle(line: String, _ slot: Slot) {
        // Lines a dying command prints after a stop was asked for must not fire the action.
        guard !slot.stopping, slot.desired != nil else { return }
        let automation = slot.running
        let trigger = automation.trigger
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        var parse = trigger
        parse.mode = trigger.mode ?? "lines"
        let items: [PollItem]
        do { items = try PollExtractor.items(from: CommandResult(code: 0, stdout: text), trigger: parse) } catch {
            return drop("not valid: \(error.localizedDescription)", slot)
        }
        for item in items {
            if let when = trigger.when, !when.isEmpty {
                do { if !JMES.truthy(try JMES.search(when, in: item.value)) { continue } } catch {
                    drop("when failed: \(error.localizedDescription)", slot)
                    continue
                }
            }
            let current = now()
            if current.timeIntervalSince(slot.windowStart) >= 1 { slot.windowStart = current; slot.windowCount = 0 }
            slot.windowCount += 1
            guard slot.windowCount <= limits.maxEventsPerSecond else { drop("over \(limits.maxEventsPerSecond) events a second", slot); continue }
            if trigger.id != nil {
                let known = slot.seen.entries[item.id]
                slot.seen.entries[item.id] = .init(version: item.version, lastSeen: current)
                slot.seenDirty = true
                if let known, known.version == item.version { continue }
                trimSeen(slot)
            }
            if let cooldown = trigger.cooldownMinutes, cooldown > 0, let last = slot.lastFired, current.timeIntervalSince(last) < cooldown * 60 {
                drop("cooldown", slot)
                continue
            }
            slot.lastEvent = current
            slot.coalescer.submit(item.value)
        }
        flushSeen(slot, force: false)
    }

    private func trimSeen(_ slot: Slot) {
        guard slot.seen.entries.count > limits.maxSeen else { return }
        let keep = slot.seen.entries.sorted { $0.value.lastSeen > $1.value.lastSeen }.prefix(limits.maxSeen * 9 / 10)
        slot.seen.entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private func flushSeen(_ slot: Slot, force: Bool) {
        guard slot.seenDirty, force || now().timeIntervalSince(slot.lastSeenSave) >= 30 else { return }
        slot.seenDirty = false
        slot.lastSeenSave = now()
        var set = slot.seen
        set.lastFired = slot.lastFired
        set.entries = set.entries.filter { now().timeIntervalSince($0.value.lastSeen) < AutomationState.seenRetention }
        saveSeen(slot.id, set)
    }

    // MARK: Log summaries

    private func drop(_ reason: String, _ slot: Slot) {
        slot.drops[reason, default: 0] += 1
        scheduleSummary(slot)
    }

    private func noteStderr(_ line: String, _ slot: Slot) {
        guard slot.stderr.count < 50 else { return }
        slot.stderr.append(String(line.prefix(500)))
        scheduleSummary(slot)
    }

    private func scheduleSummary(_ slot: Slot) {
        guard slot.summary == nil else { return }
        let item = DispatchWorkItem { [weak self, weak slot] in
            MainActor.assumeIsolated {
                guard let self, let slot else { return }
                slot.summary = nil
                self.flushSummary(slot)
            }
        }
        slot.summary = item
        DispatchQueue.main.asyncAfter(deadline: .now() + limits.summaryInterval, execute: item)
    }

    /// One history line and one log line for what was dropped, and one log line for stderr, instead of one per event.
    private func flushSummary(_ slot: Slot) {
        slot.summary?.cancel()
        slot.summary = nil
        if !slot.drops.isEmpty {
            let total = slot.drops.values.reduce(0, +)
            let detail = slot.drops.sorted { $0.key < $1.key }.map { "\($0.value) dropped: \($0.key)" }.joined(separator: "\n")
            slot.drops = [:]
            onRecord(slot.id, "skipped", "\(total) event\(total == 1 ? "" : "s") dropped")
            onLog(slot.id, "skipped", "\(total) event\(total == 1 ? "" : "s") dropped", detail, 0)
        }
        if !slot.stderr.isEmpty {
            let lines = slot.stderr
            slot.stderr = []
            onLog(slot.id, "ok", "stderr: \(lines[0].prefix(120))", "stderr:\n" + lines.joined(separator: "\n"), 0)
        }
    }

    /// What decides which events fire. A change makes the seen set start over.
    static func sameExtraction(_ a: Automation.Trigger, _ b: Automation.Trigger) -> Bool {
        a.command == b.command && a.mode == b.mode && a.items == b.items && a.id == b.id && a.version == b.version
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value < 10 ? String(format: "%.2g s", value) : "\(Int(value.rounded())) s"
    }
}
