import Foundation

/// Runs a `prompt` action. It gets its own agent process and session in `~/.ironpet/automations/workspace`, so the
/// user's chat keeps its thread, folder and agent. Only read-only tool calls are allowed.
@MainActor
enum AutomationPrompt {
    /// `agentOverride` lets tests run a scripted agent instead of one from the catalog.
    static func run(_ automation: Automation, prompt: String, workspace: URL, timeout: TimeInterval = 300,
                    agentOverride: ACPAgent? = nil) async -> Result<String, AutomationError> {
        let agentID = automation.action.agent ?? UserDefaults.standard.string(forKey: "chatAgent")
        guard let agent = agentOverride ?? AgentCatalog.agent(id: agentID) ?? AgentCatalog.agent(id: "cursor") else {
            return .failure(.init(message: "no agent is available"))
        }
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let runner = ACPBackend(agent: agent)
        runner.restricted = true
        runner.usageFeature = .automations
        runner.onPermission = { call, respond in
            if case .allow = ApprovalRules.policy(for: call, auto: false) { respond(.allow) }
            else { respond(.deny("Automations can only read")) }
        }
        let text = "This is an automated run of \"\(automation.name)\" from ironpet. Answer in under 600 characters, as plain text for a small notification.\n\n\(prompt)"
        let turn = ACPTurn(prompt: text, preamble: nil, workspace: workspace, resume: nil, model: automation.action.model, images: [], files: [])
        let state = Box()
        let task = Task { @MainActor in
            await runner.runTurn(turn) { event in
                switch event {
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
            state.finish(.failure(.init(message: "The agent did not answer within \(Int(timeout)) seconds.")))
        }
        let result = await state.wait()
        watchdog.cancel()
        task.cancel()
        runner.cancel()
        runner.shutdown()
        return result
    }

    @MainActor
    private final class Box {
        var answer = ""
        private var result: Result<String, AutomationError>?
        private var continuation: CheckedContinuation<Result<String, AutomationError>, Never>?

        func finish(_ value: Result<String, AutomationError>) {
            guard result == nil else { return }
            result = value
            continuation?.resume(returning: value)
            continuation = nil
        }

        func wait() async -> Result<String, AutomationError> {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }
    }
}
