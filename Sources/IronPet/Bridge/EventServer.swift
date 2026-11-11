import Foundation
import Network

/// Minimal loopback HTTP endpoint that receives `POST /event` from the hook script.
final class EventServer {
    private let token: String
    private let onEvent: (HookEvent) -> Void
    /// JSON snapshot served at `GET /status`, for debugging.
    var status: () -> Data = { Data("{}".utf8) }
    /// Gated hook calls from pet-started agents. The hook blocks until `respond` is called.
    var onApproval: ((ApprovalRequest, @escaping (ApprovalDecision) -> Void) -> Void)?
    /// `/test/*` control endpoints; only set when the app runs with `--test-mode`.
    var onTest: ((HTTPRequest, @escaping (Data) -> Void) -> Void)?
    private let queue = DispatchQueue(label: "ironpet.event-server")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    init(token: String, onEvent: @escaping (HookEvent) -> Void) {
        self.token = token
        self.onEvent = onEvent
    }

    /// Binds to 127.0.0.1 on the first free port starting at `preferredPort`.
    func start(preferredPort: UInt16 = 47321) throws {
        var lastError: Error?
        for candidate in preferredPort..<(preferredPort + 20) {
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: candidate)!)
                let listener = try NWListener(using: params)
                let ready = DispatchSemaphore(value: 0)
                var failed: Error?
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: ready.signal()
                    case .failed(let error): failed = error; ready.signal()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                listener.start(queue: queue)
                _ = ready.wait(timeout: .now() + 2)
                if let failed { listener.cancel(); throw failed }
                self.listener = listener
                port = candidate
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NWError.posix(.EADDRINUSE)
    }

    private func accept(_ connection: NWConnection) {
        let reader = RequestReader(connection: connection, queue: queue) { [weak self] request in
            self?.handle(request, on: connection)
        }
        reader.start()
    }

    private func handle(_ request: HTTPRequest?, on connection: NWConnection) {
        guard let request else { return respond(connection, status: "400 Bad Request") }
        guard request.header("x-ironpet-token") == token else { return respond(connection, status: "403 Forbidden") }
        if request.method == "GET", request.path == "/status" {
            return respond(connection, status: "200 OK", body: status())
        }
        if request.method == "POST", request.path == "/approval" {
            let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let approval = ApprovalRequest(event: request.header("x-ironpet-event") ?? "",
                                           runID: request.header("x-ironpet-run-id") ?? "", payload: payload)
            let source = request.header("x-ironpet-source").flatMap(AgentSource.init(rawValue:)) ?? .cursor
            guard let onApproval else {
                return respond(connection, status: "200 OK", body: ApprovalDecision.deny("ironpet is not ready").json(for: source))
            }
            onApproval(approval) { [queue] decision in
                queue.async { self.respond(connection, status: "200 OK", body: decision.json(for: source)) }
            }
            return
        }
        if request.path.hasPrefix("/test/") {
            guard let onTest else { return respond(connection, status: "404 Not Found") }
            onTest(request) { [queue] body in
                queue.async { self.respond(connection, status: "200 OK", body: body) }
            }
            return
        }
        guard request.method == "POST", request.path == "/event" else { return respond(connection, status: "404 Not Found") }
        guard let source = request.header("x-ironpet-source").flatMap(AgentSource.init(rawValue:)),
              let name = request.header("x-ironpet-event"), !name.isEmpty else {
            return respond(connection, status: "400 Bad Request")
        }
        let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        let origin = SessionOrigin(
            workspace: request.header("x-ironpet-cwd").flatMap { $0.isEmpty ? nil : $0 },
            termProgram: request.header("x-ironpet-term-program"),
            itermSessionID: request.header("x-ironpet-iterm-session"),
            pid: request.header("x-ironpet-pid").flatMap { Int32($0) }
        )
        let runID = request.header("x-ironpet-run-id").flatMap { $0.isEmpty ? nil : $0 }
        onEvent(HookEvent(source: source, name: name, payload: payload, origin: origin, runID: runID))
        respond(connection, status: "204 No Content")
    }

    private func respond(_ connection: NWConnection, status: String, body: Data = Data()) {
        var response = Data("HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

struct ApprovalRequest {
    let event: String
    let runID: String
    let payload: [String: Any]
}

/// Hook permission response. Never `ask`: headless cursor-agent treats it as allow.
struct ApprovalDecision {
    let allow: Bool
    let message: String

    static let allow = ApprovalDecision(allow: true, message: "Approved in ironpet")
    static func deny(_ message: String = "The user denied this in ironpet") -> ApprovalDecision {
        ApprovalDecision(allow: false, message: message)
    }

    func json(for source: AgentSource) -> Data {
        let object: [String: Any]
        switch source {
        case .cursor:
            object = ["permission": allow ? "allow" : "deny", "user_message": message, "agent_message": message]
        case .claude:
            object = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": allow ? "allow" : "deny",
                                             "permissionDecisionReason": message]]
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Returns nil until the buffer holds the full headers and `Content-Length` body.
    static func parse(_ buffer: Data) -> HTTPRequest?? {
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[..<split.lowerBound], encoding: .utf8) else { return .some(nil) }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .some(nil) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[split.upperBound...]
        guard body.count >= length else { return nil }
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]),
                           headers: headers, body: Data(body.prefix(length)))
    }
}

private final class RequestReader {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let completion: (HTTPRequest?) -> Void
    private var buffer = Data()

    init(connection: NWConnection, queue: DispatchQueue, completion: @escaping (HTTPRequest?) -> Void) {
        self.connection = connection
        self.queue = queue
        self.completion = completion
    }

    func start() {
        connection.start(queue: queue)
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if let parsed = HTTPRequest.parse(buffer) {
                completion(parsed)
            } else if isComplete || error != nil || buffer.count > 8 * 1024 * 1024 {
                connection.cancel()
            } else {
                read()
            }
        }
    }
}
