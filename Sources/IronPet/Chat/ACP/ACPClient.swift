import Foundation

typealias JSON = [String: Any]

/// A JSON-RPC error from the agent, or a transport failure (code -1).
struct ACPError: Error, LocalizedError {
    let code: Int
    let message: String
    let data: Any?

    init(code: Int, message: String, data: Any? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    /// ACP reports a missing sign-in as `auth_required`, JSON-RPC code -32000. Some agents use the same code for other
    /// failures (Gemini does for "this client is no longer supported"), so the message has to talk about signing in too.
    var isAuthRequired: Bool {
        guard code == -32000 else { return false }
        let text = message.lowercased()
        return ["auth", "sign in", "sign-in", "log in", "login", "credential"].contains { text.contains($0) }
    }
    var errorDescription: String? { message }
}

/// Newline-delimited bytes to and from an agent. Callbacks arrive on the main queue.
protocol ACPTransport: AnyObject {
    func start(onData: @escaping (Data) -> Void, onClose: @escaping (String?) -> Void) throws
    func send(_ data: Data)
    func close()
}

/// JSON-RPC 2.0 over newline-delimited JSON, with requests in both directions. Declares no `fs` or `terminal`
/// client capability, so agents keep using their own tools.
@MainActor
final class ACPClient {
    private let transport: ACPTransport
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var buffer = Data()
    private(set) var isClosed = false

    /// `session/update` and other notifications from the agent, in arrival order.
    var onNotification: ((String, JSON) -> Void)?
    /// A request from the agent. Call `respond` exactly once.
    var onRequest: ((String, JSON, @escaping (Result<JSON, ACPError>) -> Void) -> Void)?
    /// The transport ended. The argument is the agent's stderr tail, if any.
    var onClose: ((String?) -> Void)?

    init(transport: ACPTransport) {
        self.transport = transport
    }

    func start() throws {
        try transport.start(
            onData: { [weak self] data in MainActor.assumeIsolated { self?.receive(data) } },
            onClose: { [weak self] message in MainActor.assumeIsolated { self?.closed(message) } })
    }

    func close() {
        transport.close()
        closed(nil)
    }

    func request(_ method: String, _ params: JSON = [:]) async throws -> JSON {
        guard !isClosed else { throw ACPError(code: -1, message: "The agent is not running") }
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        }
    }

    func notify(_ method: String, _ params: JSON = [:]) {
        guard !isClosed else { return }
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func write(_ object: JSON) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        transport.send(data)
    }

    /// Feeds bytes from the agent. Lines can arrive split across reads or several to a read.
    func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty, let object = (try? JSONSerialization.jsonObject(with: line)) as? JSON else { continue }
            dispatch(object)
        }
    }

    private func dispatch(_ message: JSON) {
        let id = message["id"]
        if let method = message["method"] as? String {
            let params = message["params"] as? JSON ?? [:]
            guard let id else {
                onNotification?(method, params)
                return
            }
            guard let onRequest else {
                reply(id, .failure(ACPError(code: -32601, message: "Method not found: \(method)")))
                return
            }
            onRequest(method, params) { [weak self] result in self?.reply(id, result) }
            return
        }
        guard let number = (id as? Int) ?? (id as? Double).map(Int.init), let continuation = pending.removeValue(forKey: number) else { return }
        if let error = message["error"] as? JSON {
            continuation.resume(throwing: ACPError(code: error["code"] as? Int ?? -1, message: error["message"] as? String ?? "Agent error",
                                                   data: error["data"]))
        } else {
            continuation.resume(returning: message["result"] as? JSON ?? [:])
        }
    }

    private func reply(_ id: Any, _ result: Result<JSON, ACPError>) {
        guard !isClosed else { return }
        switch result {
        case .success(let value):
            write(["jsonrpc": "2.0", "id": id, "result": value])
        case .failure(let error):
            write(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
        }
    }

    private func closed(_ message: String?) {
        guard !isClosed else { return }
        isClosed = true
        let failure = ACPError(code: -1, message: message.flatMap { $0.isEmpty ? nil : $0 } ?? "The agent stopped")
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0.resume(throwing: failure) }
        onClose?(message)
    }
}

/// Runs the agent as a child process and talks to its stdin and stdout.
final class ACPProcessTransport: ACPTransport {
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let directory: URL?
    private var process: Process?
    private var input: FileHandle?
    private var stderr = Data()

    var processID: Int32? { process?.processIdentifier }

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL?) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }

    func start(onData: @escaping (Data) -> Void, onClose: @escaping (String?) -> Void) throws {
        // Writing to an agent that already exited raises SIGPIPE, which would end the app. The write then fails with EPIPE instead.
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return handle.readabilityHandler = nil }
            DispatchQueue.main.async { onData(data) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                guard let self else { return }
                self.stderr.append(data)
                if self.stderr.count > 8_192 { self.stderr = Data(self.stderr.suffix(8_192)) }
            }
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            // Let the readers drain what the agent printed before it exited.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let tail = self.map { String(decoding: $0.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                onClose(tail.isEmpty ? "The agent exited with status \(status)" : tail)
            }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
    }

    func send(_ data: Data) {
        try? input?.write(contentsOf: data)
    }

    func close() {
        try? input?.close()
        process?.terminate()
    }
}
