import Foundation

/// What the `desktop_*` tools do on this Mac: read other apps' windows through Accessibility and press, type, select and open.
/// Off until the user turns on `desktopControl.enabled` in settings, and every call checks that again.
@MainActor
final class DesktopAPI {
    private let service: DesktopService
    private let settings: SettingsAPI

    init(service: DesktopService, settings: SettingsAPI) {
        self.service = service
        self.settings = settings
    }

    var enabled: Bool { settings.config.desktopControl.enabled }

    /// Runs one `desktop_*` tool by name. The MCP endpoint calls it with the agent's arguments.
    func callTool(_ name: String, _ args: [String: Any]) async -> Result<DesktopOutput, DesktopService.Failure> {
        await service.call(name, args)
    }

    /// Opens a web address in a browser, by name or bundle id, or the frontmost browser when nil.
    func openURL(_ url: String, browser: String? = nil) async throws {
        var args: [String: Any] = ["url": url]
        if let browser { args["browser"] = browser }
        if case .failure(let error) = await service.call("desktop_open_url", args) { throw Self.error(error) }
    }

    /// Presses an element by the ref that `desktop_snapshot` or `desktop_find` gave.
    func press(ref: String) async throws {
        if case .failure(let error) = await service.call("desktop_press", ["ref": ref]) { throw Self.error(error) }
    }

    /// Presses a key, such as "return" or "cmd+l", in one app.
    func key(app: String, key: String) async throws {
        if case .failure(let error) = await service.call("desktop_key", ["app": app, "key": key]) { throw Self.error(error) }
    }

    private static func error(_ failure: DesktopService.Failure) -> APIError {
        failure.message.contains("is off") ? .unavailable(failure.message) : .failed(failure.message)
    }
}
