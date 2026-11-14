import Foundation

struct ChatModel: Identifiable, Hashable {
    let id: String
    let name: String

    /// Menu group: "Claude Opus", "Claude Sonnet", "GPT-5.6", "Grok", …
    var family: String {
        let words = name.split(separator: " ")
        guard let first = words.first else { return "Other" }
        if first == "Claude", words.count > 1 { return "Claude \(words[1])" }
        if first == "Auto" { return "Auto" }
        return String(first)
    }
}

/// How the user can sign in to an agent, from `authMethods` in the `initialize` result.
struct AuthMethod: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    /// "agent" (call `authenticate`) or "terminal" (run the agent's command with `args` in a terminal).
    let type: String
    let args: [String]
    let env: [String: String]

    init(json: JSON) {
        id = json["id"] as? String ?? ""
        name = json["name"] as? String ?? "Sign in"
        detail = json["description"] as? String ?? ""
        type = json["type"] as? String ?? "agent"
        args = json["args"] as? [String] ?? []
        env = json["env"] as? [String: String] ?? [:]
    }
}

enum AgentEvent {
    case session(String)
    case models(current: String?, [ChatModel])
    case assistant(String)
    case toolStarted(id: String, summary: String)
    case toolUpdated(id: String, summary: String)
    case toolFinished(id: String, ok: Bool)
    /// The agent needs a sign-in before it can run.
    case needsSignIn([AuthMethod])
    /// The adapter has no JS runtime to run on until the user allows the Bun download.
    case needsRuntime
    case finished(error: String?)
}

struct ApprovalDecision {
    let allow: Bool
    let message: String

    static let allow = ApprovalDecision(allow: true, message: "Approved in ironpet")
    static func deny(_ message: String = "The user denied this in ironpet") -> ApprovalDecision {
        ApprovalDecision(allow: false, message: message)
    }
}

struct ACPTurn {
    let prompt: String
    /// Context for the first turn of a new session (memory notes). Not sent when a session is resumed.
    let preamble: String?
    let workspace: URL
    /// Session to resume with `session/load` when this backend has none yet.
    let resume: String?
    let model: String?
    let images: [URL]
    let files: [URL]
}

/// Why an agent could not be started.
enum ACPLaunchError: LocalizedError {
    case cliMissing(String)
    case adapterMissing(String)
    case runtimeMissing
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .cliMissing(let command): return "\(command) was not found. Install it, then try again."
        case .adapterMissing(let adapter): return "The \(adapter) adapter is missing from this build of ironpet."
        case .runtimeMissing: return "ironpet needs Node 22 or a downloaded Bun to run this agent."
        case .timedOut(let what): return "The agent did not answer \(what) in time."
        }
    }
}

/// Drives one agent over ACP. The process lives across turns, so a chat keeps one session and Stop only cancels the turn.
@MainActor
final class ACPBackend {
    let agent: ACPAgent
    private(set) var sessionID: String?
    private(set) var capabilities: JSON = [:]
    private(set) var authMethods: [AuthMethod] = []

    /// A restricted run gets only its own working folder: no memory or screenshot folders. Meeting summaries use it.
    var restricted = false

    /// Called when the agent asks to run something. Answer once.
    var onPermission: ((ACPToolCall, @escaping (ApprovalDecision) -> Void) -> Void)?

    private var client: ACPClient?
    private var transport: ACPProcessTransport?
    private var sessionReady = false
    private var freshSession = false
    private var replaying = false
    private var promptInFlight = false
    /// Counts prompts, so the cancel watchdog only acts on the prompt it was started for.
    private var promptCount = 0
    private var onEvent: ((AgentEvent) -> Void)?
    private var tools: [String: ACPToolCall] = [:]
    private var finishedTools: Set<String> = []
    private var pendingPermissions: [UUID: (Result<JSON, ACPError>) -> Void] = [:]
    private var models: [ChatModel] = []
    private var currentModel: String?
    private var modelConfigID: String?
    private var timedOut = false

    var processID: Int32? { transport?.processID }
    /// The model the session is using, as the agent last reported or accepted it.
    var activeModel: String? { currentModel }

    init(agent: ACPAgent) {
        self.agent = agent
    }

    // MARK: Turns

    /// Runs one prompt. Reports through `onEvent` and never throws: failures arrive as `.finished(error:)`,
    /// `.needsSignIn` or `.needsRuntime`.
    func runTurn(_ turn: ACPTurn, onEvent: @escaping (AgentEvent) -> Void) async {
        // A cancelled turn can still be winding down. Wait for it, but never longer than the cancel watchdog allows.
        for _ in 0..<60 where promptInFlight { try? await Task.sleep(nanoseconds: 100_000_000) }
        self.onEvent = onEvent
        do {
            try await connect(turn.workspace)
            try await ensureSession(turn)
            await applyModel(turn.model)
            let blocks = promptBlocks(turn)
            guard let client, let sessionID else { throw ACPError(code: -1, message: "The agent stopped") }
            promptInFlight = true
            promptCount += 1
            defer { promptInFlight = false }
            let result = try await client.request("session/prompt", ["sessionId": sessionID, "prompt": blocks])
            emit(.finished(error: result["stopReason"] as? String == "refusal" ? "The agent declined this request." : nil))
        } catch ACPLaunchError.runtimeMissing {
            emit(.needsRuntime)
        } catch let error as ACPError where error.isAuthRequired {
            emit(.needsSignIn(authMethods))
        } catch {
            emit(.finished(error: describe(error)))
        }
    }

    /// Stop: tells the agent to end the turn and keeps its process for the next message.
    func cancel() {
        onEvent = nil
        guard let client, !client.isClosed else { return }
        if let sessionID { client.notify("session/cancel", ["sessionId": sessionID]) }
        let waiting = pendingPermissions
        pendingPermissions = [:]
        waiting.values.forEach { $0(.success(["outcome": ["outcome": "cancelled"]])) }
        guard promptInFlight else { return }
        // An agent that ignores the cancel would block the chat. After five seconds, restart it on the next message.
        // A later prompt on the same process is not the one that was cancelled, so it is left alone.
        let cancelled = promptCount
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.promptInFlight, self.promptCount == cancelled else { return }
            self.shutdown()
        }
    }

    func shutdown() {
        client?.close()
        client = nil
        transport = nil
        sessionReady = false
    }

    func authenticate(_ method: AuthMethod) async throws {
        try await connect(nil)
        guard let client else { return }
        _ = try await client.request("authenticate", ["methodId": method.id])
    }

    // MARK: Connection

    private func emit(_ event: AgentEvent) {
        onEvent?(event)
    }

    private func describe(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if timedOut { return "The agent did not answer in time. \(text)" }
        return text
    }

    private func connect(_ workspace: URL?) async throws {
        if let client, !client.isClosed { return }
        client = nil
        sessionReady = false
        timedOut = false
        let launch = try Self.launch(for: agent)
        let transport = ACPProcessTransport(executable: launch.executable, arguments: launch.arguments, environment: launch.environment,
                                            directory: workspace)
        let client = ACPClient(transport: transport)
        client.onNotification = { [weak self] method, params in self?.notification(method, params) }
        client.onRequest = { [weak self] method, params, respond in self?.agentRequest(method, params, respond) }
        client.onClose = { [weak self, weak client] _ in
            guard let self, self.client === client else { return }
            self.sessionReady = false
        }
        try client.start()
        self.client = client
        self.transport = transport
        logCLIVersion()
        do {
            let result = try await guarded(client, seconds: 60) {
                try await client.request("initialize", ["protocolVersion": 1, "clientCapabilities": JSON(),
                                                          "clientInfo": ["name": "ironpet", "title": "ironpet", "version": "0.1.0"]])
            }
            capabilities = result["agentCapabilities"] as? JSON ?? [:]
            authMethods = (result["authMethods"] as? [JSON] ?? []).map(AuthMethod.init(json:))
        } catch {
            client.close()
            self.client = nil
            throw error
        }
    }

    /// Closes the connection if `body` runs too long, which fails its pending request with a clear message.
    private func guarded<T>(_ client: ACPClient, seconds: Double, _ body: () async throws -> T) async throws -> T {
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.timedOut = true
            client.close()
        }
        defer { watchdog.cancel() }
        return try await body()
    }

    struct Launch {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    static func launch(for agent: ACPAgent) throws -> Launch {
        var env = LoginShell.environment()
        // Cursor and Claude Code run ironpet's status hooks for chats started here too. The hook script skips this run.
        env["IRONPET_ACP_RUN"] = "1"
        guard let cli = LoginShell.find(agent.command) else { throw ACPLaunchError.cliMissing(agent.command) }
        guard let helper = agent.helper else {
            return Launch(executable: cli, arguments: agent.args, environment: env)
        }
        guard let adapter = ACPRuntime.adapterFile(helper.adapter) else { throw ACPLaunchError.adapterMissing(helper.adapter) }
        guard let runtime = ACPRuntime.resolve(adapter: helper.adapter) else { throw ACPLaunchError.runtimeMissing }
        env[helper.pathVariable] = cli.path
        return Launch(executable: runtime.executable, arguments: [adapter.path] + agent.args, environment: env)
    }

    private static var loggedVersions = Set<String>()

    /// Adapters pin one SDK version while the user's CLI can be older or newer, so the version belongs in the log.
    private func logCLIVersion() {
        guard agent.viaHelper, Self.loggedVersions.insert(agent.command).inserted, let cli = LoginShell.find(agent.command) else { return }
        let name = agent.command
        Task.detached {
            let process = Process()
            process.executableURL = cli
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            NSLog("ironpet: \(name) --version: \(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // MARK: Sessions

    private func ensureSession(_ turn: ACPTurn) async throws {
        guard let client else { throw ACPError(code: -1, message: "The agent stopped") }
        if sessionReady, sessionID != nil { return }
        var params: JSON = ["cwd": turn.workspace.path, "mcpServers": [JSON]()]
        let sessionCapabilities = capabilities["sessionCapabilities"] as? JSON ?? [:]
        if sessionCapabilities["additionalDirectories"] != nil, !restricted {
            for dir in [Memory.directory, ScreenCapture.directory] { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            params["additionalDirectories"] = [Memory.directory.path, ScreenCapture.directory.path]
        }
        if let existing = sessionID ?? turn.resume, capabilities["loadSession"] as? Bool == true {
            sessionID = existing
            replaying = true
            defer { replaying = false }
            do {
                var load = params
                load["sessionId"] = existing
                let result = try await guarded(client, seconds: 60) { try await client.request("session/load", load) }
                await useAskingMode(result)
                readModels(result)
                sessionReady = true
                freshSession = false
                return
            } catch let error as ACPError where error.isAuthRequired || client.isClosed {
                throw error
            } catch {
                NSLog("ironpet: \(agent.name) could not load session \(existing): \(error.localizedDescription). Starting a new one.")
                sessionID = nil
            }
        }
        let result = try await guarded(client, seconds: 60) { try await client.request("session/new", params) }
        guard let id = result["sessionId"] as? String else { throw ACPError(code: -1, message: "The agent did not return a session") }
        sessionID = id
        sessionReady = true
        freshSession = true
        emit(.session(id))
        await useAskingMode(result)
        readModels(result)
    }

    /// Modes that approve tools without asking. Auto mode belongs to ironpet: the agent stays in a mode that asks, and
    /// ironpet answers its requests, so a "bypass permissions" default in the user's own agent settings must not apply.
    nonisolated static let permissiveModes: Set<String> = ["bypassPermissions", "acceptEdits", "yolo", "autoEdit", "full-access", "dontAsk"]

    /// The mode to switch to, or nil to leave the session alone.
    nonisolated static func askingMode(current: String?, available: [String]) -> String? {
        guard let current else { return nil }
        let permissive = permissiveModes.contains(current) || (current == "auto" && available.contains("default"))
        guard permissive else { return nil }
        return ["default", "auto"].first { available.contains($0) && $0 != current }
    }

    private func useAskingMode(_ result: JSON) async {
        guard let client, let sessionID, let block = result["modes"] as? JSON,
              let target = Self.askingMode(current: block["currentModeId"] as? String,
                                           available: (block["availableModes"] as? [JSON] ?? []).compactMap { $0["id"] as? String }) else { return }
        do {
            _ = try await client.request("session/set_mode", ["sessionId": sessionID, "modeId": target])
        } catch {
            NSLog("ironpet: could not switch \(agent.name) to its asking mode \(target): \(error.localizedDescription). It may run tools without asking.")
        }
    }

    private func readModels(_ result: JSON) {
        models = []
        modelConfigID = nil
        if let block = result["models"] as? JSON, let list = block["availableModels"] as? [JSON] {
            models = list.compactMap { item in
                guard let id = item["modelId"] as? String else { return nil }
                return ChatModel(id: id, name: item["name"] as? String ?? id)
            }
            currentModel = block["currentModelId"] as? String
        } else if let options = result["configOptions"] as? [JSON],
                  let option = options.first(where: { $0["category"] as? String == "model" || $0["id"] as? String == "model" }) {
            modelConfigID = option["id"] as? String
            currentModel = option["currentValue"] as? String
            let entries = option["options"] as? [JSON] ?? []
            models = entries.flatMap { entry -> [JSON] in (entry["options"] as? [JSON]) ?? [entry] }.compactMap { item in
                guard let id = item["value"] as? String else { return nil }
                return ChatModel(id: id, name: item["name"] as? String ?? id)
            }
        }
        emit(.models(current: currentModel, models))
    }

    private func applyModel(_ wanted: String?) async {
        guard let client, let sessionID, let wanted, wanted != currentModel, models.contains(where: { $0.id == wanted }) else { return }
        do {
            if let modelConfigID {
                _ = try await client.request("session/set_config_option", ["sessionId": sessionID, "configId": modelConfigID, "value": wanted])
            } else {
                _ = try await client.request("session/set_model", ["sessionId": sessionID, "modelId": wanted])
            }
            currentModel = wanted
        } catch {
            NSLog("ironpet: could not switch \(agent.name) to \(wanted): \(error.localizedDescription)")
        }
    }

    // MARK: Prompt

    private func promptBlocks(_ turn: ACPTurn) -> [JSON] {
        var context: [String] = []
        var blocks: [JSON] = []
        let canSendImages = (capabilities["promptCapabilities"] as? JSON)?["image"] as? Bool == true
        var pathOnly: [URL] = []
        for image in turn.images {
            if canSendImages, let block = Self.imageBlock(image) { blocks.append(block) } else { pathOnly.append(image) }
        }
        if !pathOnly.isEmpty {
            context.append("Screenshot\(pathOnly.count > 1 ? "s" : "") of my screen (open and look at \(pathOnly.count > 1 ? "them" : "it") first): "
                + pathOnly.map(\.path).joined(separator: ", "))
        }
        if !turn.files.isEmpty {
            context.append("Attached file\(turn.files.count > 1 ? "s" : "") (read \(turn.files.count > 1 ? "them" : "it") first): "
                + turn.files.map(\.path).joined(separator: ", "))
        }
        var text = turn.prompt
        if !context.isEmpty { text = context.joined(separator: "\n") + "\n\n" + text }
        if freshSession, let preamble = turn.preamble { text = preamble + "\n" + text }
        freshSession = false
        return [["type": "text", "text": text]] + blocks
    }

    nonisolated static func imageBlock(_ url: URL) -> JSON? {
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
        guard let mime = types[url.pathExtension.lowercased()], let data = try? Data(contentsOf: url), data.count < 20_000_000 else { return nil }
        return ["type": "image", "data": data.base64EncodedString(), "mimeType": mime]
    }

    // MARK: Agent to client

    private func notification(_ method: String, _ params: JSON) {
        guard method == "session/update", params["sessionId"] as? String == sessionID, !replaying,
              let update = params["update"] as? JSON else { return }
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            if let content = update["content"] as? JSON, content["type"] as? String == "text", let text = content["text"] as? String, !text.isEmpty {
                emit(.assistant(text))
            }
        case "tool_call":
            let call = ACPToolCall(json: update)
            tools[call.id] = call
            emit(.toolStarted(id: call.id, summary: call.summary))
            finishIfDone(update, call)
        case "tool_call_update":
            guard let id = update["toolCallId"] as? String else { return }
            var call = tools[id] ?? ACPToolCall(id: id)
            let before = call.summary
            call.merge(update)
            tools[id] = call
            if call.summary != before, !finishedTools.contains(id) { emit(.toolUpdated(id: id, summary: call.summary)) }
            finishIfDone(update, call)
        default:
            break
        }
    }

    private func finishIfDone(_ update: JSON, _ call: ACPToolCall) {
        guard let status = update["status"] as? String, status == "completed" || status == "failed", finishedTools.insert(call.id).inserted else { return }
        emit(.toolFinished(id: call.id, ok: status == "completed"))
    }

    private func agentRequest(_ method: String, _ params: JSON, _ respond: @escaping (Result<JSON, ACPError>) -> Void) {
        guard method == "session/request_permission" else {
            return respond(.failure(ACPError(code: -32601, message: "ironpet does not provide \(method)")))
        }
        var call = ACPToolCall(json: params["toolCall"] as? JSON ?? [:])
        // The permission request often omits the arguments that the earlier tool_call carried.
        if let known = tools[call.id] {
            var merged = known
            merged.merge(params["toolCall"] as? JSON ?? [:])
            call = merged
        }
        let options = params["options"] as? [JSON] ?? []
        guard let onPermission else { return respond(.success(Self.outcome(.deny("ironpet is not ready"), options: options))) }
        let token = UUID()
        pendingPermissions[token] = respond
        onPermission(call) { [weak self] decision in
            guard let self, let pending = self.pendingPermissions.removeValue(forKey: token) else { return }
            pending(.success(Self.outcome(decision, options: options)))
        }
    }

    /// Picks the offered option that matches the decision: allow_once or reject_once first.
    nonisolated static func outcome(_ decision: ApprovalDecision, options: [JSON]) -> JSON {
        let wanted = decision.allow ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
        for kind in wanted {
            if let option = options.first(where: { $0["kind"] as? String == kind }), let id = option["optionId"] as? String {
                return ["outcome": ["outcome": "selected", "optionId": id]]
            }
        }
        return ["outcome": ["outcome": "cancelled"]]
    }
}

/// Which catalog agents the user has and which of them speak ACP.
enum ACPProbe {
    private static var answered: [String: Bool] = [:]

    /// Native agents must answer `initialize`; adapter-backed agents count as present when their CLI is installed,
    /// because the adapter answers for them.
    @MainActor
    static func installed() async -> [ACPAgent] {
        let present = AgentCatalog.present()
        var result: [ACPAgent] = []
        await withTaskGroup(of: (ACPAgent, Bool).self) { group in
            for agent in present {
                if agent.viaHelper { result.append(agent); continue }
                group.addTask { (agent, await answersInitialize(agent)) }
            }
            for await (agent, ok) in group where ok { result.append(agent) }
        }
        return AgentCatalog.all.filter { agent in result.contains { $0.id == agent.id } }
    }

    @MainActor
    static func answersInitialize(_ agent: ACPAgent) async -> Bool {
        guard let exe = LoginShell.find(agent.command) else { return false }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: exe.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(exe.path):\(stamp)"
        if let known = answered[key] { return known }
        var env = LoginShell.environment()
        env["IRONPET_ACP_RUN"] = "1"
        let transport = ACPProcessTransport(executable: exe, arguments: agent.args, environment: env, directory: FileManager.default.temporaryDirectory)
        let client = ACPClient(transport: transport)
        guard (try? client.start()) != nil else { return false }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled { client.close() }
        }
        defer { watchdog.cancel(); client.close() }
        let ok = (try? await client.request("initialize", ["protocolVersion": 1, "clientCapabilities": JSON()])) != nil
        if ok { answered[key] = true }
        return ok
    }
}
