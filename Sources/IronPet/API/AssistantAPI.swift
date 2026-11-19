import Foundation

/// The assistant tools: hand work to background jobs (`jobs_*`), answer "what is going on" (`status_*`), keep memory
/// (`memory_*`) and find the folder a job runs in (`projects_resolve`). They read the other namespaces through the context.
@MainActor
final class AssistantAPI {
    private let context: AssistantContext

    init(context: AssistantContext) { self.context = context }

    func handles(_ name: String) -> Bool { AssistantMCP.handles(name) }

    func callTool(_ name: String, _ args: [String: Any], fromVoice: Bool = false) -> Result<Any, JobError> {
        AssistantMCP.call(name, args, context: context, fromVoice: fromVoice)
    }
}
