import Foundation

/// Runs a `prompt` action with `session` set to `new` or `own`. The run gets its own agent process with the agent's full
/// tools minus the action's `disallowedTools`, and is saved as a thread marked as an automation run, so the user can open
/// it from the thread list. It never touches the open chat.
///
/// `new` starts a fresh agent session every run. `own` resumes the thread this automation used last, and starts a fresh
/// one after `ownRunLimit` runs, so a thread does not grow without bound.
@MainActor
enum AutomationSession {
    /// Runs one `own` thread holds before the next run starts a fresh thread.
    static let ownRunLimit = 50

    /// Nobody is there to answer, so anything that would ask is refused. Edits to Ghost's memory files are refused too: what an
    /// automation learns goes through the memory tools, which mark it as coming from the automation.
    nonisolated static func decision(for call: ACPToolCall) -> ApprovalDecision {
        if ["edit", "delete", "move"].contains(call.kind), let path = call.path, FileMemoryStore.contains(path) {
            return .deny("Automations may not edit Ghost's memory files")
        }
        if case .allow = ApprovalRules.policy(for: call, auto: true) { return .allow }
        return .deny("This automation runs without anyone to ask")
    }
    /// Threads kept per automation. Older ones are deleted after a run.
    static let keptThreads = 50

    typealias TurnRunner = (ACPTurn, @escaping (AgentEvent) -> Void) async -> Void

    /// `agentOverride` and `turnRunner` let tests run a scripted agent.
    static func run(_ automation: Automation, prompt: String, workspace: URL, timeout: TimeInterval = 900,
                    agentOverride: ACPAgent? = nil, turnRunner: TurnRunner? = nil, now: Date = Date()) async -> Result<String, AutomationError> {
        guard let agent = agentOverride ?? AgentCatalog.agent(id: AutomationPrompt.agentID(automation)) else {
            return .failure(.init(message: "no agent is available"))
        }
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        var earlier: ChatThread?
        if automation.action.session == "own", let last = ThreadStore.latest(automation: automation.id),
           (last.runs ?? 0) < ownRunLimit, last.agent == agent.id {
            earlier = last
        }
        // The prompt goes in as written: a slash skill such as `/am-check-emails 1` only works as the first thing in the message.
        let turn = ACPTurn(prompt: prompt, preamble: nil, workspace: workspace, resume: earlier?.id, model: automation.action.model,
                           images: [], files: [], allowedTools: automation.action.allowedTools, disallowedTools: automation.action.disallowedTools)

        var backend: ACPBackend?
        var run = turnRunner
        if run == nil {
            let created = ACPBackend(agent: agent)
            created.usageFeature = .automations
            created.mcpCaller = "automation:\(automation.id)"
            created.sharesMemoryFolder = false
            created.onPermission = { call, respond in respond(Self.decision(for: call)) }
            backend = created
            run = { turn, emit in await created.runTurn(turn, onEvent: emit) }
        }

        let state = AutomationPrompt.Box()
        var sessionID: String?
        var transcript = TranscriptRecorder()
        let task = Task { @MainActor in
            await run?(turn) { event in
                transcript.record(event)
                switch event {
                case .session(let id): sessionID = id
                case .assistant(let chunk): state.answer += chunk
                case .finished(let error): state.finish(error.map { .failure(.init(message: $0)) } ?? .success(state.answer))
                case .needsSignIn: state.finish(.failure(.init(message: "\(agent.name) needs you to sign in. Open it in the chat once, then try again.")))
                case .needsRuntime: state.finish(.failure(.init(message: "\(agent.name) needs Node 22 or Bun. Open it in the chat once to set that up.")))
                default: break
                }
            }
        }
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            state.finish(.failure(.init(message: "The agent did not finish within \(Int(timeout / 60)) minutes.")))
        }
        let result = await state.wait()
        watchdog.cancel()
        task.cancel()
        sessionID = sessionID ?? backend?.sessionID ?? earlier?.id
        backend?.cancel()
        backend?.shutdown()

        if case .failure(let error) = result { transcript.append(.init(kind: .error(error.message))) }
        let items = transcript.items
        if let sessionID {
            let resumed = earlier.flatMap { $0.id == sessionID ? $0 : nil }
            let first = ChatSession.Item(kind: .user(prompt), origin: ChatSession.automationOrigin)
            ThreadStore.save(ChatThread(id: sessionID, title: automation.name, workspace: workspace.path, updatedAt: now,
                                        items: (resumed?.items ?? []) + [first] + items, agent: agent.id,
                                        automation: automation.id, automationName: automation.name, runs: (resumed?.runs ?? 0) + 1))
            ThreadStore.prune(automation: automation.id, keep: keptThreads)
        }
        return result
    }
}
