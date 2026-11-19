import Combine
import Foundation

/// The Mac chat window's side of the chat: the state that belongs to this window and no other client (the draft being typed, the
/// attachments waiting to go, the message being replied to, the slash popup, the find bar, a file drag, the microphone), plus a copy of
/// the shared chat that it keeps current from `ChatAPI` and the event bus. It talks to the chat only through `ChatAPI` and
/// `VoiceAPI`, as the iOS app will.
@MainActor
final class ChatViewModel: ObservableObject {
    let api: ChatAPI
    let voiceAPI: VoiceAPI
    /// The microphone and its recording state machine. A voice note's text lands in `input`.
    let voice: VoiceController

    // MARK: This window's own state

    /// Where text over `DraftPolicy.limit` is saved. Tests point it at a temporary folder.
    var draftDirectory = FileIntake.directory
    @Published var input = "" {
        didSet {
            if DraftPolicy.exceedsLimit(input) {
                let result = DraftPolicy.apply(input, into: draftDirectory)
                if let file = result.attachment { attachments.append(file) }
                // Assigning inside didSet does not re-run it, so save the shortened draft here.
                // Otherwise the huge text stays in UserDefaults and is split off again on every launch.
                input = result.input
                if persists { UserDefaults.standard.set(input, forKey: Self.draftKey) }
                return
            }
            if persists { UserDefaults.standard.set(input, forKey: Self.draftKey) }
        }
    }
    @Published var attachments: [URL] = [] {
        didSet { if persists { UserDefaults.standard.set(attachments.map(\.path), forKey: Self.attachmentsKey) } }
    }
    /// The message the next send answers. One at a time; choosing another replaces it.
    @Published var replyingTo: ChatReply?
    /// Bumps each time Reply is chosen, so the input takes focus even when the same message is chosen again.
    @Published private(set) var replyFocusTick = 0
    /// The Cmd-F find bar. `findFocusTick` counts presses so a second Cmd-F refocuses the field.
    @Published var findOpen = false
    @Published var findFocusTick = 0
    /// A file drag is over the chat. The window does not auto-hide meanwhile.
    var fileDragActive = false
    @Published var slash = SlashPopupState()
    @Published var sendAfterDictation = UserDefaults.standard.object(forKey: "sendAfterDictation") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sendAfterDictation, forKey: "sendAfterDictation") }
    }
    /// The transcription error that offers Retry, so only that card shows the button.
    @Published private(set) var voiceRetryItem: UUID?

    // MARK: The shared chat, as last read

    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var status = ChatStatus(state: "idle", running: false, title: "New chat", threadID: nil, queued: 0,
                                                    pendingApprovals: 0, pendingForms: 0)
    @Published private(set) var approvals: [ChatApprovalInfo] = []
    @Published private(set) var forms: [ChatFormInfo] = []
    @Published private(set) var queue: [ChatQueuedInfo] = []
    @Published private(set) var history: [ChatThreadInfo] = []
    @Published private(set) var options: ChatOptions

    private let persists: Bool
    private static let draftKey = "chatDraft"
    private static let attachmentsKey = "chatAttachments"
    private let events: APIEventBus
    private var subscription: APIEventBus.Subscription?
    private var cancellables: Set<AnyCancellable> = []
    /// Reads started by events, so a test can wait for them.
    private var reads: [Task<Void, Never>] = []

    init(api: ChatAPI, voiceAPI: VoiceAPI, events: APIEventBus, voice: VoiceController? = nil, persists: Bool = true) {
        self.api = api
        self.voiceAPI = voiceAPI
        self.voice = voice ?? VoiceController()
        self.persists = persists
        self.events = events
        options = api.snapshot().options
        if persists { restoreDraft() }
        self.voice.onTranscript = { [weak self] in self?.receiveTranscript($0) }
        self.voice.onFailure = { [weak self] message, canRetry in self?.voiceFailed(message, canRetry: canRetry) }
        // Phase changes are rare (start, stop, result), so forwarding them re-renders the composer only then.
        self.voice.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        voiceAPI.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        // Ghost stops talking as soon as the user starts a voice note.
        self.voice.$phase.sink { [weak self] phase in if phase == .recording { self?.voiceAPI.stop() } }.store(in: &cancellables)
        apply(api.snapshot())
        subscription = events.subscribe { [weak self] event in self?.heard(event) }
    }

    /// Waits for the reads that events and actions started. Tests call it before looking at the copy.
    func settle() async {
        while !reads.isEmpty {
            let pending = reads
            reads = []
            for task in pending { await task.value }
        }
    }

    // MARK: Keeping the copy current

    private func read(_ work: @escaping @MainActor (ChatViewModel) async -> Void) {
        reads.append(Task { [weak self] in
            guard let self else { return }
            await work(self)
        })
    }

    private func heard(_ event: APIEvent) {
        switch (event.kind, event.id) {
        case (.chatItem, let id?):
            guard let uuid = UUID(uuidString: id) else { return }
            read { await $0.refresh(message: uuid) }
        case (.chatItem, nil):
            read { await $0.refreshMessages() }
        case (.chatState, "approvals"?): read { $0.approvals = await $0.api.approvals(); await $0.refreshStatus() }
        case (.chatState, "forms"?): read { $0.forms = await $0.api.forms(); await $0.refreshStatus() }
        case (.chatState, "queue"?): read { $0.queue = await $0.api.queue(); await $0.refreshStatus() }
        case (.chatState, "options"?): read { await $0.refreshOptions() }
        case (.chatState, "threads"?): read { $0.history = await $0.api.threads() }
        case (.chatState, "status"?): read { await $0.refreshStatus() }
        case (.chatState, "draft"?): read { await $0.takeRestoredDraft() }
        case (.chatState, _): read { await $0.refreshStatus() }
        default: break
        }
    }

    /// Replaces the copy with what the chat holds now.
    func apply(_ snapshot: ChatSnapshot) {
        items = snapshot.messages
        status = snapshot.status
        approvals = snapshot.approvals
        forms = snapshot.forms
        queue = snapshot.queue
        history = snapshot.threads
        if snapshot.options.commands != options.commands { slash.selection = 0 }
        options = snapshot.options
    }

    func refreshAll() async { apply(api.snapshot()) }

    func refreshMessages() async { items = await api.messages() }

    private func refresh(message id: UUID) async {
        guard let item = try? await api.message(id) else { return }
        if let index = items.lastIndex(where: { $0.id == id }) { items[index] = item } else { items.append(item) }
    }

    func refreshStatus() async { status = await api.status() }

    func refreshOptions() async {
        let next = await api.options()
        if next.commands != options.commands { slash.selection = 0 }
        options = next
    }

    // MARK: What ChatView reads

    var isRunning: Bool { status.running }
    var runStartedAt: Date? { status.runStartedAt }
    var agent: ChatNamedInfo { options.agent }
    var agents: [ChatNamedInfo] { options.agents }
    var models: [ChatModel] { options.models.map { ChatModel(id: $0.id, name: $0.name) } }
    var model: String? {
        get { options.model }
        set { options.model = newValue; Task { await api.setModel(newValue) } }
    }
    var modelName: String {
        guard let model else { return "Default" }
        return options.models.first { $0.id == model }?.name ?? model
    }
    var autoMode: Bool {
        get { options.autoMode }
        set { options.autoMode = newValue; Task { await api.setAutoMode(newValue) } }
    }
    var workspace: URL? { options.folder.map(URL.init(fileURLWithPath:)) }
    var workspaceLabel: String { options.folderLabel }
    var needsWorkspace: Bool { options.needsFolder }
    var recents: [URL] { options.recentFolders.map(URL.init(fileURLWithPath:)) }
    var runtimeOffer: String? { options.runtimeOffer }
    var installingRuntime: Bool { options.installingRuntime }
    var signInOptions: [ChatNamedInfo] { options.signInMethods }
    var commands: [SlashCommand] { options.commands.map { SlashCommand(name: $0.name, detail: $0.detail, hint: $0.hint) } }
    /// The chat message being read aloud, so its speaker button shows Stop.
    var speakingID: UUID? { voiceAPI.speakingItem }
    var isSpeaking: Bool { voiceAPI.status.speaking }
    var voiceBusy: Bool { voice.isBusy }

    // MARK: Slash commands

    /// Commands the popup shows for the current input; empty when it should be closed.
    var slashMatches: [SlashCommand] { slash.dismissed ? [] : SlashCommand.matches(for: input, in: commands) }

    /// Puts the selected command into the input. Returns false when the popup is closed.
    @discardableResult
    func completeSlash() -> Bool {
        let list = slashMatches
        guard !list.isEmpty else { return false }
        completeSlash(list[min(slash.selection, list.count - 1)])
        return true
    }

    func completeSlash(_ command: SlashCommand) {
        // Not a dictation: the user still has to add arguments, so it must not schedule an auto-send.
        prefill("/\(command.name) ")
    }

    func moveSlashSelection(_ delta: Int) { slash.move(delta, count: slashMatches.count) }

    /// Esc closes the popup. Returns false when it was not open.
    @discardableResult
    func dismissSlash() -> Bool {
        guard !slashMatches.isEmpty else { return false }
        slash.dismissed = true
        return true
    }

    func inputChanged(from old: String, to new: String) { slash.reset() }

    // MARK: The draft

    /// Puts text in the input for the user to review. It is never sent automatically.
    func prefill(_ text: String) { input = text }

    /// Text delivered by the Wispr Flow bridge. It is inserted but not sent. Skipped if Wispr managed to type it into the field itself.
    func receiveDictation(_ text: String) {
        guard !input.trimmingCharacters(in: .whitespaces).hasSuffix(text) else { return }
        input = input.isEmpty ? text : input + " " + text
    }

    /// A voice note's text goes into the input to edit, or is sent straight away when "Send voice notes automatically" is on.
    /// This is the only path that sends automatically. Pasted, typed and Wispr Flow text never does.
    func receiveTranscript(_ text: String) {
        let existing = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = existing.isEmpty ? text : existing + " " + text
        if sendAfterDictation { send() }
    }

    func attach(_ screenshot: URL) { attachments.append(screenshot) }

    /// Appends files to the current attachments, skipping ones already there.
    func attach(_ files: [URL]) { attachments += files.filter { !attachments.contains($0) } }

    /// Starts a reply to a user or assistant message. Tool steps, screenshots and errors cannot be replied to.
    func reply(to item: ChatItem, selection: String? = nil) {
        let sender: String
        let text: String
        let fromUser: Bool
        switch item.kind {
        case .user(let t): sender = "You"; text = t; fromUser = true
        case .assistant(let t): sender = SettingsAPI.live.config.pet.name; text = t; fromUser = false
        default: return
        }
        let trimmed = selection?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = trimmed?.isEmpty == false ? trimmed : nil
        replyingTo = ChatReply(itemID: item.id, sender: sender, text: selected ?? text, date: item.date,
                               selection: selected == nil ? nil : true, fromUser: fromUser)
        replyFocusTick += 1
    }

    private func restoreDraft() {
        let defaults = UserDefaults.standard
        attachments = (defaults.stringArray(forKey: Self.attachmentsKey) ?? [])
            .map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        // A draft saved by an older version may be huge; the input's didSet turns it into an attachment.
        input = defaults.string(forKey: Self.draftKey) ?? ""
    }

    // MARK: Sending and stopping

    /// Sends the draft. The input clears at once; if the chat has no folder yet the draft comes back so nothing is lost.
    func send() { read { await $0.sendNow() } }

    func sendNow() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let (files, reply) = (attachments, replyingTo)
        input = ""
        attachments = []
        replyingTo = nil
        let result = try? await api.send(SendChatRequest(text: text, origin: nil, files: files, reply: reply))
        if result?.outcome == .needsFolder || result == nil {
            restore(ChatRestoredDraft(text: text, files: files, reply: reply))
            await refreshOptions()
        }
    }

    /// Sends text as its own message and leaves the draft as it was, for the app's own prompts (ask Ghost, a task, an automation).
    /// Returns false when the chat could not take it, such as when no folder is chosen.
    @discardableResult
    func sendSeparately(_ text: String) async -> Bool {
        let result = try? await api.send(SendChatRequest(text: text, origin: nil))
        return result?.outcome == .sent || result?.outcome == .queued || result?.outcome == .toJob
    }

    func stop() { read { await $0.stopNow() } }

    func stopNow() async {
        let result = await api.stop()
        if let restored = result.restored { restore(restored) }
    }

    private func takeRestoredDraft() async {
        if let restored = await api.takeRestoredDraft() { restore(restored) }
    }

    /// Puts messages the chat gave back in the draft, after any text already there.
    private func restore(_ draft: ChatRestoredDraft) {
        let existing = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = existing.isEmpty ? draft.text : (draft.text.isEmpty ? existing : existing + "\n\n" + draft.text)
        attachments += draft.files.filter { !attachments.contains($0) }
        if replyingTo == nil { replyingTo = draft.reply }
    }

    // MARK: Approvals, questions and the queue

    func decide(_ approval: ChatApprovalInfo, allow: Bool) {
        read { _ in _ = try? await self.api.decide(DecideApprovalRequest(id: approval.id, allow: allow)) }
    }

    func setAnswer(form id: UUID, field: String, _ value: ElicitationValue?) {
        // The card edits as the user types, so the copy updates now and the chat follows.
        if let index = forms.firstIndex(where: { $0.id == id }) { forms[index].answers[field] = value }
        read { _ in try? await self.api.answerForm(AnswerFormRequest(id: id, field: field, value: value)) }
    }

    func submitForm(_ id: UUID) { read { _ in try? await self.api.submitForm(id) } }
    func skipForm(_ id: UUID) { read { _ in try? await self.api.skipForm(id) } }
    func removeQueued(_ id: UUID) { read { _ in await self.api.removeQueued(id) } }

    // MARK: Threads, agent and folder

    func open(_ thread: ChatThreadInfo) { read { _ in try? await self.api.openThread(thread.id) } }
    func newChat() { read { _ in await self.api.newChat() } }
    func setAgent(_ agent: ChatNamedInfo) { read { _ in try? await self.api.setAgent(agent.id) } }
    func use(_ url: URL) { read { _ in try? await self.api.useFolder(url.path) } }
    func useNoProject() { read { _ in await self.api.useNoProject() } }
    func installRuntime() { read { _ in await self.api.installRuntime() } }
    func declineRuntime() { read { _ in await self.api.declineRuntime() } }
    func signIn(_ method: ChatNamedInfo) { read { _ in try? await self.api.signIn(method.id) } }
    func retryAfterFix() { read { _ in await self.api.retryAfterFix() } }

    // MARK: Voice

    /// Reads a reply aloud, or stops it when it is the one being read.
    func toggleSpeech(_ item: ChatItem) {
        guard case .assistant(let text) = item.kind else { return }
        if speakingID == item.id { voiceAPI.stop() } else { try? voiceAPI.speak(SpeakRequest(text: text, item: item.id)) }
    }

    func stopSpeech() { voiceAPI.stop() }

    private func voiceFailed(_ message: String, canRetry: Bool) {
        read { model in
            let id = await model.api.addNotice(message)
            model.voiceRetryItem = canRetry ? id : nil
        }
    }

    func retryVoice() {
        guard let id = voiceRetryItem else { return }
        voiceRetryItem = nil
        read { model in
            await model.api.removeMessage(id)
            model.voice.retry()
        }
    }
}
