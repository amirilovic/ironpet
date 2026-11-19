import Combine
import Foundation

enum AutomationApproval: String, Codable, Equatable {
    case pending, rejected
}

struct AutomationRunInfo: Codable, Equatable {
    var date: Date
    /// `fired`, `ok`, `failed`, `baseline`, `skipped` or `waiting`.
    var outcome: String
    var output: String
}

/// What a client shows next to an automation: when it runs, how it last went, whether it waits for approval.
struct AutomationStatus: Codable, Equatable {
    var id: String
    /// One line about the trigger, such as "daily at 09:00".
    var trigger: String
    var nextRun: Date?
    var lastRun: AutomationRunInfo?
    var approval: AutomationApproval?
    /// For a stream automation: `running`, `restarting` or `stopped`.
    var stream: String?
    var lastEvent: Date?
}

struct CreateAutomationRequest: Codable, Equatable {
    /// The automation as a JSON object (name, trigger, action, presentation). A missing id is made from the name.
    var definition: String
    var by = "user"
}

struct UpdateAutomationRequest: Codable, Equatable {
    var id: String
    /// A JSON object merged into the automation. A null value removes the key.
    var changes: String
    var by = "user"
}

/// Changes the time or the days of a daily automation. A nil field keeps its value.
struct SetAutomationScheduleRequest: Codable, Equatable {
    var id: String
    var times: [String]?
    var weekdays: [String]?
    /// Runs every day: removes the weekday list. `weekdays` is ignored when this is set.
    var everyDay = false
}

struct AutomationHistoryRequest: Codable, Equatable {
    var id: String
    var limit = 20
}

struct AutomationLogRequest: Codable, Equatable {
    /// Only this automation's runs. Nil lists every automation.
    var automation: String?
    var limit = 500
    var onlyProblems = false
}

struct AutomationLogEntry: Codable, Equatable, Identifiable {
    var id: Int64
    var automation: String
    var date: Date
    var duration: TimeInterval
    var outcome: String
    var summary: String
    var detail: String
}

struct AutomationRunResult: Codable, Equatable {
    var id: String
    /// `started`, or `waiting for approval` when the user has not approved what it runs.
    var status: String
}

/// Reminders, watchers and scheduled jobs: list, get, create, update, pause, resume, run, history, approve and reject.
@MainActor
final class AutomationsAPI: ObservableObject {
    private let service: AutomationService
    private var forwarding: AnyCancellable?

    init(service: AutomationService) {
        self.service = service
        forwarding = service.store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: Reading

    var automations: [Automation] { service.store.automations }
    /// Why the file could not be read, when it could not.
    var error: String? { service.store.error }
    /// The file the automations are saved in.
    var file: URL { service.store.paths.file }

    func list() -> [Automation] { automations }

    func get(_ id: String) throws -> Automation {
        guard let automation = automations.first(where: { $0.id == id }) else { throw APIError.notFound("no automation with id \"\(id)\"") }
        return automation
    }

    func status(_ id: String) throws -> AutomationStatus {
        let a = try get(id)
        var status = AutomationStatus(id: id, trigger: service.describe(a.trigger))
        status.nextRun = a.enabled ? service.engine.nextRun(a) : nil
        status.lastRun = service.lastRun(id).map { AutomationRunInfo(date: $0.date, outcome: $0.outcome, output: $0.output) }
        if service.needsApproval(a) { status.approval = service.isRejected(a) ? .rejected : .pending }
        if a.trigger.type == "stream" {
            status.stream = service.engine.streams.status(id).rawValue
            status.lastEvent = service.engine.streams.lastEvent(id)
        }
        return status
    }

    func history(_ request: AutomationHistoryRequest) throws -> [AutomationRunInfo] {
        let a = try get(request.id)
        return service.engine.state.history(a.id, limit: max(1, request.limit)).reversed()
            .map { AutomationRunInfo(date: $0.date, outcome: $0.outcome, output: $0.output) }
    }

    /// The command, script or prompt the user is asked to approve.
    func approvalDetail(_ id: String) throws -> String { service.approvalDetail(try get(id)) }

    /// The automation as pretty JSON, for a hand edit.
    func definition(_ id: String) throws -> String { service.json(for: try get(id)) }

    // MARK: Logs

    var logsUnavailable: String? { service.engine.state.unavailable }
    var logRetentionDays: Int { service.logRetentionDays() }

    func logs(_ request: AutomationLogRequest = AutomationLogRequest()) -> [AutomationLogEntry] {
        let all = service.engine.state.logs(automation: request.automation, limit: request.limit)
        let kept = request.onlyProblems ? all.filter { ["failed", "skipped", "waiting"].contains($0.outcome) } : all
        return kept.map { AutomationLogEntry(id: $0.id, automation: $0.automation, date: $0.date, duration: $0.duration,
                                             outcome: $0.outcome, summary: $0.summary, detail: $0.detail) }
    }

    func clearLogs(automation: String?) { service.engine.state.clearLogs(automation: automation) }

    // MARK: Changing

    @discardableResult
    func create(_ request: CreateAutomationRequest) throws -> Automation {
        try run { try service.create(try Self.object(request.definition), by: request.by) }
    }

    @discardableResult
    func update(_ request: UpdateAutomationRequest) throws -> Automation {
        try run { try service.update(["id": request.id, "changes": try Self.object(request.changes)], by: request.by) }
    }

    /// Replaces an automation with a hand-edited JSON document. The user is the author, so no approval is asked.
    func replace(id: String, definition: String) throws {
        if let problem = service.saveEdited(id: id, json: definition) { throw APIError.invalid(problem) }
    }

    func setEnabled(_ id: String, _ enabled: Bool) throws {
        _ = try get(id)
        try run { try service.store.update(id) { $0.enabled = enabled } }
    }

    func setSchedule(_ request: SetAutomationScheduleRequest) throws {
        _ = try get(request.id)
        try run {
            try service.store.update(request.id) {
                if let times = request.times { $0.trigger.times = times }
                if request.everyDay { $0.trigger.weekdays = nil } else if let weekdays = request.weekdays { $0.trigger.weekdays = weekdays }
            }
        }
    }

    func delete(_ id: String) throws {
        let a = try get(id)
        try run { try service.store.replace(service.store.automations.filter { $0.id != a.id }) }
        service.engine.state.forget(a.id)
        service.dismissNotice(AutomationService.approvalID(a.id))
    }

    /// Runs it now, outside its schedule. A poll or script automation polls once.
    func runNow(_ id: String) async throws -> AutomationRunResult {
        let a = try get(id)
        if a.trigger.type == "poll" || a.trigger.type == "script" {
            await service.engine.pollNow(a.id)
        } else {
            service.handle(.init(automations: [a], item: nil, agentWorking: false, manual: true, count: a.trigger.type == "stream" ? 1 : nil))
        }
        return AutomationRunResult(id: a.id, status: service.needsApproval(a) ? "waiting for approval" : "started")
    }

    /// Approves what the automation runs. Any client can do this, as the Approve button does.
    func approve(_ id: String) throws {
        _ = try get(id)
        service.approve(id)
    }

    func reject(_ id: String) throws {
        _ = try get(id)
        service.reject(id)
    }

    /// Asks about, or with auto-approve on approves, every enabled automation whose command is new.
    func reviewApprovals() { service.reviewApprovals() }

    // MARK: JSON adapter

    /// The MCP tools and the `IronPet automations` CLI call this with loose JSON arguments. Their result shapes are part of the
    /// tool contract, so the dictionaries `AutomationService` builds are kept.
    func callJSON(_ op: String, _ args: [String: Any], by: String) async -> Result<Any, AutomationError> {
        await service.call(op, args, by: by)
    }

    // MARK: Helpers

    private static func object(_ json: String) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            throw APIError.invalid("That is not a JSON object.")
        }
        return object
    }

    private func run<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as AutomationError {
            throw error.message.hasPrefix("no automation") ? APIError.notFound(error.message) : APIError.invalid(error.message)
        } catch {
            throw APIError.wrap(error)
        }
    }
}
