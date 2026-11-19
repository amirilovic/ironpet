import Combine
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

    static func telegram(chat: Int64) -> ChatOrigin { ChatOrigin(client: telegramClient, ref: String(chat)) }
}

extension ChatAPI {
    /// The models an agent offered in its last session, kept between runs.
    static func cachedModels(for agent: ACPAgent) -> [ChatModel] { ChatSession.cachedModels(for: agent) }
}

typealias ChatItem = ChatSession.Item
typealias ChatReply = ChatSession.Reply
typealias ChatApproval = ChatSession.Approval
typealias ChatPendingForm = ChatSession.PendingForm
typealias ChatQueuedMessage = ChatSession.QueuedMessage
typealias ChatTurnEvent = ChatSession.TurnEvent
typealias ChatApprovalOutcome = ChatSession.ApprovalOutcome

/// A message from a client other than the Mac's own input box.
struct SendChatRequest: Codable, Equatable {
    var text: String
    var origin: ChatOrigin
    /// Files saved on this Mac that go with the message.
    var attachments: [URL] = []
    var reply: ChatReply?
}

/// An approval card as a client that cannot draw the Mac's sees it.
struct ChatApprovalInfo: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var detail: String
}

struct ChatThreadInfo: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var workspace: String
    var updatedAt: Date
    var agent: String
    /// The automation whose run this thread holds, if any.
    var automation: String?
}

struct DecideApprovalRequest: Codable, Equatable {
    var id: UUID
    var allow: Bool
}

struct ChatStatus: Codable, Equatable {
    var running: Bool
    /// The first message of the open chat, or "New chat".
    var title: String
    var queued: Int
    var pendingApprovals: Int
}

/// The one shared chat. The Mac's chat view and the Telegram bridge are two clients of it: they send, stop, queue, answer
/// approvals and forms, and open threads through the same calls. The draft in the Mac's input box is shared state too.
///
/// This is an `ObservableObject` so the SwiftUI chat view redraws as the transcript streams in.
@MainActor
final class ChatAPI: ObservableObject {
    private let session: ChatSession
    private var forwarding: AnyCancellable?
    private var listeners: [UUID: (ChatOrigin, ChatTurnEvent) -> Void] = [:]

    init(session: ChatSession) {
        self.session = session
        forwarding = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        session.onTurn = { [weak self] origin, event in
            guard let self else { return }
            for listener in Array(listeners.values) { listener(origin, event) }
        }
    }

    // MARK: Turns from other clients

    /// Hears how the turns of messages sent with `send` go: queued, started, an approval to answer, the answer, a failure.
    @discardableResult
    func onTurn(_ listener: @escaping (ChatOrigin, ChatTurnEvent) -> Void) -> () -> Void {
        let id = UUID()
        listeners[id] = listener
        return { [weak self] in self?.listeners[id] = nil }
    }

    /// Sends a message into the open chat as `origin`. It never changes the chat's thread or folder, and a busy agent queues it.
    func send(_ request: SendChatRequest) throws {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !request.attachments.isEmpty else { throw APIError.invalid("the message is empty") }
        session.submit(text, from: request.origin, files: request.attachments, reply: request.reply)
    }

    /// Forgets an origin's queued messages and the answer it was waiting for.
    func cancel(from origin: ChatOrigin) { session.cancel(from: origin) }

    // MARK: Reading

    var status: ChatStatus {
        ChatStatus(running: session.isRunning, title: title, queued: session.userQueueCount, pendingApprovals: session.approvals.count)
    }

    /// The first message of the open chat, or "New chat".
    var title: String {
        guard let first = session.items.lazy.compactMap({ item -> String? in
            if case .user(let text) = item.kind { return text } else { return nil }
        }).first else { return "New chat" }
        return first.count > 60 ? String(first.prefix(57)) + "…" : first
    }

    /// The open chat's messages, oldest first.
    func transcript() -> [ChatItem] { session.items }

    func approvalList() -> [ChatApprovalInfo] { session.approvals.map { ChatApprovalInfo(id: $0.id, title: $0.title, detail: $0.detail) } }

    func hasPendingApproval(_ id: UUID) -> Bool { session.hasPendingApproval(id) }

    func threads() -> [ChatThreadInfo] {
        session.history.map { ChatThreadInfo(id: $0.id, title: $0.title, workspace: $0.workspace, updatedAt: $0.updatedAt, agent: $0.agent,
                                             automation: $0.automation) }
    }

    // MARK: Changing

    func stop() { session.stop() }

    /// Allows or denies a tool call, the same as the Allow and Deny buttons on the Mac.
    func decide(_ request: DecideApprovalRequest) throws {
        guard session.hasPendingApproval(request.id) else { throw APIError.notFound("that approval is no longer waiting") }
        session.decide(id: request.id, allow: request.allow)
    }

    /// Opens a saved thread in the chat, stopping the running turn.
    func openThread(_ id: String) throws {
        guard let thread = ThreadStore.load(id) else { throw APIError.notFound("no thread with id \"\(id)\"") }
        session.open(thread)
    }

    /// Opens a saved thread that is already loaded, such as one from `history`.
    func open(_ thread: ChatThread) { session.open(thread) }

    func newChat() { session.newChat() }

    func removeQueued(_ id: UUID) { session.removeQueued(id) }

    // MARK: The Mac's draft and chat controls

    var items: [ChatItem] { session.items }
    var isRunning: Bool { session.isRunning }
    var queue: [ChatQueuedMessage] { session.queue }
    var approvals: [ChatApproval] { session.approvals }
    var forms: [ChatPendingForm] { session.forms }
    /// Saved threads, newest first.
    var history: [ChatThread] { session.history }
    var runStartedAt: Date? { session.runStartedAt }
    var input: String { get { session.input } set { session.input = newValue } }
    var attachments: [URL] { get { session.attachments } set { session.attachments = newValue } }
    var replyingTo: ChatReply? { get { session.replyingTo } set { session.replyingTo = newValue } }
    var replyFocusTick: Int { session.replyFocusTick }
    var findOpen: Bool { get { session.findOpen } set { session.findOpen = newValue } }
    var findFocusTick: Int { get { session.findFocusTick } set { session.findFocusTick = newValue } }
    var fileDragActive: Bool { get { session.fileDragActive } set { session.fileDragActive = newValue } }
    var autoMode: Bool { get { session.autoMode } set { session.autoMode = newValue } }
    var sendAfterDictation: Bool { get { session.sendAfterDictation } set { session.sendAfterDictation = newValue } }
    var slash: SlashPopupState { get { session.slash } set { session.slash = newValue } }
    var slashMatches: [SlashCommand] { session.slashMatches }

    @discardableResult func completeSlash() -> Bool { session.completeSlash() }
    func completeSlash(_ command: SlashCommand) { session.completeSlash(command) }
    func moveSlashSelection(_ delta: Int) { session.moveSlashSelection(delta) }
    @discardableResult func dismissSlash() -> Bool { session.dismissSlash() }
    func inputChanged(from old: String, to new: String) { session.inputChanged(from: old, to: new) }

    /// Sends the draft in the input box, with its attachments and reply.
    func sendDraft() { session.send() }
    func attach(_ screenshot: URL) { session.attach(screenshot) }
    func attach(_ files: [URL]) { session.attach(files) }
    func reply(to item: ChatItem, selection: String? = nil) { session.reply(to: item, selection: selection) }
    func decide(_ approval: ChatApproval, allow: Bool) { session.decide(approval, allow: allow) }

    func setAnswer(form id: UUID, field: String, _ value: ElicitationValue?) { session.setAnswer(form: id, field: field, value) }
    func submitForm(_ id: UUID) { session.submitForm(id) }
    func skipForm(_ id: UUID) { session.skipForm(id) }

    // The folder, agent and model the chat runs with.
    var workspace: URL? { session.workspace }
    var workspaceLabel: String { session.workspaceLabel }
    var needsWorkspace: Bool { session.needsWorkspace }
    var recents: [URL] { session.recents }
    func use(_ url: URL) { session.use(url) }
    func useNoProject() { session.useNoProject() }
    var agent: ACPAgent { session.agent }
    var agents: [ACPAgent] { session.agents }
    func setAgent(_ next: ACPAgent) { session.setAgent(next) }
    var models: [ChatModel] { session.models }
    var model: String? { get { session.model } set { session.model = newValue } }
    var modelName: String { session.modelName }
    var runtimeOffer: String? { session.runtimeOffer }
    var installingRuntime: Bool { session.installingRuntime }
    var signInOptions: [AuthMethod] { session.signInOptions }
    func installRuntime() { session.installRuntime() }
    func declineRuntime() { session.declineRuntime() }
    func signIn(_ method: AuthMethod) { session.signIn(method) }
    func retryAfterFix() { session.retryAfterFix() }

    // Voice, until the voice API replaces it.
    var voice: VoiceController { session.voice }
    var speech: SpeechPlayer { session.speech }
    /// The chat message being read aloud, so its speaker button shows Stop.
    var speakingID: UUID? { session.speech.speakingID }
    /// Whether the mic is recording or transcribing.
    var voiceBusy: Bool { session.voice.isBusy }
    /// Whether a reply is being read aloud.
    var isSpeaking: Bool { session.speech.isSpeaking }
    func stopSpeech() { session.speech.stop() }
    var voiceRetryItem: UUID? { session.voiceRetryItem }
    func toggleSpeech(_ item: ChatItem) { session.toggleSpeech(item) }
    func retryVoice() { session.retryVoice() }
}
