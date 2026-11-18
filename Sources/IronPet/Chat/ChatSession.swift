import Combine
import Foundation

/// One quick-chat thread with the pet, driven over ACP by whichever coding agent the user picked.
@MainActor
final class ChatSession: ObservableObject {
    enum State { case idle, running, done, failed }

    /// A file drag is over the chat. The window does not auto-hide meanwhile.
    var fileDragActive = false

    struct Item: Identifiable, Codable {
        enum Kind: Codable {
            case user(String)
            case screenshot(String)
            case assistant(String)
            case tool(String, ok: Bool?)
            case error(String)
            /// A form the agent asked and the user answered or skipped.
            case form(ElicitationRecord)
        }
        var id = UUID()
        var kind: Kind
        var date: Date? = Date()
        /// Where a user message came from when it was not typed here (`ChatSession.telegramOrigin`).
        var origin: String?
        /// The earlier message this one answers, when the user used Reply.
        var reply: Reply?
    }

    /// A reference to an earlier message, kept with the message that answers it. It stores the full text, so the agent
    /// still gets the original after the transcript scrolls or the thread is reopened.
    struct Reply: Codable, Equatable {
        /// The id of the original item. The quote scrolls to it while it is in the transcript.
        var itemID: UUID
        /// "You" or the pet's name.
        var sender: String
        /// The original message, or only the selected part of it when `selection` is true.
        var text: String
        var date: Date?
        /// True when the user selected part of the message and asked about that.
        var selection: Bool? = nil
        /// True when the user wrote the original. Older saved threads lack it and fall back to the sender name.
        var fromUser: Bool? = nil
    }

    struct QueuedMessage: Identifiable {
        let id = UUID()
        let text: String
        let attachments: [URL]
        /// The Telegram chat id when the message came from Telegram. Those are never put back in the Mac input.
        var telegram: Int64? = nil
        var reply: Reply? = nil
        /// The id of the automation that sent the message. Those are never put back in the Mac input.
        var automation: String? = nil
    }

    /// What happened to a turn that an automation started, for `onAutomation`.
    enum AutomationEvent: Equatable {
        case started
        case finished
        /// The reply was the task review's "nothing to do" line. The chat removed the prompt and the reply.
        case noChange
        case failed(String)
        /// The user or the chat ended it before or during the run. Not a fault in the automation.
        case cancelled(String)
    }

    /// What happened to a turn that started from Telegram, for `onTelegram`.
    enum TelegramEvent: Equatable {
        /// The agent was busy, so the message waits its turn.
        case queued
        case started
        /// The turn needs an approval. The Mac shows the same card.
        case approval(id: UUID, title: String, detail: String)
        /// An approval card was answered, here or on the Mac, or went away because the turn ended.
        case approvalDecided(id: UUID, outcome: ApprovalOutcome)
        /// The turn ended; the text is the last thing the agent wrote.
        case finished(String?)
        case failed(String)
    }

    enum ApprovalOutcome: Equatable { case allowed, denied, ended }

    static let telegramOrigin = "telegram"
    static let automationOrigin = "automation"
    /// A prompt or follow-up that a background job ran (`JobService`).
    static let jobOrigin = "job"

    struct Approval: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        /// Identical requests share one card and one decision.
        var responders: [(ApprovalDecision) -> Void]

        var key: String { title + "\u{0}" + detail }

        func respond(_ decision: ApprovalDecision) {
            responders.forEach { $0(decision) }
        }
    }

    /// A form the agent is waiting on (`elicitation/create`), with what the user has entered so far.
    struct PendingForm: Identifiable {
        let id = UUID()
        let form: ElicitationForm
        var answers: ElicitationAnswers = [:]
        let respond: (ElicitationReply) -> Void
    }

    @Published var items: [Item] = []
    /// The Cmd-F find bar. `findFocusTick` counts presses so a second Cmd-F refocuses the field.
    @Published var findOpen = false
    @Published var findFocusTick = 0
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
    /// Where text over `DraftPolicy.limit` is saved. Tests point it at a temporary folder.
    var draftDirectory = FileIntake.directory
    @Published var workspace: URL?
    /// Set when the chat opened outside a coding app; the user picks a folder before sending.
    @Published private(set) var needsWorkspace = false
    @Published private(set) var recents: [URL] = []
    @Published var autoMode = false {
        didSet { if persists { UserDefaults.standard.set(autoMode, forKey: Self.autoKey) } }
    }
    @Published var sendAfterDictation = UserDefaults.standard.object(forKey: "sendAfterDictation") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sendAfterDictation, forKey: "sendAfterDictation") }
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var approvals: [Approval] = []
    @Published private(set) var forms: [PendingForm] = []
    @Published private(set) var history: [ChatThread] = ThreadStore.recent()
    @Published var attachments: [URL] = [] {
        didSet { if persists { UserDefaults.standard.set(attachments.map(\.path), forKey: Self.attachmentsKey) } }
    }
    /// Messages typed while a turn runs. Each keeps the attachments present when it was queued.
    @Published private(set) var queue: [QueuedMessage] = []
    /// The message the next send answers. One at a time; choosing another replaces it.
    @Published var replyingTo: Reply?
    /// Bumps each time Reply is chosen, so the input takes focus even when the same message is chosen again.
    @Published private(set) var replyFocusTick = 0
    /// What the agent is doing right now, e.g. "Running `npm test`".
    @Published private(set) var activity: String?
    @Published private(set) var runStartedAt: Date?
    @Published private(set) var lastRunDuration: TimeInterval?
    /// Models the agent offered in its last session. Empty hides the picker.
    @Published private(set) var models: [ChatModel] = []
    @Published private(set) var agent: ACPAgent =
        AgentCatalog.agent(id: UserDefaults.standard.string(forKey: "chatAgent")) ?? AgentCatalog.agent(id: "cursor")!
    /// Installed agents that answer `initialize`. Starts as just the current one until the check finishes.
    @Published private(set) var agents: [ACPAgent] = []
    @Published private(set) var commands: [SlashCommand] = []
    @Published var slash = SlashPopupState()

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

    func moveSlashSelection(_ delta: Int) {
        slash.move(delta, count: slashMatches.count)
    }

    /// Esc closes the popup. Returns false when it was not open.
    @discardableResult
    func dismissSlash() -> Bool {
        guard !slashMatches.isEmpty else { return false }
        slash.dismissed = true
        return true
    }

    func receiveCommands(_ list: [SlashCommand]) {
        if list != commands { slash.selection = 0 }
        commands = list
        if persists { SlashCommand.store(list, for: agent.id) }
    }
    /// nil uses the agent's default model. Stored per agent.
    @Published var model: String? {
        didSet { UserDefaults.standard.set(model, forKey: "chatModel.\(agent.id)") }
    }
    /// Set when an adapter has no runtime: the chat offers a one-time Bun download.
    @Published private(set) var runtimeOffer: String?
    @Published private(set) var installingRuntime = false
    /// Set when the agent asks the user to sign in.
    @Published private(set) var signInOptions: [AuthMethod] = []

    var modelName: String {
        guard let model else { return "Default" }
        return models.first { $0.id == model }?.name ?? model
    }

    /// Called when something needs the user while the chat is hidden.
    var onAttention: ((String) -> Void)?
    /// A new approval card while the chat is hidden; answered from a notification.
    var onApprovalNeeded: ((Approval) -> Void)?
    var onApprovalResolved: ((UUID) -> Void)?
    /// A new form while the chat is hidden: a title and the form's message.
    var onFormNeeded: ((String, String) -> Void)?
    var isVisible = false
    /// Reports progress of turns that came from Telegram, with the Telegram chat id.
    var onTelegram: ((Int64, TelegramEvent) -> Void)?
    /// Reports the start and end of a turn that an automation sent (`submitFromAutomation`).
    var onAutomation: ((String, AutomationEvent) -> Void)?
    private var automationRun: String?
    /// The `quiet` reply of an automation, by id. A turn whose final reply is exactly that text is hidden.
    var quietReply: (String) -> String? = { _ in nil }
    private var telegramChat: Int64?

    private(set) var threadID: String? {
        didSet { if persists { UserDefaults.standard.set(threadID, forKey: Self.threadKey) } }
    }
    /// False for preview sessions, so rendering screenshots neither reads nor overwrites the real chat.
    private let persists: Bool
    private static let threadKey = "chatThread"
    private static let draftKey = "chatDraft"
    private static let attachmentsKey = "chatAttachments"
    private static let autoKey = "chatAutoMode"
    private var acp: ACPBackend?
    /// Ignores events from a turn the user stopped.
    private var turnID: UUID?
    private var lastTurn: ACPTurn?
    /// Replaces the agent turn in tests: receives the turn and the callback that delivers its events.
    var turnRunner: ((ACPTurn, @escaping (AgentEvent) -> Void) async -> Void)?
    private var toolItems: [String: UUID] = [:]
    /// A tool row's own summary, before the count of its subagent's tool calls is added.
    private var toolBase: [String: String] = [:]
    /// The tool calls each subagent has made, by the subagent's tool-use id, in the order they started.
    private var subagentCalls: [String: [(id: String, ok: Bool?)]] = [:]
    /// The reply item that late updates extend, so a later result starts its own item.
    private var backgroundReply: UUID?
    /// Decisions made during the current run, so a repeated identical check isn't asked twice.
    private var decided: [String: Bool] = [:]
    let voice = VoiceController()
    private var voiceChanges: AnyCancellable?
    let speech = SpeechPlayer()
    private var speechChanges: [AnyCancellable] = []
    /// The running turn was sent from the chat, not from Telegram or an automation; its reply is read aloud when it ends.
    private var turnSpoken = false
    /// True during a call or a meeting recording, when a reply is not read aloud on its own. Set by `AppDelegate`.
    var isQuiet: () -> Bool = { false }
    /// The transcription error that offers Retry, so only that card shows the button.
    @Published private(set) var voiceRetryItem: UUID?

    static let scratchWorkspace = Paths.root.appendingPathComponent("scratch")

    /// `restore` reopens the chat that was open when the app last quit: its thread, folder and backend,
    /// plus the unsent draft and attachments. Auto mode comes back only for that same chat; a new chat or
    /// one opened from history still starts with Auto off.
    init(restore: Bool = true) {
        persists = restore
        recents = (UserDefaults.standard.stringArray(forKey: "recentWorkspaces") ?? [])
            .map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) && $0 != Self.scratchWorkspace }
        workspace = recents.first
        model = UserDefaults.standard.string(forKey: "chatModel.\(agent.id)")
        models = Self.cachedModels(for: agent)
        commands = SlashCommand.cached(for: agent.id)
        agents = [agent]
        if restore { Task { await refreshAgents() } }
        if restore { restoreLastChat() }
        // Phase changes are rare (start, stop, result), so forwarding them re-renders the composer only then.
        voiceChanges = voice.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        voice.onTranscript = { [weak self] in self?.receiveTranscript($0) }
        voice.onFailure = { [weak self] message, canRetry in self?.voiceFailed(message, canRetry: canRetry) }
        speechChanges = [
            speech.objectWillChange.sink { [weak self] in self?.objectWillChange.send() },
            // Ghost stops talking as soon as the user starts a voice note.
            voice.$phase.sink { [weak self] phase in if phase == .recording { self?.speech.stop() } },
        ]
        speech.onFailure = { [weak self] message in self?.items.append(Item(kind: .error(message))) }
    }

    /// A voice note's text goes into the input to edit, or is sent straight away when "Send voice notes automatically" is on.
    /// This is the only path that sends automatically. Pasted, typed and Wispr Flow text never does.
    func receiveTranscript(_ text: String) {
        let existing = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = existing.isEmpty ? text : existing + " " + text
        if sendAfterDictation { send() }
    }

    /// Reads a reply aloud, or stops it when it is the one being read.
    func toggleSpeech(_ item: Item) {
        guard case .assistant(let text) = item.kind else { return }
        if speech.speakingID == item.id { speech.stop() } else { speech.speak(text, id: item.id) }
    }

    private func voiceFailed(_ message: String, canRetry: Bool) {
        let item = Item(kind: .error(message))
        items.append(item)
        voiceRetryItem = canRetry ? item.id : nil
    }

    func retryVoice() {
        guard let id = voiceRetryItem else { return }
        items.removeAll { $0.id == id }
        voiceRetryItem = nil
        voice.retry()
    }

    private func restoreLastChat() {
        let defaults = UserDefaults.standard
        autoMode = defaults.bool(forKey: Self.autoKey)
        if let id = defaults.string(forKey: Self.threadKey), let thread = ThreadStore.load(id) {
            apply(thread.restoredAfterQuit(), reason: "restore after launch")
        }
        attachments = (defaults.stringArray(forKey: Self.attachmentsKey) ?? [])
            .map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        // A draft saved by an older version may be huge; the input's didSet turns it into an attachment.
        input = defaults.string(forKey: Self.draftKey) ?? ""
    }

    /// Writes the open thread to disk, e.g. when the app quits mid-run.
    func persistForRelaunch() {
        guard persists else { return }
        saveThread()
    }

    var mood: PetMood? {
        if !approvals.isEmpty || !forms.isEmpty { return .needsInput }
        switch state {
        case .running: return .working
        case .done: return .done
        case .failed: return .failed
        case .idle: return isVisible ? .listening : nil
        }
    }

    var isRunning: Bool { state == .running }

    /// Called when the chat opens. The session and folder stay as they are. Only when no folder was ever chosen does
    /// the picker show.
    func prepareForShow() {
        if state == .done || state == .failed, approvals.isEmpty, forms.isEmpty { state = .idle }
        if workspace == nil { needsWorkspace = true }
    }

    func use(_ url: URL) {
        let changed = workspace != url
        workspace = url
        needsWorkspace = false
        if url != Self.scratchWorkspace {
            recents = [url] + recents.filter { $0 != url }.prefix(7)
            UserDefaults.standard.set(recents.map(\.path), forKey: "recentWorkspaces")
        }
        if changed { ChatLog.note("workspace changed to \(url.path)") }
        if changed, !items.isEmpty, !isRunning { newChat(reason: "folder picked: \(url.path)") }
    }

    /// For general questions that are not about a project.
    func useNoProject() {
        try? FileManager.default.createDirectory(at: Self.scratchWorkspace, withIntermediateDirectories: true)
        use(Self.scratchWorkspace)
    }

    var workspaceLabel: String {
        guard let workspace else { return "Choose a folder" }
        return workspace == Self.scratchWorkspace ? "No project" : workspace.lastPathComponent
    }

    func setAgent(_ next: ACPAgent) {
        guard next != agent, !isRunning else { return }
        ChatLog.note("agent changed from \(agent.id) to \(next.id)")
        select(next)
        if !items.isEmpty { newChat(reason: "agent changed to \(next.id)") }
    }

    private func select(_ next: ACPAgent) {
        agent = next
        UserDefaults.standard.set(next.id, forKey: "chatAgent")
        model = UserDefaults.standard.string(forKey: "chatModel.\(next.id)")
        models = Self.cachedModels(for: next)
        commands = SlashCommand.cached(for: next.id)
        if !agents.contains(next) { agents.append(next) }
    }

    /// Lists the installed agents that speak ACP. The first launch switches to an installed one if the saved choice is missing.
    func refreshAgents() async {
        let found = await ACPProbe.installed()
        guard !found.isEmpty else { return }
        agents = found
        if !found.contains(agent), items.isEmpty, !isRunning, let first = found.first { select(first) }
    }

    static func cachedModels(for agent: ACPAgent) -> [ChatModel] {
        (UserDefaults.standard.array(forKey: "cachedModels.\(agent.id)") as? [[String]] ?? []).compactMap {
            $0.count == 2 ? ChatModel(id: $0[0], name: $0[1]) : nil
        }
    }

    /// Sample conversations for `--render-previews`.
    enum Preview { case done, approval, markdown, form }

    func loadPreview(_ preview: Preview) {
        workspace = URL(fileURLWithPath: "/Users/you/code/demo-app")
        needsWorkspace = false
        if preview == .markdown {
            items = [
                Item(kind: .user("how does login refresh the token?")),
                Item(kind: .assistant("""
                    ## Token refresh

                    `login()` stores the session, then **refreshes the token** before it expires:

                    1. Read the expiry from the session
                    2. Schedule `refreshToken()` 60 s early
                       - retries twice on a network error
                    3. Replace the stored token

                    | Step | File |
                    |------|------|
                    | Login | `src/auth/login.ts` |
                    | Refresh | `src/auth/session.ts` |

                    ```ts
                    await refreshToken(session)
                    ```

                    > The test was flaky because step 2 was not awaited.

                    ```mermaid
                    graph LR
                      A[login] --> B[store session] --> C[refresh token]
                    ```
                    """)),
            ]
            state = .done
            return
        }
        items = [
            Item(kind: .user("why is the login test flaky?")),
            Item(kind: .tool("Ran `npm test -- login`", ok: false)),
            Item(kind: .tool("Read src/auth/session.ts", ok: true)),
            Item(kind: .assistant("`refreshToken()` resolves after the test checks the session, so it fails whenever the mock server is slow. Awaiting it in `login()` fixes it. Want me to make the change?")),
            Item(kind: .user("yes please")),
        ]
        switch preview {
        case .approval:
            items.append(Item(kind: .tool("Edited src/auth/session.ts", ok: true)))
            state = .running
            activity = "Waiting for you"
            runStartedAt = Date().addingTimeInterval(-9)
            approvals = [Approval(title: "Run this command?", detail: "npm test -- login --runInBand", responders: [])]
        case .done:
            items.append(Item(kind: .tool("Edited src/auth/session.ts", ok: true)))
            items.append(Item(kind: .tool("Ran `npm test -- login`", ok: true)))
            items.append(Item(kind: .assistant("Done! `login()` now waits for the token refresh, and the test passed 20 runs in a row.")))
            state = .done
            lastRunDuration = 14
        case .markdown:
            break
        case .form:
            state = .running
            activity = "Waiting for you"
            runStartedAt = Date().addingTimeInterval(-9)
            if let form = ElicitationForm.parse(Self.sampleForm) {
                forms = [PendingForm(form: form, answers: ["question_0": .one("Swift Testing"), "question_1": .many(["lint"])], respond: { _ in })]
            }
        }
    }

    /// A reply with every text block, for the markdown previews.
    static let sampleMarkdown = """
    ## Plan
    The first paragraph has `code`, **bold**, a [link](https://example.com) and the path /etc/hosts, and it runs long enough to wrap onto a second line.

    - First item is long enough to wrap onto a second line at the narrow column width, so the hanging indent shows
      - Nested item
        - Deeper nested item
    - [ ] Open task item
    - [x] Done task item

    1. One
    2. Two is long enough to wrap onto a second line at the narrow column width, so the hanging indent shows
    3. Three

    > A quoted line that also wraps around when the column is narrow enough to need it, with `code` inside.

    ```swift
    let answer = 42
    ```

    Closing paragraph after the code block.
    """

    private static let sampleForm: JSON = [
        "mode": "form", "message": "Please answer the following questions.",
        "requestedSchema": ["type": "object", "properties": [
            "question_0": ["type": "string", "title": "Test runner", "description": "Which test runner should the new tests use?",
                           "oneOf": [["const": "XCTest", "title": "XCTest", "description": "Already used by every test in this repo"],
                                     ["const": "Swift Testing", "title": "Swift Testing", "description": "Newer macros, needs Xcode 16"]]],
            "question_0_custom": ["type": "string", "title": "Other", "description": "Type your own answer, or add a note to the option you chose above (optional)."],
            "question_1": ["type": "array", "title": "Checks", "description": "Which checks should run before the commit?",
                           "items": ["anyOf": [["const": "lint", "title": "Lint"], ["const": "build", "title": "Build", "description": "swift build"],
                                               ["const": "test", "title": "Tests", "description": "swift test, about two minutes"]]]],
            "question_1_custom": ["type": "string", "title": "Other", "description": "Type your own answer to add to your selection above (optional)."],
        ] as JSON],
    ]

    func attach(_ screenshot: URL) {
        attachments.append(screenshot)
    }

    /// Appends files to the current attachments, skipping ones already there.
    func attach(_ files: [URL]) {
        attachments += files.filter { !attachments.contains($0) }
    }

    /// Starts a reply to a user or assistant message. Tool steps, screenshots and errors cannot be replied to.
    func reply(to item: Item, selection: String? = nil) {
        let sender: String
        let text: String
        let fromUser: Bool
        switch item.kind {
        case .user(let t): sender = "You"; text = t; fromUser = true
        case .assistant(let t): sender = ConfigStore.shared.config.pet.name; text = t; fromUser = false
        default: return
        }
        let trimmed = selection?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = trimmed?.isEmpty == false ? trimmed : nil
        replyingTo = Reply(itemID: item.id, sender: sender, text: selected ?? text, date: item.date,
                           selection: selected == nil ? nil : true, fromUser: fromUser)
        replyFocusTick += 1
    }

    /// Most characters of the original that reach the agent.
    static let replyLimit = 4000

    private static let replyTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    /// The prompt the agent receives for a reply: the original quoted in full, then the user's text.
    static func replyPrompt(_ reply: Reply, text: String) -> String {
        var original = reply.text
        var note = ""
        if original.count > replyLimit {
            note = "\n[The original was cut here. It is \(original.count) characters long.]"
            original = String(original.prefix(replyLimit))
        }
        let owner = reply.fromUser ?? (reply.sender == "You") ? "your own" : "\(reply.sender)'s"
        let when = reply.date.map { " from \(replyTime.string(from: $0))" } ?? ""
        let quoted = (original + note).components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        let lead = reply.selection == true ? "About this part of" : "Replying to"
        return "> \(lead) \(owner) message\(when):\n\(quoted)\n\n\(text)"
    }

    /// Auto mode is not touched: it is the user's setting, not part of a chat.
    func newChat(reason: String = "new chat requested") {
        ChatLog.note("chat cleared (\(items.count) items, thread \(threadID ?? "none")): \(reason)")
        stop()
        shutdownAgent()
        replyingTo = nil
        items = []
        threadID = nil
        jobMessages = []
        state = .idle
        lastRunDuration = nil
    }

    func open(_ thread: ChatThread) {
        stop()
        shutdownAgent()
        apply(thread, reason: "opened from history")
    }

    private func apply(_ thread: ChatThread, reason: String) {
        ChatLog.note("thread \(thread.id) loaded (\(thread.items.count) items), replacing thread \(threadID ?? "none"): \(reason)")
        if let saved = AgentCatalog.agent(id: thread.agent), saved != agent { select(saved) }
        replyingTo = nil
        items = thread.items
        threadID = thread.id
        jobMessages = []
        state = .idle
        let url = URL(fileURLWithPath: thread.workspace)
        workspace = url
        needsWorkspace = false
        if url != Self.scratchWorkspace { recents = [url] + recents.filter { $0 != url }.prefix(7) }
    }

    private func saveThread() {
        guard let threadID, let workspace else { return }
        let firstPrompt = items.lazy.compactMap { item -> String? in
            if case .user(let text) = item.kind { return text } else { return nil }
        }.first ?? "Chat"
        let title = firstPrompt.count > 60 ? String(firstPrompt.prefix(57)) + "…" : firstPrompt
        var thread = ChatThread(id: threadID, title: title, workspace: workspace.path, updatedAt: Date(), items: items, agent: agent.id)
        // Continuing an automation's thread keeps it marked as one, and keeps its run count.
        if let earlier = ThreadStore.load(threadID), earlier.automation != nil {
            thread.title = earlier.title
            thread.automation = earlier.automation
            thread.automationName = earlier.automationName
            thread.runs = earlier.runs
        }
        if let earlier = ThreadStore.load(threadID), earlier.job != nil {
            thread.title = earlier.title
            thread.job = earlier.job
        }
        ThreadStore.save(thread)
        history = ThreadStore.recent()
    }

    /// Reloads the thread list after something else saved a thread, such as an automation run.
    func refreshHistory() { history = ThreadStore.recent() }

    /// A background job saved `thread`. When it is the one on screen and no turn of the chat's own is running, the
    /// transcript shows the job's new steps.
    func threadSaved(_ thread: ChatThread) {
        refreshHistory()
        guard thread.id == threadID, !isRunning else { return }
        let sent = Set(thread.items.compactMap { item -> String? in
            if case .user(let text) = item.kind { return text } else { return nil }
        })
        // Messages typed here that the job has not started on yet are not in its transcript.
        jobMessages.removeAll { sent.contains($0.sent) }
        items = thread.items + jobMessages.map(\.item)
    }

    /// What a message typed in a job's thread sends to the job.
    static func jobMessage(_ text: String, reply: Reply?, files: [URL]) -> String {
        var message = reply.map { replyPrompt($0, text: text) } ?? text
        if !files.isEmpty { message += (message.isEmpty ? "" : "\n\n") + "Attached files:\n" + files.map { "- \($0.path)" }.joined(separator: "\n") }
        return message
    }

    /// Messages typed into the open job thread that are waiting for the job's current turn to end.
    private var jobMessages: [(item: Item, sent: String)] = []

    /// Takes a message typed in a thread whose background job is still running (thread id, text). Returns false when no
    /// job runs there, so the chat sends it itself.
    var jobFollowUp: ((String, String) -> Bool)?

    func send() {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !attachments.isEmpty else { return }
        speech.stop()
        // A second process on the job's session would race it, so everything typed here goes to the job: a reply as its
        // quoted prompt, attachments as their paths.
        let message = Self.jobMessage(prompt, reply: replyingTo, files: attachments)
        if !isRunning, let threadID, jobFollowUp?(threadID, message) == true {
            let item = Item(kind: .user(prompt.isEmpty ? "Attached files" : prompt), origin: Self.jobOrigin, reply: replyingTo)
            attachments = []
            replyingTo = nil
            items.append(item)
            jobMessages.append((item, message))
            input = ""
            return
        }
        if isRunning {
            queue.append(QueuedMessage(text: prompt, attachments: attachments, reply: replyingTo))
            input = ""
            attachments = []
            replyingTo = nil
            return
        }
        if start(prompt: prompt, shots: attachments, reply: replyingTo) {
            input = ""
            attachments = []
            replyingTo = nil
        }
    }

    /// Starts a turn. Returns false, without sending, when no folder is chosen or the hooks are missing.
    @discardableResult
    private func start(prompt: String, shots: [URL], telegram: Int64? = nil, reply: Reply? = nil, automation: String? = nil) -> Bool {
        var prompt = prompt
        if telegram != nil || automation != nil, workspace == nil {
            // No chat has a folder yet. The no-project folder is what a chat with no code context uses.
            try? FileManager.default.createDirectory(at: Self.scratchWorkspace, withIntermediateDirectories: true)
            workspace = Self.scratchWorkspace
            needsWorkspace = false
        }
        // A Telegram message uses the chat as it is, so it does not wait for a folder pick.
        guard telegram != nil || automation != nil || !needsWorkspace, let workspace else {
            needsWorkspace = true
            return false
        }
        if telegram != nil || automation != nil, state == .done || state == .failed { state = .idle }
        if prompt.isEmpty { prompt = telegram == nil ? "Help me with what's on my screen." : "Help me with the attached file." }
        let origin = telegram != nil ? Self.telegramOrigin : automation != nil ? Self.automationOrigin : nil
        items += shots.map { Item(kind: .screenshot($0.path), origin: origin) }
        items.append(Item(kind: .user(prompt), origin: origin, reply: reply))
        let preamble = threadID == nil ? Memory.preamble(for: workspace) : nil
        telegramChat = telegram
        turnSpoken = telegram == nil && automation == nil
        if let telegram { onTelegram?(telegram, .started) }
        automationRun = automation
        if let automation { onAutomation?(automation, .started) }
        run(ACPTurn(prompt: reply.map { Self.replyPrompt($0, text: prompt) } ?? prompt, preamble: preamble, workspace: workspace, resume: threadID, model: model,
                    images: shots.filter(ImageIntake.isImageFile), files: shots.filter { !ImageIntake.isImageFile($0) }))
        return true
    }

    private func run(_ turn: ACPTurn) {
        lastTurn = turn
        runtimeOffer = nil
        signInOptions = []
        state = .running
        activity = "Thinking"
        runStartedAt = Date()
        lastRunDuration = nil
        decided = [:]
        let id = UUID()
        turnID = id
        if let turnRunner {
            Task { [weak self] in await turnRunner(turn) { event in self?.handle(event, turn: id) } }
            return
        }
        if agent.id == "cursor", Config.load().config.integrations.shareMCPSignIns { MCPAuthSharing.prepare(workspace: turn.workspace) }
        let backend = acp?.agent == agent ? acp! : makeBackend()
        Task { [weak self] in
            await backend.runTurn(turn) { event in self?.handle(event, turn: id) }
        }
    }

    func removeQueued(_ id: UUID) {
        if let automation = queue.first(where: { $0.id == id })?.automation { onAutomation?(automation, .cancelled("Removed from the queue.")) }
        queue.removeAll { $0.id == id }
    }

    /// Puts queued messages back in the input, after any text already there, so nothing is lost. Messages that came
    /// from Telegram go back to Telegram as a failure instead: they are not the Mac user's draft.
    private func restoreQueue(reason: String = "Cancelled on the Mac before it started.") {
        for message in queue { if let chat = message.telegram { onTelegram?(chat, .failed(reason)) } }
        queue.removeAll { $0.telegram != nil }
        for message in queue { if let id = message.automation { onAutomation?(id, .cancelled(reason)) } }
        queue.removeAll { $0.automation != nil }
        guard !queue.isEmpty else { return }
        let text = queue.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let existing = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = existing.isEmpty ? text : existing + "\n\n" + text
        input = combined
        attachments += queue.flatMap(\.attachments)
        if replyingTo == nil { replyingTo = queue.compactMap(\.reply).first }
        queue = []
    }

    /// Sends the oldest queued message through the normal path.
    private func sendNextQueued() {
        guard let next = queue.first else { return }
        if start(prompt: next.text, shots: next.attachments, telegram: next.telegram, reply: next.reply, automation: next.automation) {
            queue.removeFirst()
        } else {
            restoreQueue()
        }
    }

    /// A message from an allowed Telegram user. It goes into the chat that is open now, the same way typed text
    /// does, and never changes the chat's thread or folder. A busy agent queues it with the Mac's own queue until the
    /// turn ends. `files` are shown and sent like Mac attachments, without touching the draft the user may be composing.
    func submitFromTelegram(_ text: String, chat: Int64, files: [URL] = [], reply: Reply? = nil) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !files.isEmpty else { return }
        guard !isRunning else {
            queue.append(QueuedMessage(text: prompt, attachments: files, telegram: chat, reply: reply))
            onTelegram?(chat, .queued)
            return
        }
        start(prompt: prompt, shots: files, telegram: chat, reply: reply)
    }

    /// A prompt from an automation. It goes into the chat that is open now, in the current thread and folder, and
    /// waits in the queue behind a running turn. The user's draft and attachments stay as they are. Without a folder
    /// it uses the no-project folder instead of asking. Returns false when this automation's earlier message is still
    /// queued or running, or the message could not start.
    @discardableResult
    func submitFromAutomation(_ text: String, automation: String) -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !hasAutomationRun(automation) else { return false }
        guard !isRunning else {
            queue.append(QueuedMessage(text: prompt, attachments: [], automation: automation))
            return true
        }
        return start(prompt: prompt, shots: [], automation: automation)
    }

    /// True while a message from this automation is queued or its turn is running.
    func hasAutomationRun(_ id: String) -> Bool {
        automationRun == id || queue.contains { $0.automation == id }
    }

    /// Tells the automation how its turn ended. Called before the next queued message starts.
    private func finishAutomationTurn(error: String?, noChange: Bool = false) {
        guard let id = automationRun else { return }
        automationRun = nil
        onAutomation?(id, error.map { .failed($0) } ?? (noChange ? .noChange : .finished))
    }

    /// Removes an automation's prompt and reply from the transcript when the reply is exactly its `quiet` text.
    /// Returns true when it did. Any other reply stays as a normal automation turn.
    private func hideQuietTurn() -> Bool {
        guard let id = automationRun, let quiet = quietReply(id)?.trimmingCharacters(in: .whitespacesAndNewlines), !quiet.isEmpty,
              let start = items.lastIndex(where: { if case .user = $0.kind { return true } else { return false } }),
              items[start].origin == Self.automationOrigin,
              lastAnswer()?.trimmingCharacters(in: .whitespacesAndNewlines) == quiet else { return false }
        // The reply is the whole turn. Tool calls or other text before the line mean the agent did something.
        let rest = items[(start + 1)...]
        let onlyTheLine = rest.allSatisfy { item in
            if case .assistant(let text) = item.kind {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty || t == quiet
            }
            return false
        }
        guard onlyTheLine else { return false }
        items.removeSubrange(start...)
        return true
    }

    /// Applies a decision from Telegram through the same path as the Mac's Allow and Deny buttons.
    func decideFromTelegram(id: UUID, allow: Bool) {
        decide(id: id, allow: allow)
    }

    func hasPendingApproval(_ id: UUID) -> Bool { approvals.contains { $0.id == id } }

    var telegramQueueCount: Int { queue.filter { $0.automation == nil }.count }

    func cancelTelegram(chat: Int64) {
        queue.removeAll { $0.telegram == chat }
        if telegramChat == chat { telegramChat = nil }
    }

    /// Tells Telegram how its turn ended. Called before the next queued message starts, which replaces `telegramChat`.
    private func finishTelegramTurn(error: String?, noChange: Bool = false) {
        finishAutomationTurn(error: error, noChange: noChange)
        guard let chat = telegramChat else { return }
        telegramChat = nil
        if let error {
            onTelegram?(chat, .failed(error))
        } else {
            onTelegram?(chat, .finished(lastAnswer()))
        }
    }

    /// The last assistant message after the newest user message.
    private func lastAnswer() -> String? {
        guard let item = lastAnswerItem(), case .assistant(let text) = item.kind else { return nil }
        return text
    }

    private func lastAnswerItem() -> Item? {
        guard let start = items.lastIndex(where: { if case .user = $0.kind { return true } else { return false } }) else { return nil }
        return items[start...].last { item in
            if case .assistant(let text) = item.kind { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return false
        }
    }

    private func makeBackend() -> ACPBackend {
        if acp != nil { ChatLog.note("agent backend replaced: \(agent.id), thread \(threadID ?? "none") kept") }
        acp?.shutdown()
        let backend = ACPBackend(agent: agent)
        backend.usageFeature = .chat
        backend.onPermission = { [weak self] call, respond in self?.handlePermission(call, respond: respond) }
        backend.onElicitation = { [weak self] form, respond in self?.handleElicitation(form, respond: respond) }
        backend.onBackground = { [weak self] event in self?.handleBackground(event) }
        acp = backend
        return backend
    }

    private func shutdownAgent() {
        acp?.shutdown()
        acp = nil
    }

    /// For the test endpoints: which process and session the chat is using.
    var processID: Int32? { acp?.processID }
    var sessionID: String? { acp?.sessionID ?? threadID }
    var activeModel: String? { acp?.activeModel }

    func stop() {
        restoreQueue()
        speech.stop()
        turnSpoken = false
        turnID = nil
        acp?.cancel()
        for approval in approvals {
            approval.respond(.deny("Stopped in ironpet"))
            onApprovalResolved?(approval.id)
            if let chat = telegramChat { onTelegram?(chat, .approvalDecided(id: approval.id, outcome: .ended)) }
        }
        approvals = []
        cancelForms()
        activity = nil
        runStartedAt = nil
        if state == .running { state = .idle }
        if let id = automationRun {
            automationRun = nil
            onAutomation?(id, .cancelled("Stopped on the Mac."))
        }
        if let chat = telegramChat {
            telegramChat = nil
            onTelegram?(chat, .failed("Stopped on the Mac."))
        }
    }

    /// Stops the agent process for good, e.g. when the app quits.
    func shutdown() {
        stop()
        shutdownAgent()
    }

    /// Text delivered by the Wispr Flow bridge. It is inserted but not sent. Skipped if Wispr managed to type it into the field itself.
    func receiveDictation(_ text: String) {
        guard !input.trimmingCharacters(in: .whitespaces).hasSuffix(text) else { return }
        input = input.isEmpty ? text : input + " " + text
    }

    /// Puts text in the input for the user to review. It is never sent automatically.
    func prefill(_ text: String) {
        input = text
    }

    func inputChanged(from old: String, to new: String) {
        slash.reset()
    }

    func decide(_ approval: Approval, allow: Bool) {
        decide(id: approval.id, allow: allow)
    }

    func decide(id: UUID, allow: Bool) {
        guard let current = approvals.first(where: { $0.id == id }) else { return }
        approvals.removeAll { $0.id == id }
        decided[current.key] = allow
        current.respond(allow ? .allow : .deny())
        onApprovalResolved?(id)
        if let chat = telegramChat { onTelegram?(chat, .approvalDecided(id: id, outcome: allow ? .allowed : .denied)) }
    }

    /// Shows the agent's `elicitation/create` form as a card. The reply goes out when the user submits or skips.
    func handleElicitation(_ form: ElicitationForm, respond: @escaping (ElicitationReply) -> Void) {
        let pending = PendingForm(form: form, respond: respond)
        forms.append(pending)
        if !isVisible {
            onFormNeeded?("\(ConfigStore.shared.config.pet.name) has a question for you", String(form.message.prefix(240)))
        }
    }

    func setAnswer(form id: UUID, field: String, _ value: ElicitationValue?) {
        guard let index = forms.firstIndex(where: { $0.id == id }) else { return }
        forms[index].answers[field] = value
    }

    func submitForm(_ id: UUID) {
        guard let pending = forms.first(where: { $0.id == id }), pending.form.canSubmit(pending.answers) else { return }
        finishForm(pending, reply: .accept(pending.form.content(pending.answers)),
                   record: ElicitationRecord(message: pending.form.message, skipped: false, lines: pending.form.lines(pending.answers)))
    }

    func skipForm(_ id: UUID) {
        guard let pending = forms.first(where: { $0.id == id }) else { return }
        finishForm(pending, reply: .decline, record: ElicitationRecord(message: pending.form.message, skipped: true, lines: []))
    }

    private func finishForm(_ pending: PendingForm, reply: ElicitationReply, record: ElicitationRecord) {
        forms.removeAll { $0.id == pending.id }
        items.append(Item(kind: .form(record)))
        pending.respond(reply)
    }

    /// The turn stopped or ended with forms open. The agent aborts the tool call that asked.
    private func cancelForms() {
        let open = forms
        forms = []
        open.forEach { $0.respond(.cancel) }
    }

    /// Answers the agent's `session/request_permission`: either straight away or through an approval card.
    func handlePermission(_ call: ACPToolCall, respond: @escaping (ApprovalDecision) -> Void) {
        switch ApprovalRules.policy(for: call, auto: autoMode) {
        case .allow:
            respond(.allow)
        case .ask(let title, let detail):
            ask(title: title, detail: detail, respond: respond)
        }
    }

    func retryAfterFix() {
        guard let turn = lastTurn, !isRunning else { return }
        items.removeAll { if case .error = $0.kind { return true } else { return false } }
        run(turn)
    }

    /// The user allowed the one-time Bun download.
    func installRuntime() {
        guard runtimeOffer != nil, !installingRuntime else { return }
        installingRuntime = true
        Task {
            defer { installingRuntime = false }
            do {
                try await BunRuntime.install()
                runtimeOffer = nil
                retryAfterFix()
            } catch {
                runtimeOffer = nil
                items.append(Item(kind: .error(error.localizedDescription)))
                state = .failed
            }
        }
    }

    func declineRuntime() {
        runtimeOffer = nil
        items.append(Item(kind: .error("\(agent.name) needs Node 22 or newer, or the Bun download. Install Node, then send again.")))
        state = .failed
    }

    func signIn(_ method: AuthMethod) {
        if method.type == "terminal" {
            TerminalLauncher.open(agent: agent, method: method)
            return
        }
        Task {
            do {
                try await acp?.authenticate(method)
                signInOptions = []
                retryAfterFix()
            } catch {
                items.append(Item(kind: .error("Sign-in failed: \(error.localizedDescription)")))
            }
        }
    }

    private static func presentTense(_ summary: String) -> String {
        for (past, present) in [("Ran ", "Running "), ("Edited ", "Editing "), ("Read ", "Reading "),
                                ("Deleted ", "Deleting "), ("Searched ", "Searching ")] where summary.hasPrefix(past) {
            return present + summary.dropFirst(past.count)
        }
        return summary
    }

    private func ask(title: String, detail: String, respond: @escaping (ApprovalDecision) -> Void) {
        let approval = Approval(title: title, detail: detail, responders: [respond])
        if let previous = decided[approval.key] { return respond(previous ? .allow : .deny()) }
        if let index = approvals.firstIndex(where: { $0.key == approval.key }) {
            approvals[index].responders.append(respond)
            return
        }
        approvals.append(approval)
        if let chat = telegramChat { onTelegram?(chat, .approval(id: approval.id, title: approval.title, detail: approval.detail)) }
        if !isVisible { onApprovalNeeded?(approval) }
    }

    private func handle(_ event: AgentEvent, turn: UUID) {
        guard turn == turnID else { return }
        switch event {
        case .session(let id):
            // The agent started a fresh session because it could not resume the old one. The chat keeps its thread
            // and transcript; only the agent's own context starts over.
            if let current = threadID, current != id {
                ChatLog.note("agent session \(id) replaced unresumable \(current); chat thread and \(items.count) items kept")
            } else {
                threadID = id
            }
            // Saved now, not only when the turn ends, so quitting mid-run keeps the question.
            saveThread()
        case .models(_, let list):
            models = list
            UserDefaults.standard.set(list.map { [$0.id, $0.name] }, forKey: "cachedModels.\(agent.id)")
            if let model, !list.isEmpty, !list.contains(where: { $0.id == model }) { self.model = nil }
        case .commands(let list):
            receiveCommands(list)
        case .toolUpdated, .subagentTool:
            applyTranscript(event)
        case .needsSignIn(let methods):
            endTurn()
            signInOptions = methods
            items.append(Item(kind: .error("\(agent.name) needs you to sign in.")))
            state = .failed
            finishTelegramTurn(error: "\(agent.name) needs you to sign in on the Mac.")
            restoreQueue(reason: "\(agent.name) needs you to sign in on the Mac.")
        case .needsRuntime:
            endTurn()
            // Not a failure: the chat waits for the user to allow the download.
            runtimeOffer = agent.name
            state = .idle
            finishTelegramTurn(error: "\(agent.name) needs a runtime download. Approve it on the Mac.")
            restoreQueue(reason: "\(agent.name) needs a runtime download. Approve it on the Mac.")
        case .assistant, .toolStarted, .toolFinished:
            applyTranscript(event)
        case .finished(let error):
            endTurn()
            if let error { items.append(Item(kind: .error(error))) }
            state = error == nil ? .done : .failed
            let hidden = error == nil && hideQuietTurn()
            saveThread()
            // Before the queue moves on: the next message replaces the Telegram chat this turn belongs to.
            finishTelegramTurn(error: error, noChange: hidden)
            if !isVisible, !hidden {
                let name = ConfigStore.shared.config.pet.name
                onAttention?(error == nil ? "\(name) finished your task" : "\(name)'s task failed")
            }
            // The switch comes first: the quiet check starts polling the microphone list, which must not happen while off.
            if error == nil, turnSpoken, !hidden, speech.isEnabled(), !isQuiet(), let answer = lastAnswerItem(),
               case .assistant(let text) = answer.kind {
                speech.speak(text, id: answer.id)
            }
            turnSpoken = false
            if error == nil { sendNextQueued() } else { restoreQueue(reason: "The turn before it failed, so this message did not run.") }
        }
    }

    /// Updates that arrive after the turn ended, such as a background subagent's result. They join the transcript
    /// without a turn, so the chat stays idle and new messages start at once. An update that lands while the next
    /// turn is still connecting joins that turn's reply instead of being lost.
    func handleBackground(_ event: AgentEvent) {
        switch event {
        case .assistant, .toolStarted, .toolUpdated, .toolFinished, .subagentTool: applyTranscript(event)
        default: break
        }
    }

    /// Text and tool items. Outside a running turn, text opens a new item instead of extending the last reply.
    private func applyTranscript(_ event: AgentEvent) {
        switch event {
        case .assistant(let text):
            if isRunning { activity = "Writing" }
            if case .assistant(let previous) = items.last?.kind, isRunning || items.last?.id == backgroundReply {
                items[items.count - 1].kind = .assistant(previous + text)
            } else {
                let item = Item(kind: .assistant(text))
                backgroundReply = isRunning ? nil : item.id
                items.append(item)
            }
        case .toolStarted(let id, let summary):
            if isRunning { activity = Self.presentTense(summary) }
            let item = Item(kind: .tool(summary, ok: nil))
            toolBase[id] = summary
            toolItems[id] = item.id
            items.append(item)
        case .toolUpdated(let id, let summary):
            if let itemID = toolItems[id], let index = items.firstIndex(where: { $0.id == itemID }),
               case .tool(_, let ok) = items[index].kind {
                toolBase[id] = summary
                items[index].kind = .tool(composedSummary(id), ok: ok)
            }
        case .subagentTool(let parent, let id, let summary, let ok):
            // A subagent's calls count on its own row. They never open an item, so the reply's text keeps one message.
            if isRunning, ok == nil { activity = Self.presentTense(summary) }
            var calls = subagentCalls[parent] ?? []
            if let index = calls.firstIndex(where: { $0.id == id }) { calls[index].ok = ok } else { calls.append((id, ok)) }
            subagentCalls[parent] = calls
            if let itemID = toolItems[parent], let index = items.firstIndex(where: { $0.id == itemID }),
               case .tool(_, let parentOK) = items[index].kind {
                items[index].kind = .tool(composedSummary(parent), ok: parentOK)
            }
            if !isRunning { saveThread() }
        case .toolFinished(let id, let ok):
            if isRunning { activity = "Thinking" }
            if let itemID = toolItems[id], let index = items.firstIndex(where: { $0.id == itemID }),
               case .tool(let summary, _) = items[index].kind {
                items[index].kind = .tool(summary, ok: ok)
            }
            if !isRunning { saveThread() }
        default:
            break
        }
    }

    /// A tool row's summary with its subagent's tool-call count, e.g. "Run research · 3 tool calls".
    private func composedSummary(_ id: String) -> String {
        let base = toolBase[id] ?? ""
        let count = subagentCalls[id]?.count ?? 0
        guard count > 0 else { return base }
        return "\(base) · \(count) tool call\(count == 1 ? "" : "s")"
    }

    private func endTurn() {
        turnID = nil
        activity = nil
        lastRunDuration = runStartedAt.map { Date().timeIntervalSince($0) }
        runStartedAt = nil
        for approval in approvals {
            approval.respond(.deny("The run ended"))
            onApprovalResolved?(approval.id)
            if let chat = telegramChat { onTelegram?(chat, .approvalDecided(id: approval.id, outcome: .ended)) }
        }
        approvals = []
        cancelForms()
    }
}
