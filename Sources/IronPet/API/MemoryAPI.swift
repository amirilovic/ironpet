import Foundation

/// Ghost's memory: notes about the user, their projects and people, and search over past chats, meetings and the screen. The
/// `memory_*` tools reach it here. The app owner supplies the services, which exist only once memory is set up.
@MainActor
final class MemoryAPI {
    private let services: () -> MemoryMCP.Services?

    init(services: @escaping () -> MemoryMCP.Services?) { self.services = services }

    func handles(_ name: String) -> Bool { MemoryMCP.names.contains(name) }

    /// Runs one `memory_*` tool. `caller` names a session that is not the user's chat, such as `automation:<id>`.
    func callTool(_ name: String, _ args: [String: Any], caller: String? = nil) -> Result<Any, MemoryMCP.Failure> {
        guard let services = services() else {
            return .failure(MemoryMCP.Failure(message: "Ghost's memory is not available right now"))
        }
        return MemoryMCP.call(name, args, services: services, caller: caller)
    }
}
