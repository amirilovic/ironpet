import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore

/// What each request carries through the router: the device the token named, once the gate has checked it.
struct RemoteContext: RequestContext, WebSocketRequestContext {
    var coreContext: CoreRequestContextStorage
    let webSocket: WebSocketHandlerReference<Self>
    var device: RemoteDevice?

    /// Request bodies are capped at 1 MiB.
    var maxUploadSize: Int { RemoteServer.maxBody }

    init(source: Source) {
        coreContext = .init(source: source)
        webSocket = .init()
        device = nil
    }
}

/// Every request passes here first. It limits and checks the token, runs the route, makes errors one JSON shape, adds `Cache-Control:
/// no-store` and writes one access log row. The row has the method, the route template (`/v1/tasks/:id`), the status, the size and the
/// time. It never has the path, the query, a header or a body, so no token or code can reach it.
struct RemoteGate: RouterMiddleware {
    typealias Context = RemoteContext
    let service: RemoteService

    /// The two routes a device without a token may call.
    private static let open: Set<String> = ["/v1/pair", "/v1/pair/:id"]

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let started = ContinuousClock.now
        var context = context
        var response: Response
        do {
            response = try await dispatch(request, &context, next)
        } catch {
            response = RemoteServer.errorResponse(error)
        }
        response.headers[.cacheControl] = "no-store"
        let elapsed = ContinuousClock.now - started
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        service.log(RemoteAccessRow(at: Date(), deviceID: context.device?.id, method: request.method.rawValue,
                                    route: Self.template(context.endpointPath) ?? "-", status: Int(response.status.code),
                                    bytes: response.body.contentLength ?? 0, durationMs: ms))
        return response
    }

    /// The router names a parameter `{id}`. The log and the open-route list write it `:id`.
    static func template(_ path: String?) -> String? {
        path?.replacingOccurrences(of: #"\{(\w+)\}"#, with: ":$1", options: .regularExpression)
    }

    private func dispatch(_ request: Request, _ context: inout Context, _ next: (Request, Context) async throws -> Response) async throws -> Response {
        // Headers over 64 KiB are refused before anything reads them.
        let headerBytes = request.headers.reduce(0) { $0 + $1.name.rawName.utf8.count + $1.value.utf8.count + 4 }
        if headerBytes > RemoteServer.maxHeaders {
            return RemoteServer.error(431, "headers_too_large", "request headers are too large")
        }
        if let length = request.headers[.contentLength].flatMap(Int.init), length > RemoteServer.maxBody {
            return RemoteServer.error(413, "too_large", "request body is larger than \(RemoteServer.maxBody) bytes")
        }
        if let path = Self.template(context.endpointPath), Self.open.contains(path) {
            return try await next(request, context)
        }
        switch service.authenticate(authorization: request.headers[.authorization], origin: request.headers[.xForwardedFor]) {
        case .device(let device):
            context.device = device
            return try await next(request, context)
        case .unauthorized:
            return RemoteServer.error(401, "unauthorized", "unauthorized")
        case .limited(let seconds):
            return RemoteServer.limited(seconds)
        }
    }
}

extension HTTPField.Name {
    static let xForwardedFor = HTTPField.Name("X-Forwarded-For")!
    static let pairingSecret = HTTPField.Name("X-Pairing-Secret")!
}

/// The remote API: Hummingbird on 127.0.0.1, one port for REST and the event socket. It trusts nothing about the connection. Every route
/// but pairing needs a device token, and every route calls `IronPetAPI` like any other client. TLS is the job of the user's own front
/// (`tailscale serve`), which forwards to this port.
@MainActor
final class RemoteServer {
    nonisolated static let maxBody = 1 << 20
    nonisolated static let maxHeaders = 64 << 10

    let service: RemoteService
    private let api: IronPetAPI
    private var task: Task<Void, Never>?
    /// The port the listener is bound to, while it runs.
    private(set) var port: Int?

    init(api: IronPetAPI, service: RemoteService) {
        self.api = api
        self.service = service
    }

    var isRunning: Bool { task != nil }

    /// Starts listening on `port` (0 picks a free one, for tests). Throws when the port is taken.
    func start(port requested: Int) async throws {
        guard task == nil else { return }
        let (started, report) = AsyncStream<Result<Int, Error>>.makeStream()
        let app = makeApplication(port: requested) { report.yield(.success($0)) }
        let running = Task.detached {
            do {
                try await app.runService()
                report.yield(.failure(RemoteServerError.stopped))
            } catch {
                report.yield(.failure(error))
            }
            report.finish()
        }
        for await result in started {
            switch result {
            case .success(let bound):
                port = bound
                task = running
                return
            case .failure(let error):
                running.cancel()
                throw error
            }
        }
        throw RemoteServerError.stopped
    }

    /// Closes the listener and every event socket. Tokens stay valid.
    func stop() async {
        guard let running = task else { return }
        task = nil
        port = nil
        service.closeAllSockets()
        running.cancel()
        await running.value
    }

    enum RemoteServerError: Error, LocalizedError {
        case stopped
        var errorDescription: String? { "the remote API stopped before it was listening" }
    }

    // MARK: Application

    private func makeApplication(port: Int, onRunning: @escaping @Sendable (Int) -> Void) -> some ApplicationProtocol {
        let router = Router(context: RemoteContext.self)
        router.add(middleware: RemoteGate(service: service))
        addRoutes(to: router)
        let upgrades = Router(context: RemoteContext.self)
        addEventSocket(to: upgrades)
        var configuration = ApplicationConfiguration(address: .hostname("127.0.0.1", port: port))
        configuration.serverName = nil
        // The server's own logger stays silent: its messages carry request paths and error text, which the access log keeps out on purpose.
        let silent = Logger(label: "ironpet.remote", factory: { _ in SwiftLogNoOpLogHandler() })
        return Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: upgrades,
                                           configuration: .init(maxFrameSize: 1 << 14, autoPing: .enabled(timePeriod: .seconds(20)))),
            configuration: configuration,
            onServerRunning: { channel in onRunning(channel.localAddress?.port ?? port) },
            logger: silent)
    }

    // MARK: Routes

    private func addRoutes(to router: Router<RemoteContext>) {
        let service = service
        router.post("/v1/pair") { request, context -> Response in
            let body = try await Self.object(request, context)
            let key = body["device_public_key"] as? String
            switch service.pair(code: body["code"] as? String ?? "", deviceName: body["device_name"] as? String ?? "", publicKey: key) {
            case .accepted(let accepted):
                return Self.json(202, ["pairing_id": accepted.pairingID, "secret": accepted.secret, "expires_in": accepted.expiresIn,
                                       "public_key": accepted.publicKey.base64EncodedString(), "signature": accepted.signature.base64EncodedString()])
            case .invalid(let message): return Self.error(400, "invalid", message)
            case .unauthorized: return Self.error(401, "unauthorized", "unauthorized")
            case .limited(let seconds): return Self.limited(seconds)
            }
        }
        router.get("/v1/pair/:id") { request, context -> Response in
            let id = context.parameters.get("id") ?? ""
            switch service.poll(id: id, secret: request.headers[.pairingSecret] ?? "") {
            case .pending: return Self.json(200, ["status": "pending"])
            case .denied: return Self.json(200, ["status": "denied"])
            case .expired: return Self.json(200, ["status": "expired"])
            case .allowed(let token, let deviceID): return Self.json(200, ["status": "allowed", "token": token, "device_id": deviceID])
            case .gone: return Self.error(410, "gone", "the token was already handed out")
            case .unauthorized: return Self.error(401, "unauthorized", "unauthorized")
            case .limited(let seconds): return Self.limited(seconds)
            }
        }
        router.get("/v1/devices/me") { _, context -> Response in
            guard let device = context.device else { return Self.error(401, "unauthorized", "unauthorized") }
            return Self.json(200, Self.describe(device))
        }
        router.delete("/v1/devices/me") { _, context -> Response in
            guard let device = context.device else { return Self.error(401, "unauthorized", "unauthorized") }
            service.revoke(device.id)
            return Self.json(200, ["revoked": true])
        }
        // A request that reaches here without an upgrade, or whose upgrade the socket router refused.
        router.get("/v1/events") { _, context -> Response in
            guard let device = context.device else { return Self.error(401, "unauthorized", "unauthorized") }
            if service.socketCount(device: device.id) >= RemoteService.socketsPerDevice { return Self.limited(5) }
            return Self.error(426, "upgrade_required", "this route is a WebSocket")
        }

        router.get("/v1/tasks") { [self] request, context in
            let query = Self.query(request)
            return try await self.call(context) { try $0.list(query: query) }
        }
        router.post("/v1/tasks") { [self] request, context in
            let body = try await Self.object(request, context)
            return try await self.call(context, status: 201) { try $0.create(body) }
        }
        router.get("/v1/tasks/:id") { [self] _, context in
            let id = context.parameters.get("id") ?? ""
            return try await self.call(context) { try $0.get(id) }
        }
        router.patch("/v1/tasks/:id") { [self] request, context in
            let id = context.parameters.get("id") ?? ""
            let body = try await Self.object(request, context)
            return try await self.call(context) { try $0.update(id, body) }
        }
        router.post("/v1/tasks/:id/close") { [self] request, context in
            let id = context.parameters.get("id") ?? ""
            let body = try await Self.object(request, context)
            return try await self.call(context) { try $0.close(id, body) }
        }
        router.delete("/v1/tasks/:id") { [self] _, context in
            let id = context.parameters.get("id") ?? ""
            return try await self.call(context) { try $0.delete(id) }
        }
        router.get("/v1/suggestions") { [self] _, context in
            try await self.call(context) { try $0.suggestions() }
        }
        router.post("/v1/suggestions/:id/accept") { [self] request, context in
            let id = context.parameters.get("id") ?? ""
            let body = try await Self.object(request, context)
            return try await self.call(context) { try $0.accept(id, body) }
        }
        router.post("/v1/suggestions/:id/reject") { [self] request, context in
            let id = context.parameters.get("id") ?? ""
            let body = try await Self.object(request, context)
            return try await self.call(context) { try $0.reject(id, body) }
        }
    }

    /// Runs a task call on the main actor, as every other client of `IronPetAPI` does, and turns its result or error into a response.
    private func call(_ context: RemoteContext, status: Int = 200, _ body: @MainActor (RemoteTasks) throws -> [String: Any]) async throws -> Response {
        guard let device = context.device else { return Self.error(401, "unauthorized", "unauthorized") }
        let api = api
        return await MainActor.run {
            do { return Self.json(status, try body(RemoteTasks(api: api, by: "remote:\(device.id)"))) } catch {
                return Self.errorResponse(RemoteFailure(error))
            }
        }
    }

    // MARK: Event socket

    private func addEventSocket(to router: Router<RemoteContext>) {
        let service = service
        let api = api
        router.ws("/v1/events", shouldUpgrade: { request, _ in
            // The same checks as REST, without counting a failure: a refused upgrade falls through to the REST router, which counts it once.
            let header = request.headers[.authorization]
            guard case .device(let device) = service.authenticate(authorization: header, origin: nil, count: false),
                  service.socketCount(device: device.id) < RemoteService.socketsPerDevice,
                  case .device = service.authenticate(authorization: header, origin: request.headers[.xForwardedFor]) else { return .dontUpgrade }
            service.log(RemoteAccessRow(at: Date(), deviceID: device.id, method: "GET", route: "/v1/events", status: 101, bytes: 0, durationMs: 0))
            return .upgrade([:])
        }) { inbound, outbound, context in
            let request = context.request
            guard case .device(let device) = service.authenticate(authorization: request.headers[.authorization], origin: nil, count: false) else { return }
            let since = request.uri.queryParameters["since"].flatMap { Int($0) }
            let (frames, send) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(2000))
            guard let socket = service.openSocket(device: device.id, close: { send.finish() }) else { return }
            defer { service.socketClosed(socket) }
            let subscription = await MainActor.run { () -> APIEventBus.Subscription in
                let bus = api.events
                send.yield(Self.text(["kind": "hello", "seq": bus.lastSeq]))
                let gap = since.map { bus.replay(after: $0).gap } ?? false
                if gap { send.yield(Self.text(["kind": "resync", "seq": bus.lastSeq])) }
                return bus.subscribe(after: gap ? nil : since) { send.yield(Self.text(Self.describe($0))) }
            }
            defer { Task { @MainActor in subscription.cancel() } }
            // Reading keeps the library answering pings. A close from the device or a revoke ends the stream and with it the socket.
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do { for try await _ in inbound {} } catch {}
                    send.finish()
                }
                group.addTask {
                    for await frame in frames {
                        do { try await outbound.write(.text(frame)) } catch { break }
                    }
                }
                await group.next()
                group.cancelAll()
            }
        }
    }

    // MARK: JSON

    private nonisolated static func describe(_ event: APIEvent) -> [String: Any] {
        var object: [String: Any] = ["seq": event.seq, "at": ISO8601DateFormatter().string(from: event.at), "kind": event.kind.rawValue]
        if let id = event.id { object["id"] = id }
        return object
    }

    private nonisolated static func describe(_ device: RemoteDevice) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var object: [String: Any] = ["id": device.id, "name": device.name, "created": iso.string(from: device.created)]
        if let seen = device.lastSeen { object["last_seen"] = iso.string(from: seen) }
        return object
    }

    private nonisolated static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    private nonisolated static func text(_ object: Any) -> String { String(decoding: data(object), as: UTF8.self) }

    nonisolated static func json(_ status: Int, _ object: Any) -> Response {
        let bytes = data(object)
        return Response(status: .init(code: status), headers: [.contentType: "application/json; charset=utf-8"], body: .init(byteBuffer: ByteBuffer(bytes: bytes)))
    }

    nonisolated static func error(_ status: Int, _ code: String, _ message: String) -> Response {
        json(status, ["error": ["code": code, "message": message]])
    }

    nonisolated static func limited(_ seconds: Int) -> Response {
        var response = error(429, "rate_limited", "too many requests")
        response.headers[.retryAfter] = String(max(1, seconds))
        return response
    }

    /// Everything a route or the router throws becomes `{"error":{"code","message"}}`. Unknown errors say nothing about the cause.
    nonisolated static func errorResponse(_ error: Error) -> Response {
        if let failure = error as? RemoteFailure { return Self.error(failure.status, failure.code, failure.message) }
        if let http = error as? HTTPResponseError {
            let code = http.status.code
            let names = [400: "invalid", 404: "not_found", 405: "method_not_allowed", 413: "too_large", 415: "unsupported", 422: "invalid"]
            return Self.error(Int(code), names[Int(code)] ?? "failed", http.status.reasonPhrase)
        }
        return Self.error(500, "failed", "internal error")
    }

    /// The body as a JSON object. An empty body is an empty object.
    nonisolated static func object(_ request: Request, _ context: RemoteContext) async throws -> [String: Any] {
        let buffer = try await request.body.collect(upTo: context.maxUploadSize)
        guard buffer.readableBytes > 0 else { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(buffer.readableBytesView))) as? [String: Any] else {
            throw RemoteFailure.invalid("the body must be a JSON object")
        }
        return object
    }

    nonisolated static func query(_ request: Request) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (key, value) in request.uri.queryParameters { result[String(key), default: []].append(String(value)) }
        return result
    }
}
