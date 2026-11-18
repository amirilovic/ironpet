import AppKit
import Foundation

/// What an automation shows: one bubble, plus optionally a macOS notification.
struct AutomationNotice {
    enum Tint { case info, good, bad, warn }
    struct Button {
        var title: String
        var primary = false
        var destructive = false
        var run: () -> Void
    }

    var id: String
    var symbol: String
    var tint: Tint = .info
    var title: String
    var subtitle: String?
    var body: String?
    var buttons: [Button] = []
    /// nil stays until answered.
    var expires: TimeInterval?
    var systemNotification = false
    /// The automation this belongs to, so a notification's Done and Snooze can find it.
    var automationIDs: [String] = []
    /// What the bubble's Open button opens, kept so the activity log can offer it later.
    var url: URL?
    /// A break reminder (`Automation.isBreakReminder`), which is not news after a break.
    var isBreakReminder = false
}

struct AutomationError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Glue between the file, the engine and the outside: runs actions, holds approvals and history, and offers the one
/// set of operations that MCP tools, the CLI endpoint and Settings all use. Every write goes through `AutomationValidator`.
@MainActor
final class AutomationService {
    let store: AutomationStore
    let engine: AutomationEngine
    var notice: (AutomationNotice) -> Void = { _ in }
    var dismissNotice: (String) -> Void = { _ in }
    /// Adds or updates an alert in the alerts list. The flag asks for a bubble and a sound.
    var alert: (_ signal: Signal, _ notify: Bool) -> Void = { _, _ in }
    /// Removes an alert from the alerts list.
    var resolveAlert: (_ id: String) -> Void = { _ in }
    var nudge: ([PetMood]) -> Void = { _ in }
    /// Runs a `prompt` action in a background session. Returns the answer or an error text.
    var runPrompt: (_ automation: Automation, _ prompt: String) async -> Result<String, AutomationError> = { _, _ in .failure(.init(message: "no agent")) }
    /// Runs a `prompt` action whose `session` is `new` or `own`, in its own thread with the agent's full tools. Returns the
    /// final reply. Without it (tests), those prompts run in the restricted background session.
    var runSession: ((_ automation: Automation, _ prompt: String) async -> Result<String, AutomationError>)?
    /// Puts a message into the chat the user is looking at, as a queued message that runs with the chat's tools. Returns
    /// false when the chat took nothing. Without it (tests, no chat), a `prompt` action runs in the background.
    var sendToChat: ((_ automationID: String, _ message: String) -> Bool)?
    /// True while a message from this automation is queued or running in the chat.
    var chatRunPending: (_ automationID: String) -> Bool = { _ in false }
    /// True when `~/.ironpet/HEARTBEAT.md` has at least one entry. A `/heartbeat` prompt is skipped without one.
    var checklistHasEntries: () -> Bool = { true }
    /// Builds a `digest` action's brief or recap from data on this Mac. Nil when the stores are not ready. `slot` is the
    /// daily slot being delivered, so a recap caught up after midnight covers the slot's day; nil for Run now.
    var digest: (_ kind: Brief.Kind, _ automation: Automation, _ slot: Date?) -> Brief? = { _, _, _ in nil }
    /// Shows a brief. `manual` is true for Run now, which shows an empty brief too.
    var showDigest: (_ brief: Brief, _ automation: Automation, _ manual: Bool) -> Void = { _, _, _ in }
    var runShell: (_ command: String, _ timeout: TimeInterval) async -> CommandResult = { command, timeout in
        await CommandRunner.run(shell: command, timeout: timeout, environment: CommandRunner.defaultEnvironment())
    }

    private var pending: [String: AutomationEngine.Fire] = [:]
    private var announced: [String: String] = [:]
    private var running: Set<String> = []
    private var invalidShown: String?

    /// `database` is the app's shared one. Without it, the service opens `ironpet.db` next to the definitions file.
    init(store: AutomationStore, engine: AutomationEngine, database: Database? = nil) {
        self.store = store
        self.engine = engine
        engine.state = AutomationState(database: database ?? Database.open(path: store.paths.database, migrations: AppMigrations.all).database)
        engine.set(store.automations)
        engine.onFire = { [weak self] fire in self?.handle(fire) }
        engine.onRecord = { [weak self] id, outcome, text in self?.recordHistory(id, outcome, text) }
        engine.onLog = { [weak self] id, outcome, summary, detail, duration in self?.log(id, outcome, summary, detail: detail, duration: duration) }
        engine.mayRun = { [weak self] a in !(self?.needsApproval(a) ?? false) }
        engine.onActions = { [weak self] automation, actions, firstRun in self?.perform(actions, for: automation, firstRun: firstRun) }
        store.onChange = { [weak self] list in
            guard let self else { return }
            engine.set(list)
            reviewApprovals()
        }
        store.onInvalid = { [weak self] message in
            self?.notice(AutomationNotice(id: "automations-invalid", symbol: "exclamationmark.triangle.fill", tint: .warn,
                                          title: "automations.json has a problem",
                                          body: message + ". The last good list stays active.", expires: 60))
        }
    }

    /// Call once `notice` and the other outputs are set: reports a bad file and asks about automations waiting for approval.
    func start() {
        if let message = store.error { store.onInvalid?(message) }
        engine.restoreSnoozes()
        pruneLogs(force: true)
        engine.state.prune(now: engine.env.now(), keeping: Set(store.automations.map(\.id)))
        reviewApprovals()
        engine.startStreams()
    }

    /// Stops the `stream` commands and their children. Call when the app quits. It waits up to two seconds, then kills.
    func stop() {
        engine.stopStreams()
    }

    /// A run for the history that `automations_history` and the Settings list show: the last 20, short.
    func recordHistory(_ id: String, _ outcome: String, _ text: String) {
        engine.state.record(id, .init(date: engine.env.now(), outcome: outcome, output: String(text.prefix(300))))
    }

    /// A run for the history and the execution log.
    func record(_ id: String, _ outcome: String, _ text: String) {
        recordHistory(id, outcome, text)
        let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        log(id, outcome, first, detail: text, duration: 0)
    }

    /// Whether a failing automation is sent to the agent to fix. Set from the settings.
    var autoFixEnabled: () -> Bool = { false }
    /// Asks the agent to fix an automation: the automation, a short description of when it runs, and the error.
    var requestFix: (_ automation: Automation, _ trigger: String, _ error: String) -> Void = { _, _, _ in }
    /// One request per automation in this many seconds, however often it fails.
    static let fixInterval: TimeInterval = 6 * 3600
    private var failing: Set<String> = []
    private var lastFix: [String: Date] = [:]

    /// A failure asks for a fix once. It asks again only after the automation ran fine in between, and never more than every six hours.
    private func considerFix(_ id: String, _ summary: String, _ detail: String) {
        guard autoFixEnabled(), let a = store.automations.first(where: { $0.id == id }), a.enabled, !needsApproval(a), failing.insert(id).inserted else { return }
        let now = engine.env.now()
        if let last = lastFix[id] ?? Self.storedFix(id), now.timeIntervalSince(last) < Self.fixInterval { return }
        lastFix[id] = now
        Self.storeFix(id, now)
        requestFix(a, describe(a.trigger), detail.isEmpty ? summary : detail)
    }

    private static let fixKey = "automationFixRequested"
    private static func storedFix(_ id: String) -> Date? {
        (UserDefaults.standard.dictionary(forKey: fixKey)?[id] as? Double).map(Date.init(timeIntervalSince1970:))
    }
    private static func storeFix(_ id: String, _ date: Date) {
        var all = UserDefaults.standard.dictionary(forKey: fixKey) ?? [:]
        all[id] = date.timeIntervalSince1970
        UserDefaults.standard.set(all, forKey: fixKey)
    }

    /// How many days of execution logs to keep. Set from the settings.
    var logRetentionDays: () -> Int = { 14 }
    private var lastLogPrune: Date?

    /// Adds a line to the execution log, and deletes lines past the retention at most once an hour.
    func log(_ id: String, _ outcome: String, _ summary: String, detail: String = "", duration: TimeInterval = 0) {
        let now = engine.env.now()
        engine.state.addLog(id, date: now, duration: duration, outcome: outcome, summary: summary, detail: detail)
        pruneLogs(force: false)
        if outcome == "failed" { considerFix(id, summary, detail) } else if ["ok", "baseline", "fired"].contains(outcome) { failing.remove(id) }
    }

    func pruneLogs(force: Bool) {
        let now = engine.env.now()
        if !force, let last = lastLogPrune, now.timeIntervalSince(last) < 3600 { return }
        lastLogPrune = now
        engine.state.pruneLogs(olderThanDays: logRetentionDays(), now: now)
    }

    // MARK: Approval

    func needsApproval(_ a: Automation) -> Bool {
        guard let risk = a.riskText, !a.isByUser else { return false }
        return engine.state.approved(a.id) != AutomationState.hash(risk)
    }

    func isRejected(_ a: Automation) -> Bool {
        guard let risk = a.riskText else { return false }
        return engine.state.rejected(a.id) == AutomationState.hash(risk)
    }

    /// Whether commands, scripts and prompts an agent writes are approved without asking. Set from the settings.
    var autoApproveEnabled: () -> Bool = { false }

    /// Asks about every enabled automation whose command or prompt is new and not the user's own.
    /// With auto-approve on, it approves them instead, through the same `approve` as the Approve button.
    func reviewApprovals() {
        let live = Set(store.automations.map(\.id))
        for id in pending.keys where !live.contains(id) { pending[id] = nil }
        for a in store.automations where a.enabled && needsApproval(a) && !isRejected(a) {
            if autoApproveEnabled() {
                approve(a.id)
                notice(AutomationNotice(id: "automation-auto-approved:\(a.id)", symbol: "checkmark.shield.fill", tint: .info,
                                        title: "Auto-approved \"\(a.name)\"", subtitle: "Created by \(a.createdBy).", expires: 15))
                continue
            }
            let hash = AutomationState.hash(a.riskText ?? "")
            if announced[a.id] != hash { askApproval(a) }
        }
    }

    /// The command, script or prompt the user is asked to allow, without the internal "shell:" style labels.
    /// The approval bubble and Settings show this same text.
    func approvalDetail(_ a: Automation) -> String {
        (a.riskText ?? "").split(separator: "\n").map { line -> String in
            let text = String(line)
            for prefix in ["shell:", "poll:", "prompt:", "http:", "stream:"] where text.hasPrefix(prefix) { return String(text.dropFirst(prefix.count)) }
            return text
        }.joined(separator: "\n")
    }

    private func askApproval(_ a: Automation) {
        announced[a.id] = AutomationState.hash(a.riskText ?? "")
        let detail = approvalDetail(a)
        let kind = a.action.type == "prompt" ? "prompt" : "command"
        notice(AutomationNotice(
            id: Self.approvalID(a.id), symbol: "hand.raised.fill", tint: .warn,
            title: "Allow \"\(a.name)\"?", subtitle: "Created by \(a.createdBy). It wants to run this \(kind).",
            body: detail.count > 1500 ? String(detail.prefix(1500)) + "\n(\(detail.count - 1500) more characters not shown)" : detail,
            buttons: [.init(title: "Approve", primary: true) { [weak self] in self?.approve(a.id) },
                      .init(title: "Reject", destructive: true) { [weak self] in self?.reject(a.id) }]))
    }

    /// The bubble of one poll or script item. An item with an `id` keeps one bubble, so a script can dismiss it later.
    static func itemBubbleID(_ automation: String, item: [String: Any]?, fallback: String) -> String {
        let key = (item?["id"]).map { "\($0)" } ?? fallback
        return "automation:\(automation):" + AutomationState.hash(key).prefix(8)
    }

    static func approvalID(_ id: String) -> String { "automation-approval:\(id)" }

    func approve(_ id: String) {
        guard let a = store.automations.first(where: { $0.id == id }), let risk = a.riskText else { return }
        engine.state.setApproved(id, AutomationState.hash(risk))
        engine.state.setRejected(id, nil)
        dismissNotice(Self.approvalID(id))
        engine.syncStreams()
        if let fire = pending.removeValue(forKey: id) { handle(fire) }
    }

    func reject(_ id: String) {
        guard let a = store.automations.first(where: { $0.id == id }), let risk = a.riskText else { return }
        engine.state.setRejected(id, AutomationState.hash(risk))
        pending[id] = nil
        dismissNotice(Self.approvalID(id))
        try? store.update(id) { $0.enabled = false }
        record(id, "skipped", "rejected by the user, turned off")
    }

    // MARK: Running

    func handle(_ fire: AutomationEngine.Fire) {
        if fire.automations.count > 1 {
            let bubbles = fire.automations.filter { $0.action.type == "bubble" }
            for other in fire.automations where other.action.type != "bubble" { handle(.init(automations: [other], item: nil, agentWorking: fire.agentWorking)) }
            if bubbles.count > 1 { return showBatch(bubbles, agentWorking: fire.agentWorking) }
            if let only = bubbles.first { handle(.init(automations: [only], item: nil, agentWorking: fire.agentWorking)) }
            return
        }
        guard let a = fire.automations.first else { return fire.finished?() ?? () }
        // A stream event waits for its action to finish. Actions that run in the background call `finished` themselves.
        if !handle(a, fire) { fire.finished?() }
    }

    /// Runs one automation's action. Returns true when the action goes on in the background and will call `fire.finished`.
    private func handle(_ a: Automation, _ fire: AutomationEngine.Fire) -> Bool {
        guard !needsApproval(a) else {
            if isRejected(a) { record(a.id, "skipped", "rejected earlier, not run"); return false }
            // A stream event is dropped rather than kept: a stream does not run before it is approved.
            if a.trigger.type != "stream" { pending[a.id] = fire }
            record(a.id, "waiting", "waiting for approval")
            askApproval(a)
            return false
        }
        if a.action.type == "prompt", a.action.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) == AutomationDefaults.heartbeatPrompt,
           !checklistHasEntries() {
            record(a.id, "skipped", "skipped: empty checklist")
            return false
        }
        let values = templateValues(a, item: fire.item, count: fire.count)
        switch a.action.type {
        case "shell":
            let command = AutomationTemplate.render(a.action.command ?? "", values: values.shellSafe)
            return runInBackground(a, done: fire.finished) { [self] in
                let result = await runShell(command, a.action.timeoutSeconds ?? 60)
                finish(a, ok: result.ok, text: result.summary.isEmpty ? (result.ok ? "done" : "failed") : result.summary, fire: fire, truncated: result.truncated)
            }
        case "prompt" where runsInSession(a):
            let prompt = AutomationTemplate.render(a.action.prompt ?? "", values: values)
            return runInBackground(a, done: fire.finished) { [self] in
                switch await runSession?(a, prompt) ?? .failure(.init(message: "no agent")) {
                case .success(let answer):
                    // The reply that means nothing happened: no bubble, but the run and its thread stay recorded.
                    if let quiet = a.action.quiet?.trimmingCharacters(in: .whitespacesAndNewlines), !quiet.isEmpty,
                       answer.trimmingCharacters(in: .whitespacesAndNewlines) == quiet {
                        record(a.id, "ok", "no changes")
                        afterRun(a)
                    } else {
                        finish(a, ok: true, text: answer, fire: fire)
                    }
                case .failure(let error): finish(a, ok: false, text: error.message, fire: fire)
                }
            }
        case "prompt" where runsInChat(a):
            deliverToChat(a, fire: fire, values: values)
        case "digest":
            guard let kind = a.action.digest.flatMap(Brief.Kind.init(rawValue:)), let brief = digest(kind, a, fire.slot) else {
                record(a.id, "failed", "the brief is not available")
                return false
            }
            // A scheduled brief with nothing in it stays quiet; Run now always answers.
            if brief.isEmpty, !fire.manual {
                record(a.id, "ok", "nothing to report")
            } else {
                showDigest(brief, a, fire.manual)
                record(a.id, "fired", brief.lines.isEmpty ? "nothing to report" : brief.lines.joined(separator: "; "))
            }
            afterRun(a)
        case "prompt":
            let prompt = AutomationTemplate.render(a.action.prompt ?? "", values: values)
            return runInBackground(a, done: fire.finished) { [self] in
                switch await runPrompt(a, prompt) {
                case .success(let answer): finish(a, ok: true, text: answer, fire: fire)
                case .failure(let error): finish(a, ok: false, text: error.message, fire: fire)
                }
            }
        default:
            show(a, title: AutomationTemplate.render(a.action.title ?? a.name, values: values),
                 body: AutomationTemplate.render(a.action.body ?? "", values: values), fire: fire, ok: true)
            record(a.id, "fired", AutomationTemplate.render(a.action.title ?? a.name, values: values))
            afterRun(a)
        }
        return false
    }

    /// A prompt without poll item data runs in the user's chat, with the chat's agent, tools and memory. Item text comes
    /// from outside (a web page, an issue title), so a prompt that uses it stays in the restricted background run.
    func runsInChat(_ a: Automation) -> Bool {
        guard sendToChat != nil, a.action.type == "prompt", !runsInSession(a) else { return false }
        return !Self.usesItemData(a.action.prompt ?? "")
    }

    /// A prompt with `session` new or own runs in its own thread with full tools. The same rule as the chat applies: item
    /// text comes from outside, so a prompt that uses it stays in the read-only background run.
    func runsInSession(_ a: Automation) -> Bool {
        runSession != nil && a.action.runsInOwnSession && !Self.usesItemData(a.action.prompt ?? "")
    }

    static func usesItemData(_ prompt: String) -> Bool {
        var rest = Substring(prompt)
        while let open = rest.range(of: "{{") {
            guard let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else { return false }
            let key = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if key == "item" || key.hasPrefix("item.") { return true }
            rest = rest[close.upperBound...]
        }
        return false
    }

    /// The line the chat shows above the prompt, so the user can see where the message came from.
    func chatHeader(_ a: Automation) -> String {
        let when = a.trigger.type == "interval" ? "every \(String(format: "%g", a.trigger.minutes ?? 0)) min" : describe(a.trigger)
        let name = a.name.components(separatedBy: .newlines).joined(separator: " ")
        return "Automation \"\(name)\" (\(when)):"
    }

    private func deliverToChat(_ a: Automation, fire: AutomationEngine.Fire, values: [String: Any]) {
        // One message per automation: a slow turn must not stack up behind its own schedule.
        if chatRunPending(a.id) { return record(a.id, "skipped", "skipped: previous run still in the chat") }
        let message = chatHeader(a) + "\n\n" + AutomationTemplate.render(a.action.prompt ?? "", values: values)
        // Record before sending: the chat reports "running" synchronously, and that row must come after this one.
        record(a.id, "sent", "sent to chat")
        if sendToChat?(a.id, message) != true {
            record(a.id, "failed", "the chat did not take the message")
        }
        afterRun(a)
    }

    /// How a turn that an automation sent ended. The answer stays in the chat, so only the outcome is recorded.
    func chatOutcome(_ id: String, _ event: ChatSession.AutomationEvent) {
        switch event {
        case .started: record(id, "running", "running in the chat")
        case .finished: record(id, "ok", "finished in the chat")
        case .noChange: record(id, "ok", "no changes")
        case .failed(let reason): record(id, "failed", "failed in the chat: \(reason)")
        case .cancelled(let reason): record(id, "skipped", "not finished: \(reason)")
        }
    }

    /// Always returns true: when it skips the run it calls `done` itself.
    @discardableResult
    private func runInBackground(_ a: Automation, key: String? = nil, done: (() -> Void)? = nil, _ work: @escaping () async -> Void) -> Bool {
        // One run at a time per automation: a slow command must not stack up behind its own schedule.
        let key = key ?? a.id
        guard running.insert(key).inserted else {
            record(a.id, "skipped", "the previous run is still going")
            done?()
            return true
        }
        Task { [weak self] in
            await work()
            self?.running.remove(key)
            done?()
        }
        return true
    }

    private func finish(_ a: Automation, ok: Bool, text: String, fire: AutomationEngine.Fire, truncated: Bool = false) {
        record(a.id, ok ? "ok" : "failed", text)
        let values = templateValues(a, item: fire.item, count: fire.count)
        let title = a.action.title.map { AutomationTemplate.render($0, values: values) } ?? (ok ? a.name : "\(a.name) failed")
        let body = ok ? (a.action.body.map { AutomationTemplate.render($0, values: values) + "\n" } ?? "") + text : text
        show(a, title: title, body: String(body.prefix(600)) + (truncated ? "\n(output cut off)" : ""), fire: fire, ok: ok)
        afterRun(a)
    }

    private func afterRun(_ a: Automation) {
        if a.trigger.type == "once" { try? store.update(a.id) { $0.enabled = false } }
    }

    private func templateValues(_ a: Automation, item: [String: Any]?, count: Int? = nil) -> [String: Any] {
        var values: [String: Any] = ["item": item ?? [:], "name": a.name, "now": AutomationClock.format(engine.env.now())]
        if let count { values["count"] = count }
        return values
    }

    private func show(_ a: Automation, title: String, body: String, fire: AutomationEngine.Fire, ok: Bool) {
        let p = a.presentation
        let mood = p.mood.flatMap(PetMood.init(rawValue:)) ?? .listening
        let buttons = p.buttons ?? (a.trigger.type == "interval" ? ["done", "snooze"] : [])
        var list: [AutomationNotice.Button] = []
        if buttons.contains("done") { list.append(.init(title: "Done", primary: true) { [weak self] in self?.nudge([.done]) }) }
        if buttons.contains("snooze") {
            list.append(.init(title: "Snooze \(Int(engine.timing().snoozeMinutes)) min") { [weak self] in self?.engine.snooze([a.id]) })
        }
        // Several new items from one poll must not replace each other's bubble, so a poll item adds a short tag to the id.
        let bubbleID = fire.item == nil ? "automation:\(a.id)" : Self.itemBubbleID(a.id, item: fire.item, fallback: title + "\n" + body)
        notice(AutomationNotice(id: bubbleID, symbol: ok ? (p.symbol ?? "bell.fill") : "exclamationmark.triangle.fill",
                                tint: ok ? .info : .bad, title: title,
                                subtitle: fire.agentWorking && a.trigger.type == "interval" ? "Your agent is still working, good moment for it." : nil,
                                body: body.isEmpty ? nil : body, buttons: list, expires: p.expiresSeconds ?? (a.trigger.type == "interval" ? 180 : 45),
                                systemNotification: p.notification ?? false, automationIDs: [a.id], isBreakReminder: a.isBreakReminder))
        nudge([mood])
    }

    private func showBatch(_ list: [Automation], agentWorking: Bool) {
        let first = list[0]
        let ids = list.map(\.id)
        for a in list { record(a.id, "fired", a.action.title ?? a.name) }
        notice(AutomationNotice(
            id: "automation:batch", symbol: first.presentation.symbol ?? "bell.fill", title: "Time for a short break",
            subtitle: agentWorking ? "Your agent is still working, good moment for it." : nil,
            body: list.map { "\($0.action.title ?? $0.name): \($0.action.body ?? "")" }.joined(separator: "\n"),
            buttons: [.init(title: "Done", primary: true) { [weak self] in self?.nudge([.done]) },
                      .init(title: "Snooze \(Int(engine.timing().snoozeMinutes)) min") { [weak self] in self?.engine.snooze(ids) }],
            expires: 180, systemNotification: list.contains { $0.presentation.notification == true }, automationIDs: ids,
            isBreakReminder: list.allSatisfy(\.isBreakReminder)))
        nudge(list.map { $0.presentation.mood.flatMap(PetMood.init(rawValue:)) ?? .listening })
    }

    /// The Done and Snooze buttons of a macOS notification.
    func notificationAction(ids: [String], snooze: Bool) {
        if snooze { engine.snooze(ids) } else { nudge([.done]) }
    }

    // MARK: Script actions

    private static let severities = ["info", "good", "warn", "bad"]
    static let maxSuggestionsPerRun = 10

    /// Carries out what a script returned, in order. A mistake in one action is recorded and the rest still run.
    func perform(_ actions: [[String: Any]], for a: Automation, firstRun: Bool) {
        var drafts: [TaskSuggestion.Draft] = []
        var dropped = 0
        for (index, action) in actions.enumerated() {
            let problem: String?
            switch action["type"] as? String {
            case "bubble": problem = scriptBubble(action, a)
            case "alert": problem = scriptAlert(action, a, firstRun: firstRun)
            case "prompt": problem = scriptPrompt(action, a)
            case "suggest_task":
                do {
                    let draft = try TaskSuggestion.Draft(action: action)
                    if drafts.count < Self.maxSuggestionsPerRun { drafts.append(draft) } else { dropped += 1 }
                    problem = nil
                } catch {
                    problem = error.localizedDescription
                }
            default: problem = "type must be bubble, alert, prompt or suggest_task"
            }
            if let problem { record(a.id, "failed", "action \(index + 1): \(problem)") }
        }
        if dropped > 0 { record(a.id, "failed", "at most \(Self.maxSuggestionsPerRun) suggest_task actions per run, \(dropped) left out") }
        if !drafts.isEmpty { suggestTasks(drafts, a, firstRun: firstRun) }
    }

    /// Where `suggest_task` actions go: suggestions only, never tasks.
    var tasks: TaskStore?
    /// Offers what one run added, in one bubble.
    var suggested: (_ added: [TaskSuggestion]) -> Void = { _ in }

    /// Watcher text comes from outside, so it only becomes a suggestion the user adds or skips. The first run adds
    /// them quietly, like alerts.
    private func suggestTasks(_ drafts: [TaskSuggestion.Draft], _ a: Automation, firstRun: Bool) {
        guard let tasks else { return record(a.id, "failed", "suggest_task: the task list is not available") }
        let added = tasks.suggest(drafts, automation: a.id, name: a.name)
        if !added.isEmpty && !firstRun { suggested(added) }
    }

    private func text(_ action: [String: Any], _ key: String) -> String? {
        guard let value = action[key], !(value is NSNull) else { return nil }
        let text = (value as? String) ?? "\(value)"
        return text.isEmpty ? nil : text
    }

    private func severity(_ action: [String: Any], default fallback: String) -> String {
        let value = text(action, "severity") ?? fallback
        return Self.severities.contains(value) ? value : fallback
    }

    private func mood(for severity: String) -> PetMood {
        switch severity {
        case "bad": return .failed
        case "good": return .done
        case "warn": return .needsInput
        default: return .listening
        }
    }

    private func scriptBubble(_ action: [String: Any], _ a: Automation) -> String? {
        guard let title = text(action, "title") ?? text(action, "body") else { return "a bubble needs a title or a body" }
        let level = severity(action, default: "info")
        let key = text(action, "id") ?? (title + "\n" + (text(action, "body") ?? ""))
        let url = text(action, "url").flatMap(URL.init(string:))
        var buttons: [AutomationNotice.Button] = []
        if let url { buttons.append(.init(title: "Open", primary: true) { NSWorkspace.shared.open(url) }) }
        let tint: AutomationNotice.Tint = level == "bad" ? .bad : level == "warn" ? .warn : level == "good" ? .good : .info
        notice(AutomationNotice(id: Self.itemBubbleID(a.id, item: ["id": key], fallback: key),
                                symbol: text(action, "symbol") ?? "bell.fill", tint: tint, title: title, subtitle: text(action, "subtitle"),
                                body: text(action, "body") == title ? nil : text(action, "body"), buttons: buttons,
                                expires: (action["expiresSeconds"] as? Double) ?? 45,
                                systemNotification: action["notification"] as? Bool ?? false, automationIDs: [a.id], url: url))
        nudge([mood(for: level)])
        return nil
    }

    /// An alert is an open item in the alerts list. A new or changed one gets a bubble. One listed again unchanged is left
    /// alone, even if the user dismissed it. `resolved: true` removes it.
    private func scriptAlert(_ action: [String: Any], _ a: Automation, firstRun: Bool) -> String? {
        guard let id = text(action, "id") else { return "an alert needs an id" }
        let signalID = "automation:\(a.id):\(id)"
        if action["resolved"] as? Bool == true {
            resolveAlert(signalID)
            engine.state.clearAlert(a.id, id)
            return nil
        }
        guard let title = text(action, "title") else { return "an alert needs a title" }
        let level = severity(action, default: "warn")
        let fingerprint = AutomationState.hash(text(action, "version")
            ?? [title, text(action, "subtitle"), text(action, "label"), level, text(action, "url")].map { $0 ?? "" }.joined(separator: "\u{1}"))
        let known = engine.state.alertHash(a.id, id)
        guard known != fingerprint else { return nil }
        let signal = Signal(id: signalID, title: title, subtitle: text(action, "subtitle") ?? text(action, "body") ?? "",
                            url: text(action, "url").flatMap(URL.init(string:)), label: text(action, "label") ?? a.name,
                            symbol: text(action, "symbol") ?? (level == "good" ? "checkmark.seal.fill" : level == "bad" ? "xmark.octagon.fill" : "bell.badge.fill"),
                            mood: level == "info" ? .done : mood(for: level), ask: text(action, "ask"))
        engine.state.setAlertHash(a.id, id, fingerprint, signal: signal)
        // An empty stored hash is an alert from before payloads were stored, so it comes back without a bubble.
        alert(signal, !firstRun && known != "")
        return nil
    }

    private func scriptPrompt(_ action: [String: Any], _ a: Automation) -> String? {
        guard let prompt = text(action, "prompt") else { return "a prompt needs prompt text" }
        var asking = a
        asking.action = .init(type: "prompt", prompt: prompt, agent: text(action, "agent"), model: text(action, "model"))
        let title = text(action, "title") ?? a.name
        runInBackground(a, key: "\(a.id)#prompt") { [self] in
            switch await runPrompt(asking, prompt) {
            case .success(let answer):
                record(a.id, "ok", answer)
                notice(AutomationNotice(id: "automation:\(a.id):prompt:" + AutomationState.hash(prompt).prefix(8), symbol: text(action, "symbol") ?? "sparkles",
                                        tint: .info, title: title, body: String(answer.prefix(600)), expires: 60, automationIDs: [a.id]))
            case .failure(let error):
                record(a.id, "failed", error.message)
                notice(AutomationNotice(id: "automation:\(a.id):prompt", symbol: "exclamationmark.triangle.fill", tint: .bad, title: "\(title) failed",
                                        body: error.message, expires: 45, automationIDs: [a.id]))
            }
        }
        return nil
    }

    // MARK: Operations

    /// `by` is `user` for Settings and `agent:mcp` or `agent:cli` for the other paths.
    func call(_ op: String, _ args: [String: Any], by: String) async -> Result<Any, AutomationError> {
        do {
            switch op {
            case "list": return .success(store.automations.map(summary))
            case "get": return .success(detail(try find(args)))
            case "create": return .success(detail(try create(args, by: by)))
            case "update": return .success(detail(try update(args, by: by)))
            case "delete":
                let a = try find(args)
                try store.replace(store.automations.filter { $0.id != a.id })
                engine.state.forget(a.id)
                dismissNotice(Self.approvalID(a.id))
                return .success(["deleted": a.id])
            case "pause", "resume":
                let a = try find(args)
                try store.update(a.id) { $0.enabled = op == "resume" }
                return .success(detail(try find(["id": a.id])))
            case "run_now":
                let a = try find(args)
                if a.trigger.type == "poll" || a.trigger.type == "script" {
                    await engine.pollNow(a.id)
                } else {
                    handle(.init(automations: [a], item: nil, agentWorking: false, manual: true, count: a.trigger.type == "stream" ? 1 : nil))
                }
                let waiting = needsApproval(a)
                return .success(["id": a.id, "status": waiting ? "waiting for approval" : "started"])
            case "history":
                let a = try find(args)
                let limit = (args["limit"] as? Int) ?? 20
                return .success(history(a.id, limit: limit))
            default:
                return .failure(.init(message: "unknown operation \"\(op)\""))
            }
        } catch let error as AutomationError {
            return .failure(error)
        } catch {
            return .failure(.init(message: error.localizedDescription))
        }
    }

    private func find(_ args: [String: Any]) throws -> Automation {
        guard let id = args["id"] as? String else { throw AutomationError(message: "id is required") }
        guard let a = store.automations.first(where: { $0.id == id }) else { throw AutomationError(message: "no automation with id \"\(id)\"") }
        return a
    }

    private func create(_ args: [String: Any], by: String) throws -> Automation {
        var raw = (args["automation"] as? [String: Any]) ?? args
        let name = raw["name"] as? String ?? ""
        if raw["id"] == nil { raw["id"] = AutomationValidator.slug(name, taken: Set(store.automations.map(\.id))) }
        raw["createdBy"] = by
        var (parsed, errors) = AutomationValidator.parseOne(raw)
        if let a = parsed {
            errors += AutomationValidator.validate(a, now: engine.env.now(), isNew: true)
            if store.automations.contains(where: { $0.id == a.id }) { errors.append("an automation with id \"\(a.id)\" already exists") }
        }
        guard errors.isEmpty, let a = parsed else { throw AutomationError(message: errors.joined(separator: "\n")) }
        try store.replace(store.automations + [a])
        return a
    }

    private func update(_ args: [String: Any], by: String) throws -> Automation {
        let existing = try find(args)
        let changes = (args["changes"] as? [String: Any]) ?? args.filter { $0.key != "id" }
        guard !changes.isEmpty else { throw AutomationError(message: "changes is empty") }
        var raw = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(existing))) as? [String: Any] ?? [:]
        raw = Self.merge(changes, into: raw)
        if let newTrigger = changes["trigger"] as? [String: Any], let type = newTrigger["type"] as? String, type != existing.trigger.type {
            raw["trigger"] = newTrigger
        }
        raw["id"] = existing.id
        let (parsed, parseErrors) = AutomationValidator.parseOne(raw)
        guard var a = parsed else { throw AutomationError(message: parseErrors.joined(separator: "\n")) }
        // Whoever changes what can run becomes its author. Changing only timing or text keeps the old author.
        a.createdBy = a.riskText == existing.riskText && changes["createdBy"] == nil ? existing.createdBy : by
        let errors = parseErrors + AutomationValidator.validate(a, now: engine.env.now())
        guard errors.isEmpty else { throw AutomationError(message: errors.joined(separator: "\n")) }
        try store.replace(store.automations.map { $0.id == a.id ? a : $0 })
        return a
    }

    private static func merge(_ changes: [String: Any], into base: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in changes {
            if value is NSNull { result[key] = nil }
            else if let nested = value as? [String: Any], let old = base[key] as? [String: Any], key != "match", key != "headers" {
                result[key] = merge(nested, into: old)
            } else { result[key] = value }
        }
        return result
    }

    // MARK: Settings

    /// Saves a hand edit from Settings. The user is the author, so no approval is asked.
    func saveEdited(id: String, json: String) -> String? {
        guard let dict = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return "That is not a JSON object." }
        var raw = dict
        raw["id"] = id
        raw["createdBy"] = "user"
        let (parsed, parseErrors) = AutomationValidator.parseOne(raw)
        guard let a = parsed else { return parseErrors.joined(separator: "\n") }
        let errors = parseErrors + AutomationValidator.validate(a, now: engine.env.now())
        guard errors.isEmpty else { return errors.joined(separator: "\n") }
        do { try store.replace(store.automations.map { $0.id == id ? a : $0 }) } catch { return error.localizedDescription }
        return nil
    }

    func json(for a: Automation) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(a), as: UTF8.self)) ?? ""
    }

    func lastRun(_ id: String) -> AutomationState.Run? { engine.state.history(id, limit: 1).last }

    // MARK: Descriptions

    func summary(_ a: Automation) -> [String: Any] {
        var out: [String: Any] = ["id": a.id, "name": a.name, "enabled": a.enabled, "trigger": describe(a.trigger),
                                  "action": a.action.type, "createdBy": a.createdBy]
        if let next = engine.nextRun(a) { out["nextRun"] = AutomationClock.format(next) }
        if let last = engine.state.history(a.id, limit: 1).last { out["lastRun"] = ["time": AutomationClock.format(last.date), "outcome": last.outcome, "output": last.output] }
        if needsApproval(a) { out["approval"] = isRejected(a) ? "rejected" : "pending" }
        if a.trigger.type == "stream" {
            out["stream"] = engine.streams.status(a.id).rawValue
            if let last = engine.streams.lastEvent(a.id) { out["lastEvent"] = AutomationClock.format(last) }
        }
        return out
    }

    func detail(_ a: Automation) -> [String: Any] {
        var out = summary(a)
        if let data = try? JSONEncoder().encode(a), let full = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in full where out[key] == nil || key == "trigger" || key == "action" { out[key] = value }
        }
        out["recentRuns"] = history(a.id, limit: 5)
        return out
    }

    func history(_ id: String, limit: Int) -> [[String: String]] {
        engine.state.history(id, limit: max(1, limit)).reversed().map {
            ["time": AutomationClock.format($0.date), "outcome": $0.outcome, "output": $0.output]
        }
    }

    func describe(_ t: Automation.Trigger) -> String {
        switch t.type {
        case "interval": return "every \(Int(t.minutes ?? 0)) min (\(t.clock == "wall" ? "clock time" : "keyboard time"))"
        case "daily": return "daily at \((t.times ?? []).joined(separator: ", "))" + (t.weekdays.map { " on \($0.joined(separator: ", "))" } ?? "")
        case "once": return "once at \(t.at ?? "?")"
        case "script": return "runs a script every \(Int(t.minutes ?? 0)) min"
        case "stream":
            let command = (t.command ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return "streams `\(command.count > 60 ? String(command.prefix(60)) + "…" : command)`"
        default: return "polls a \(t.source?.type ?? "?") source every \(Int(t.minutes ?? 0)) min"
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    /// Item values for a shell command, with each string quoted so a title cannot add commands.
    var shellSafe: [String: Any] {
        func quote(_ value: Any) -> Any {
            switch value {
            case let s as String: return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
            case let d as [String: Any]: return d.mapValues(quote)
            case let l as [Any]: return l.map(quote)
            default: return value
            }
        }
        return mapValues(quote)
    }
}
