import Foundation

/// Who sent a chat message when it was not typed on the Mac. The chat tells the sender how its turn goes (`ChatAPI.onTurn`),
/// so a client only hears about its own messages.
struct ChatOrigin: Codable, Equatable, Hashable {
    /// The kind of client: `telegram`, `ios`.
    var client: String
    /// The client's own id for the conversation, such as a Telegram chat id or a device id.
    var ref: String

    static let telegramClient = "telegram"
    /// Messages an automation sent into the chat.
    static let automationClient = "automation"
    /// A prompt or follow-up that a background job ran.
    static let jobClient = "job"
    /// Something the user said in voice mode on the Mac.
    static let voiceClient = "voice"

    static func telegram(chat: Int64) -> ChatOrigin { ChatOrigin(client: telegramClient, ref: String(chat)) }
}

typealias ChatItem = ChatSession.Item
typealias ChatReply = ChatSession.Reply
typealias ChatTurnEvent = ChatSession.TurnEvent
typealias ChatApprovalOutcome = ChatSession.ApprovalOutcome

/// A file a remote client sends with a message. The chat saves it on this Mac and hands the agent its path.
struct ChatUpload: Codable, Equatable {
    var fileName: String
    var data: Data
}

/// A message for the open chat.
struct SendChatRequest: Codable, Equatable {
    var text: String
    /// Who is sending. Nil is the Mac's own input box: a missing folder asks for one, a running turn queues the message, and the
    /// reply is read aloud when that is on. Any other sender never changes the chat's thread or folder.
    var origin: ChatOrigin?
    /// Files already on this Mac, such as a screenshot or a file the Mac user dropped.
    var files: [URL] = []
    /// Files the sender carries, saved on this Mac first.
    var uploads: [ChatUpload] = []
    var reply: ChatReply?
}

enum ChatSendOutcome: String, Codable {
    /// The message was empty.
    case ignored
    /// A turn started.
    case sent
    /// The agent was busy, so the message waits its turn.
    case queued
    /// A background job runs in this thread and took the message.
    case toJob
    /// No folder is chosen yet, so nothing was sent. Choose one with `useFolder` or `useNoProject`.
    case needsFolder
}

struct ChatSendResult: Codable, Equatable {
    var outcome: ChatSendOutcome
}

/// Mac messages that were cancelled before they started, handed back so the sender can edit them.
struct ChatRestoredDraft: Codable, Equatable {
    var text: String
    var files: [URL]
    var reply: ChatReply?
}

struct ChatStopResult: Codable, Equatable {
    var restored: ChatRestoredDraft?
}

/// An approval card as a client that cannot draw the Mac's sees it.
struct ChatApprovalInfo: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var detail: String
}

struct DecideApprovalRequest: Codable, Equatable {
    var id: UUID
    var allow: Bool
}

/// A question the agent asked, with what has been entered so far.
struct ChatFormInfo: Codable, Equatable, Identifiable {
    var id: UUID
    var form: ElicitationForm
    var answers: [String: ElicitationValue]
}

struct AnswerFormRequest: Codable, Equatable {
    var id: UUID
    var field: String
    /// Nil clears the answer.
    var value: ElicitationValue?
}

struct ChatQueuedInfo: Codable, Equatable, Identifiable {
    var id: UUID
    var text: String
    var files: [URL]
    var reply: ChatReply?
    /// Typed on this Mac, so a stop gives it back to the draft. Others are told their turn failed.
    var fromMac: Bool
}

struct ChatThreadInfo: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var workspace: String
    var updatedAt: Date
    var agent: String
    /// The automation whose run this thread holds, if any.
    var automation: String?
    var automationName: String?
    /// A voice-mode conversation on the Mac.
    var voice: Bool?

    var isAutomationRun: Bool { automation != nil }
}

struct ChatStatus: Codable, Equatable {
    /// `idle`, `running`, `done` or `failed`.
    var state: String
    var running: Bool
    /// The first message of the open chat, or "New chat".
    var title: String
    var threadID: String?
    var queued: Int
    var pendingApprovals: Int
    var pendingForms: Int
    /// What the agent is doing now, such as "Running `npm test`".
    var activity: String?
    var runStartedAt: Date?
    var lastRunDuration: TimeInterval?
}

struct ChatNamedInfo: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var detail = ""
}

enum ChatCommandKind: String, Codable {
    /// A command the agent offers after a slash.
    case command
    /// A skill the agent offers after a slash. Agents that report skills as commands show as `command`.
    case skill
}

/// One row of the slash popup: what the agent offers after a `/`. A client fetches the list when the user types `/`, then
/// filters and highlights it itself.
struct ChatCommandInfo: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var detail: String
    /// What to type after the name, such as `<path>`.
    var hint: String?
    var kind: ChatCommandKind = .command
}

/// Which agent's commands to list. With `thread`, the agent that thread belongs to; else `agent`; else the open chat's agent.
struct ChatCommandsRequest: Codable, Equatable {
    var thread: String?
    var agent: String?
}

/// Which agent, model and folder the chat runs with, and what is blocking it.
struct ChatOptions: Codable, Equatable {
    var agent: ChatNamedInfo
    var agents: [ChatNamedInfo]
    var model: String?
    var models: [ChatNamedInfo]
    var folder: String?
    var folderLabel: String
    var recentFolders: [String]
    var needsFolder: Bool
    var autoMode: Bool
    /// The agent the chat offers to download a runtime for, or nil.
    var runtimeOffer: String?
    var installingRuntime: Bool
    /// Ways to sign in when the agent asked for it.
    var signInMethods: [ChatNamedInfo]
}

/// Everything a client reads about the chat, at one moment.
struct ChatSnapshot: Codable, Equatable {
    var status: ChatStatus
    var messages: [ChatItem]
    var approvals: [ChatApprovalInfo]
    var forms: [ChatFormInfo]
    var queue: [ChatQueuedInfo]
    var threads: [ChatThreadInfo]
    var options: ChatOptions
}

/// The one shared chat. The Mac's chat view model and the Telegram bridge are two clients of it, and the iOS app will be a third:
/// they send, stop, answer approvals and forms, and open threads through the same calls. Everything here is a `Codable` value or
/// an event on the bus: `chat.item` carries the id of the message that was added or changed (no id means read them all again) and
/// `chat.state` says what else moved (`approvals`, `forms`, `queue`, `draft`, or no id for the turn state). Draft text, the slash
/// popup, find and voice are the Mac window's own state and live in `ChatViewModel`, not here.
@MainActor
final class ChatAPI {
    private let session: ChatSession
    private let uploads: URL
    private var listeners: [UUID: (ChatOrigin, ChatTurnEvent) -> Void] = [:]

    init(session: ChatSession, uploads: URL = FileIntake.directory) {
        self.session = session
        self.uploads = uploads
        session.onTurn = { [weak self] origin, event in
            guard let self else { return }
            for listener in Array(listeners.values) { listener(origin, event) }
        }
    }

    /// The models an agent offered in its last session, kept between runs.
    static func cachedModels(forAgent id: String) -> [ChatNamedInfo] {
        guard let agent = AgentCatalog.agent(id: id) else { return [] }
        return ChatSession.cachedModels(for: agent).map { ChatNamedInfo(id: $0.id, name: $0.name) }
    }

    // MARK: Turns from other clients

    /// Hears how the turns of messages sent with an origin go: queued, started, an approval to answer, the answer, a failure.
    @discardableResult
    func onTurn(_ listener: @escaping (ChatOrigin, ChatTurnEvent) -> Void) -> () -> Void {
        let id = UUID()
        listeners[id] = listener
        return { [weak self] in self?.listeners[id] = nil }
    }

    /// Forgets an origin's queued messages and the answer it was waiting for.
    func cancel(from origin: ChatOrigin) async { session.cancel(from: origin) }

    // MARK: Reading

    /// All the reads at once. It does not wait for anything, so a window can draw its first frame, or a test can check the chat, at once.
    func snapshot() -> ChatSnapshot {
        ChatSnapshot(status: currentStatus, messages: session.items, approvals: currentApprovals, forms: currentForms, queue: currentQueue,
                     threads: currentThreads, options: currentOptions)
    }

    func status() async -> ChatStatus { currentStatus }

    private var currentStatus: ChatStatus {
        ChatStatus(state: Self.name(session.state), running: session.isRunning, title: title, threadID: session.threadID,
                   queued: session.userQueueCount, pendingApprovals: session.approvals.count, pendingForms: session.forms.count,
                   activity: session.activity, runStartedAt: session.runStartedAt, lastRunDuration: session.lastRunDuration)
    }

    /// The open chat's messages, oldest first.
    func messages() async -> [ChatItem] { session.items }

    /// One message, for a client that heard a `chat.item` event with its id.
    func message(_ id: UUID) async throws -> ChatItem {
        guard let item = session.items.first(where: { $0.id == id }) else { throw APIError.notFound("no message with id \"\(id.uuidString)\"") }
        return item
    }

    func approvals() async -> [ChatApprovalInfo] { currentApprovals }
    func forms() async -> [ChatFormInfo] { currentForms }
    func queue() async -> [ChatQueuedInfo] { currentQueue }
    func threads() async -> [ChatThreadInfo] { currentThreads }
    func options() async -> ChatOptions { currentOptions }

    /// The slash commands for an agent, in the agent's order. The list is data: nothing here depends on what the user has typed. The
    /// open chat's agent returns what its session reported last; any other agent returns what was kept from its last session.
    func commands(_ request: ChatCommandsRequest = ChatCommandsRequest()) async throws -> [ChatCommandInfo] {
        var agentID = request.agent ?? session.agent.id
        if let thread = request.thread {
            guard let saved = ThreadStore.load(thread) else { throw APIError.notFound("no thread with id \"\(thread)\"") }
            agentID = saved.agent
        }
        guard AgentCatalog.agent(id: agentID) != nil else { throw APIError.notFound("no agent \"\(agentID)\"") }
        let list = agentID == session.agent.id ? session.commands : SlashCommand.cached(for: agentID)
        return list.map { ChatCommandInfo(name: $0.name, detail: $0.detail, hint: $0.hint, kind: .command) }
    }

    private var currentApprovals: [ChatApprovalInfo] { session.approvals.map { ChatApprovalInfo(id: $0.id, title: $0.title, detail: $0.detail) } }
    private var currentForms: [ChatFormInfo] { session.forms.map { ChatFormInfo(id: $0.id, form: $0.form, answers: $0.answers) } }

    private var currentQueue: [ChatQueuedInfo] {
        session.queue.filter { $0.automation == nil }.map {
            ChatQueuedInfo(id: $0.id, text: $0.text, files: $0.attachments, reply: $0.reply, fromMac: $0.origin == nil)
        }
    }

    private var currentThreads: [ChatThreadInfo] {
        session.history.map { ChatThreadInfo(id: $0.id, title: $0.title, workspace: $0.workspace, updatedAt: $0.updatedAt, agent: $0.agent,
                                             automation: $0.automation, automationName: $0.automationName, voice: $0.voice) }
    }

    private var currentOptions: ChatOptions {
        ChatOptions(agent: Self.info(session.agent), agents: session.agents.map(Self.info), model: session.model,
                    models: session.models.map { ChatNamedInfo(id: $0.id, name: $0.name) }, folder: session.workspace?.path,
                    folderLabel: session.workspaceLabel, recentFolders: session.recents.map(\.path), needsFolder: session.needsWorkspace,
                    autoMode: session.autoMode, runtimeOffer: session.runtimeOffer, installingRuntime: session.installingRuntime,
                    signInMethods: session.signInOptions.map { ChatNamedInfo(id: $0.id, name: $0.name, detail: $0.detail) })
    }

    // MARK: Sending and stopping

    func send(_ request: SendChatRequest) async throws -> ChatSendResult {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = request.files + (try save(request.uploads))
        guard !text.isEmpty || !files.isEmpty else {
            if request.origin == nil { return ChatSendResult(outcome: .ignored) }
            throw APIError.invalid("the message is empty")
        }
        guard let origin = request.origin else {
            return ChatSendResult(outcome: Self.outcome(session.submitLocal(text, files: files, reply: request.reply)))
        }
        let before = session.queue.count
        session.submit(text, from: origin, files: files, reply: request.reply)
        return ChatSendResult(outcome: session.queue.count > before ? .queued : .sent)
    }

    /// Stops the running turn and answers what it cancelled. Queued messages that were typed on the Mac come back as a draft.
    func stop() async -> ChatStopResult {
        session.stop()
        return ChatStopResult(restored: await takeRestoredDraft())
    }

    /// Mac messages that a stop or a failed start cancelled, once. A client hears `chat.state` with the id `draft` when there are some.
    func takeRestoredDraft() async -> ChatRestoredDraft? {
        session.takeRestoredDraft().map { ChatRestoredDraft(text: $0.text, files: $0.attachments, reply: $0.reply) }
    }

    func removeQueued(_ id: UUID) async { session.removeQueued(id) }

    // MARK: Approvals and questions

    /// Allows or denies a tool call, the same as the Allow and Deny buttons on the Mac.
    func decide(_ request: DecideApprovalRequest) async throws {
        guard session.hasPendingApproval(request.id) else { throw APIError.notFound("that approval is no longer waiting") }
        session.decide(id: request.id, allow: request.allow)
    }

    func answerForm(_ request: AnswerFormRequest) async throws {
        guard session.forms.contains(where: { $0.id == request.id }) else { throw APIError.notFound("that question is no longer waiting") }
        session.setAnswer(form: request.id, field: request.field, request.value)
    }

    func submitForm(_ id: UUID) async throws {
        guard let form = session.forms.first(where: { $0.id == id }) else { throw APIError.notFound("that question is no longer waiting") }
        guard form.form.canSubmit(form.answers) else { throw APIError.invalid("a required answer is missing") }
        session.submitForm(id)
    }

    func skipForm(_ id: UUID) async throws {
        guard session.forms.contains(where: { $0.id == id }) else { throw APIError.notFound("that question is no longer waiting") }
        session.skipForm(id)
    }

    // MARK: Threads

    /// Opens a saved thread in the chat, stopping the running turn.
    func openThread(_ id: String) async throws {
        guard let thread = ThreadStore.load(id) else { throw APIError.notFound("no thread with id \"\(id)\"") }
        session.open(thread)
    }

    func newChat() async { session.newChat() }

    // MARK: Agent, model and folder

    func setAgent(_ id: String) async throws {
        guard let agent = session.agents.first(where: { $0.id == id }) ?? AgentCatalog.agent(id: id) else { throw APIError.notFound("no agent \"\(id)\"") }
        guard !session.isRunning else { throw APIError.conflict("the agent is working") }
        session.setAgent(agent)
    }

    /// Nil uses the agent's default model.
    func setModel(_ id: String?) async { session.model = id }

    func setAutoMode(_ on: Bool) async { session.autoMode = on }

    /// Chooses the folder the chat works in. A different folder starts a new chat.
    func useFolder(_ path: String) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw APIError.invalid("\"\(path)\" is not a folder on this Mac")
        }
        session.use(URL(fileURLWithPath: path))
    }

    /// For general questions that are not about a project.
    func useNoProject() async { session.useNoProject() }

    func installRuntime() async { session.installRuntime() }
    func declineRuntime() async { session.declineRuntime() }

    func signIn(_ methodID: String) async throws {
        guard let method = session.signInOptions.first(where: { $0.id == methodID }) else { throw APIError.notFound("no sign-in method \"\(methodID)\"") }
        session.signIn(method)
    }

    func retryAfterFix() async { session.retryAfterFix() }

    // MARK: Notices

    /// Adds an error line to the transcript, such as a voice note that could not be transcribed. Returns its id.
    func addNotice(_ message: String) async -> UUID { session.appendNotice(message) }

    func removeMessage(_ id: UUID) async { session.removeItem(id) }

    // MARK: Helpers

    private var title: String {
        guard let first = session.items.lazy.compactMap({ item -> String? in
            if case .user(let text) = item.kind { return text } else { return nil }
        }).first else { return "New chat" }
        return first.count > 60 ? String(first.prefix(57)) + "…" : first
    }

    private func save(_ uploads: [ChatUpload]) throws -> [URL] {
        guard !uploads.isEmpty else { return [] }
        try FileManager.default.createDirectory(at: self.uploads, withIntermediateDirectories: true)
        return try uploads.map { upload in
            // A file name only: a remote client must not choose where on this Mac the file lands.
            let name = (upload.fileName as NSString).lastPathComponent
            let url = self.uploads.appendingPathComponent("\(UUID().uuidString.prefix(8))-" + (name.isEmpty ? "file" : name))
            try upload.data.write(to: url)
            return url
        }
    }

    private static func info(_ agent: ACPAgent) -> ChatNamedInfo { ChatNamedInfo(id: agent.id, name: agent.name) }

    private static func name(_ state: ChatSession.State) -> String {
        switch state {
        case .idle: return "idle"
        case .running: return "running"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    private static func outcome(_ send: ChatSession.LocalSend) -> ChatSendOutcome {
        switch send {
        case .ignored: return .ignored
        case .sent: return .sent
        case .queued: return .queued
        case .toJob: return .toJob
        case .needsFolder: return .needsFolder
        }
    }
}
