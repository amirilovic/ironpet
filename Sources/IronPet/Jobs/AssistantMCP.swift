import Foundation

/// What the assistant tools read and drive. `AppDelegate` fills it in; tests build their own.
@MainActor
final class AssistantContext {
    var jobs: () -> JobService? = { nil }
    /// The agent sessions ironpet watches through hooks, background jobs left out.
    var sessions: () -> [AgentSession] = { [] }
    var tasks: () -> TasksAPI? = { nil }
    var alerts: () -> [Signal] = { [] }
    var brief: (Brief.Kind) -> Brief? = { _ in nil }
    var meetings: () -> [MeetingRecord] = { [] }
    var projects: () -> [ProjectCandidate] = { [] }
    /// Opens a job's thread in the chat, now or when the chat's turn ends. Returns what to tell the agent.
    var openJob: (String) -> Result<String, JobError> = { _ in .failure(JobError(message: "the chat is not available")) }
    var now: () -> Date = Date.init
}

/// The tools that make Ghost an assistant: hand work to background jobs (`jobs_*`), answer "what's going on" (`status_*`),
/// and find the folder a job runs in (`projects_resolve`). Served by `MCPEndpoint` at `POST /mcp`. Memory has its own tools (`MemoryMCP`).
@MainActor
enum AssistantMCP {
    static let prefixes = ["jobs_", "status_", "projects_"]

    static func handles(_ name: String) -> Bool { prefixes.contains { name.hasPrefix($0) } }

    static let jobsGuide = """
        A background job is a separate agent session that does a piece of work while the user carries on. Use one when the user hands \
        you work that takes more than a minute or two, or asks for it to run in the background. Start it with projects_resolve's \
        folder: ask which project when the answer is ambiguous, and use the no-project folder for work that is not about code. Write \
        the prompt as full instructions for an agent that has not seen this conversation. After starting, tell the user in one short \
        sentence what you started and where. Commands that could destroy data wait for the user to click Allow; you cannot approve them.
        """

    static var tools: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required]]
        }
        let id: [String: Any] = ["id": ["type": "string", "description": "Job id, such as job-k3m9qa"]]
        return [
            tool("jobs_start", "Start a background job.\n\n" + jobsGuide,
                 ["title": ["type": "string", "maxLength": Job.titleLimit, "description": "A few words for the Agents list and the task, such as \"Fix the flaky login test\""],
                  "prompt": ["type": "string", "maxLength": Job.promptLimit, "description": "Full instructions for the agent that does the work"],
                  "folder": ["type": "string", "description": "A path projects_resolve returned"]],
                 required: ["title", "prompt", "folder"]),
            tool("jobs_list", "List background jobs: the running and queued ones, and those that finished in the last day.",
                 ["include_older": ["type": "boolean", "description": "Also list jobs that finished earlier"]]),
            tool("jobs_get", "One job in full, with its last steps and the reply so far.", id, required: ["id"]),
            tool("jobs_followup", "Send a job another message. A running job gets it after its current step; a finished one starts again in the same session.",
                 id.merging(["message": ["type": "string", "maxLength": Job.promptLimit]]) { a, _ in a }, required: ["id", "message"]),
            tool("jobs_stop", "Stop a job. Only when the user asks.", id, required: ["id"]),
            tool("jobs_open", "Show a job's transcript to the user in the chat.", id, required: ["id"]),
            tool("projects_resolve", "Find the folder for a job from what the user called the project. Returns best (use it), or matches to ask the user about when ambiguous is true. Without a name, best is the project the user is working in. name \"no project\" gives the folder for work that is not about code.",
                 ["name": ["type": "string", "description": "What the user called it, such as \"ironpet\" or \"the kokous repo\""]]),
            tool("status_overview", "What's going on, in one call: agent sessions that need the user or are running, background jobs, tasks that need the user, open alerts and recent meetings. Use it for \"what's going on\" or \"anything need me\".", [:]),
            tool("status_sessions", "The coding agent sessions ironpet watches (Cursor, Claude Code, Codex and others): status, project, prompt and last reply.", [:]),
            tool("status_alerts", "The open alerts from ironpet's watchers: failed CI, reviews waiting, production errors.", [:]),
            tool("status_today", "Today's brief (what needs the user this morning) or recap (what finished today).",
                 ["kind": ["type": "string", "enum": Brief.Kind.allCases.map(\.rawValue)]]),
            tool("status_meetings", "Recent recorded meetings with their summary line and the user's open action items.",
                 ["limit": ["type": "integer", "minimum": 1, "maximum": 20]]),
        ]
    }

    /// Tools that only read ironpet's own state or open a job's thread. They run without an approval, like the task tools.
    nonisolated static let ownTools: Set<String> = ["jobs_list", "jobs_get", "jobs_open", "projects_resolve", "status_overview", "status_sessions",
                                        "status_alerts", "status_today", "status_meetings"]
    /// Tools that start or steer a job. They ask in a chat without Auto; voice mode runs them, since that is how it hands work off.
    nonisolated static let jobControl: Set<String> = ["jobs_start", "jobs_followup", "jobs_stop"]
    static let voiceHoldNote = "It starts \(Int(JobService.voiceHold)) seconds after you have told the user, so they can still say \"cancel that\"."

    /// `fromVoice`: the call came from voice mode's session, whose jobs wait until the pet has answered and
    /// `JobService.voiceHold` more before they start.
    static func call(_ name: String, _ args: [String: Any], context: AssistantContext, fromVoice: Bool = false) -> Result<Any, JobError> {
        do {
            return .success(try run(name, args, context, fromVoice: fromVoice))
        } catch let error as JobError {
            return .failure(error)
        } catch {
            return .failure(JobError(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    private static func run(_ name: String, _ args: [String: Any], _ context: AssistantContext, fromVoice: Bool) throws -> Any {
        func string(_ key: String) -> String? { (args[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }
        func required(_ key: String) throws -> String {
            guard let value = string(key) else { throw JobError(message: "\(key) is required") }
            return value
        }
        func jobs() throws -> JobService {
            guard let jobs = context.jobs() else { throw JobError(message: "background jobs are not available right now") }
            if let reason = jobs.unavailable { throw JobError(message: "background jobs are not available: \(reason)") }
            return jobs
        }

        switch name {
        case "jobs_start":
            let path = try required("folder")
            guard let candidate = ProjectResolver.candidate(at: path, in: context.projects()) else {
                throw JobError(message: "\(path) is not a folder ironpet knows. Call projects_resolve and use a path it returns.")
            }
            if candidate.sources.contains(.noProject) {
                try FileManager.default.createDirectory(at: candidate.url, withIntermediateDirectories: true)
            }
            let job = try jobs().start(title: try required("title"), prompt: try required("prompt"), folder: candidate.url, fromVoice: fromVoice)
            var object = job.json
            object["project"] = candidate.name
            if fromVoice {
                object["note"] = Self.voiceHoldNote
            }
            return object
        case "jobs_list":
            let cutoff = context.now().addingTimeInterval(-86_400)
            let all = try jobs().jobs
            let listed = args["include_older"] as? Bool == true ? all : all.filter { $0.state.isActive || ($0.ended ?? $0.created) > cutoff }
            return ["jobs": listed.map(\.json), "running": all.filter { $0.state == .running || $0.state == .needsApproval }.count,
                    "queued": all.filter { $0.state == .queued }.count]
        case "jobs_get":
            let service = try jobs()
            let id = try required("id")
            guard let job = service.job(id) else { throw JobError(message: "no job with id \"\(id)\"") }
            var object = job.json
            object["recent_steps"] = service.recentSteps(id)
            return object
        case "jobs_followup":
            let service = try jobs()
            let job = try service.followUp(try required("id"), message: try required("message"), fromVoice: fromVoice)
            var object = job.json
            if fromVoice, service.isHeld(job.id) { object["note"] = Self.voiceHoldNote }
            return object
        case "jobs_stop":
            return try jobs().stop(try required("id")).json
        case "jobs_open":
            let id = try required("id")
            guard try jobs().job(id) != nil else { throw JobError(message: "no job with id \"\(id)\"") }
            return ["job": id, "result": try context.openJob(id).get()]
        case "projects_resolve":
            let candidates = context.projects()
            let result = ProjectResolver.resolve(string("name"), in: candidates)
            var object: [String: Any] = ["matches": result.matches.map(\.json), "ambiguous": result.ambiguous]
            object["best"] = result.best?.json
            if result.matches.isEmpty { object["known"] = candidates.map(\.json) }
            return object
        case "status_overview":
            return overview(context)
        case "status_sessions":
            return ["sessions": context.sessions().map(sessionJSON)]
        case "status_alerts":
            return ["alerts": context.alerts().map(alertJSON)]
        case "status_today":
            let kind = string("kind").flatMap(Brief.Kind.init(rawValue:)) ?? .brief
            guard let brief = context.brief(kind) else { throw JobError(message: "the brief is not available right now") }
            return ["kind": kind.rawValue, "lines": brief.lines,
                    "sections": brief.sections.filter { !$0.items.isEmpty }.map { section in
                        ["title": section.title, "items": section.items.map { item -> [String: Any] in
                            var object: [String: Any] = ["title": item.title]
                            object["detail"] = item.subtitle
                            return object
                        }]
                    }]
        case "status_meetings":
            let limit = min(20, max(1, (args["limit"] as? Int) ?? 5))
            return ["meetings": context.meetings().prefix(limit).map(meetingJSON)]
        default:
            throw JobError(message: "unknown tool \(name)")
        }
    }

    private static func overview(_ context: AssistantContext) -> [String: Any] {
        let sessions = context.sessions()
        let jobs = context.jobs()?.jobs ?? []
        let cutoff = context.now().addingTimeInterval(-86_400)
        let tasks = context.tasks()?.items.filter { $0.status != .done } ?? []
        var object: [String: Any] = [
            "sessions": [
                "need_you": sessions.filter { $0.status == .needsInput || $0.status == .failed }.map(sessionJSON),
                "running": sessions.filter { $0.status == .running }.map(sessionJSON),
                "finished": sessions.filter { $0.status == .done }.map(sessionJSON),
            ],
            "jobs": jobs.filter { $0.state.isActive || ($0.ended ?? $0.created) > cutoff }.map(\.json),
            "tasks": [
                "needs_you": tasks.filter { $0.status == .needsYou && $0.waitingOn == nil }.map { ["id": $0.id, "title": $0.title] },
                "in_progress": tasks.filter { $0.status == .inProgress }.map { ["id": $0.id, "title": $0.title] },
                "backlog": tasks.filter { $0.status == .backlog }.count,
            ],
            "alerts": context.alerts().map(alertJSON),
            "meetings": context.meetings().prefix(3).map(meetingJSON),
        ]
        if context.tasks() == nil { object["tasks"] = nil }
        return object
    }

    private static func sessionJSON(_ session: AgentSession) -> [String: Any] {
        var object: [String: Any] = ["id": session.id, "agent": session.source.displayName, "status": session.status.label,
                                     "project": session.workspaceName, "updated": ISO8601DateFormatter().string(from: session.updatedAt)]
        object["prompt"] = session.prompt
        object["doing"] = session.status == .running || session.status == .needsInput ? session.detail : nil
        object["summary"] = session.summary
        return object
    }

    private static func alertJSON(_ signal: Signal) -> [String: Any] {
        var object: [String: Any] = ["id": signal.id, "label": signal.label, "title": signal.title, "detail": signal.subtitle,
                                     "since": ISO8601DateFormatter().string(from: signal.date)]
        object["url"] = signal.url?.absoluteString
        return object
    }

    private static func meetingJSON(_ meeting: MeetingRecord) -> [String: Any] {
        var object: [String: Any] = ["id": meeting.id, "date": ISO8601DateFormatter().string(from: meeting.date), "summary": meeting.preview]
        if meeting.hasSummary, let text = try? String(contentsOf: meeting.summaryURL, encoding: .utf8) {
            object["my_action_items"] = ActionItems.openItems(text).map { item -> [String: Any] in
                var entry: [String: Any] = ["title": item.title]
                entry["due"] = item.due
                return entry
            }
        }
        return object
    }
}
