import Combine
import Foundation

struct ScreenSearchRequest: Codable, Equatable {
    var query: String
    /// Only this app, by bundle id or name.
    var app: String?
    var since: Date?
    var until: Date?
    var limit = 20
}

/// What screen capture stored: the local text of windows the user worked in, with secrets already redacted. Nothing here reads
/// the screen. Turning capture on or off is a setting (`api.settings`); pausing it is here.
///
/// This is an `ObservableObject` so the Screen section and its settings page redraw as captures arrive.
@MainActor
final class ScreenAPI: ObservableObject {
    private let service: CaptureService
    private var forwarding: AnyCancellable?

    init(service: CaptureService) {
        self.service = service
        forwarding = service.model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Whether capture runs, what macOS allows it, whether it is paused, how many captures are stored.
    var status: CaptureStatusModel { service.model }

    /// Reads the state again, for example after the user changed a permission.
    func refreshStatus() { service.refreshModel() }

    func recent(limit: Int = 50) async -> [StoredCapture] {
        let store = service.store
        return await Task.detached(priority: .userInitiated) { store.recent(limit: limit) }.value
    }

    func search(_ request: ScreenSearchRequest) async throws -> [CaptureHit] {
        let query = request.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { throw APIError.invalid("query is required") }
        let store = service.store
        return await Task.detached(priority: .userInitiated) {
            store.search(query, app: request.app, since: request.since, until: request.until, limit: request.limit)
        }.value
    }

    /// The text stored for one capture. Nil when it was deleted.
    func captureText(_ id: Int64) async -> String? {
        let store = service.store
        return await Task.detached(priority: .userInitiated) { store.capture(id: id)?.text }.value
    }

    /// The apps captured so far, with how many captures each has, for the exclude list.
    func seenApps() -> [(bundleId: String, name: String, captures: Int)] { service.store.seenApps() }

    func pause(for seconds: TimeInterval) throws {
        guard seconds > 0 else { throw APIError.invalid("the pause must be longer than zero") }
        service.privacy.pause(for: seconds)
        service.refreshModel()
    }

    func pauseUntilTomorrow() {
        service.privacy.pauseUntilTomorrow()
        service.refreshModel()
    }

    func resume() {
        service.privacy.resume()
        service.refreshModel()
    }

    /// Deletes every stored capture.
    func clear() {
        service.store.clear()
        service.refreshModel()
    }

    /// The MCP tools `screen_search` and `screen_window`, which read loose JSON arguments.
    func callTool(_ name: String, _ args: [String: Any]) -> Result<Any, ScreenMCP.Failure> {
        ScreenMCP.call(name, args, store: service.store)
    }
}
