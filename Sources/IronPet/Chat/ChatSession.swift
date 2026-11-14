import Combine
import Foundation

/// One quick-chat thread with the pet, driven over ACP by whichever coding agent the user picked.
@MainActor
final class ChatSession: ObservableObject {
    enum State { case idle, running, done, failed }

    struct Item: Identifiable, Codable {
        enum Kind: Codable {
            case user(String)
            case screenshot(String)
            case assistant(String)
            case tool(String, ok: Bool?)
            case error(String)
        }
        var id = UUID()
        var kind: Kind
        var date: Date? = Date()
    }

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

    @Published var items: [Item] = []
    @Published var input = "" {
        didSet { if persists { UserDefaults.standard.set(input, forKey: Self.draftKey) } }
    }
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
    @Published private(set) var history: [ChatThread] = ThreadStore.recent()
    @Published var attachments: [URL] = [] {
        didSet { if persists { UserDefaults.standard.set(attachments.map(\.path), forKey: Self.attachmentsKey) } }
    }
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
    var isVisible = false

    private var threadID: String? {
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
    private var toolItems: [String: UUID] = [:]
    /// Decisions made during the current run, so a repeated identical check isn't asked twice.
    private var decided: [String: Bool] = [:]
    private var dictationTimer: Timer?
    private var prefilling = false
    let voice = VoiceController()
    private var voiceChanges: AnyCancellable?
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
        agents = [agent]
        if restore { Task { await refreshAgents() } }
        if restore { restoreLastChat() }
        // Phase changes are rare (start, stop, result), so forwarding them re-renders the composer only then.
        voiceChanges = voice.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        voice.onTranscript = { [weak self] in self?.receiveTranscript($0) }
        voice.onFailure = { [weak self] message, canRetry in self?.voiceFailed(message, canRetry: canRetry) }
    }

    /// A voice note's text goes into the input to edit, or is sent straight away when "Send after dictation" is on, the same switch Wispr Flow dictation uses.
    /// It is not run through the dictation heuristics, which would send any multi-word insert.
    func receiveTranscript(_ text: String) {
        let existing = input.trimmingCharacters(in: .whitespacesAndNewlines)
        prefilling = true
        input = existing.isEmpty ? text : existing + " " + text
        if sendAfterDictation { send() }
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
        // Read Auto first: apply(_:) turns Auto off, and its didSet would overwrite the saved value.
        let savedAuto = defaults.bool(forKey: Self.autoKey)
        if let id = defaults.string(forKey: Self.threadKey), let thread = ThreadStore.load(id) {
            apply(thread.restoredAfterQuit())
            autoMode = savedAuto
        }
        input = defaults.string(forKey: Self.draftKey) ?? ""
        attachments = (defaults.stringArray(forKey: Self.attachmentsKey) ?? [])
            .map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Writes the open thread to disk, e.g. when the app quits mid-run.
    func persistForRelaunch() {
        guard persists else { return }
        saveThread()
    }

    var mood: PetMood? {
        if !approvals.isEmpty { return .needsInput }
        switch state {
        case .running: return .working
        case .done: return .done
        case .failed: return .failed
        case .idle: return isVisible ? .listening : nil
        }
    }

    var isRunning: Bool { state == .running }

    /// Picks the folder from the app the user came from. Outside a coding app, a new chat asks instead
    /// of silently reusing the last folder; an ongoing chat keeps its folder.
    func prepareForShow(detected: URL?) {
        if state == .done || state == .failed, approvals.isEmpty { state = .idle }
        guard !isRunning else { return }
        if let detected {
            use(detected)
        } else if items.isEmpty {
            needsWorkspace = true
        }
    }

    func use(_ url: URL) {
        let changed = workspace != url
        workspace = url
        needsWorkspace = false
        if url != Self.scratchWorkspace {
            recents = [url] + recents.filter { $0 != url }.prefix(7)
            UserDefaults.standard.set(recents.map(\.path), forKey: "recentWorkspaces")
        }
        if changed, !items.isEmpty, !isRunning { newChat() }
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
        select(next)
        if !items.isEmpty { newChat() }
    }

    private func select(_ next: ACPAgent) {
        agent = next
        UserDefaults.standard.set(next.id, forKey: "chatAgent")
        model = UserDefaults.standard.string(forKey: "chatModel.\(next.id)")
        models = Self.cachedModels(for: next)
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
    enum Preview { case done, approval, markdown }

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
        }
    }

    func attach(_ screenshot: URL) {
        attachments.append(screenshot)
    }

    /// Appends files to the current attachments, skipping ones already there.
    func attach(_ files: [URL]) {
        attachments += files.filter { !attachments.contains($0) }
    }

    func newChat() {
        stop()
        shutdownAgent()
        items = []
        threadID = nil
        autoMode = false
        state = .idle
        lastRunDuration = nil
    }

    func open(_ thread: ChatThread) {
        stop()
        shutdownAgent()
        apply(thread)
    }

    private func apply(_ thread: ChatThread) {
        if let saved = AgentCatalog.agent(id: thread.agent), saved != agent { select(saved) }
        items = thread.items
        threadID = thread.id
        autoMode = false
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
        ThreadStore.save(ChatThread(id: threadID, title: title, workspace: workspace.path, updatedAt: Date(),
                                    items: items, agent: agent.id))
        history = ThreadStore.recent()
    }

    func send() {
        dictationTimer?.invalidate()
        var prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !attachments.isEmpty, !isRunning else { return }
        guard !needsWorkspace, let workspace else {
            needsWorkspace = true
            return
        }
        if prompt.isEmpty { prompt = "Help me with what's on my screen." }
        input = ""
        let shots = attachments
        attachments = []
        items += shots.map { Item(kind: .screenshot($0.path)) }
        items.append(Item(kind: .user(prompt)))
        let preamble = threadID == nil ? Memory.preamble(for: workspace) : nil
        run(ACPTurn(prompt: prompt, preamble: preamble, workspace: workspace, resume: threadID, model: model,
                    images: shots.filter(ImageIntake.isImageFile), files: shots.filter { !ImageIntake.isImageFile($0) }))
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
        if agent.id == "cursor", Config.load().config.integrations.shareMCPSignIns { MCPAuthSharing.prepare(workspace: turn.workspace) }
        let backend = acp?.agent == agent ? acp! : makeBackend()
        let id = UUID()
        turnID = id
        Task { [weak self] in
            await backend.runTurn(turn) { event in self?.handle(event, turn: id) }
        }
    }

    private func makeBackend() -> ACPBackend {
        acp?.shutdown()
        let backend = ACPBackend(agent: agent)
        backend.onPermission = { [weak self] call, respond in self?.handlePermission(call, respond: respond) }
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
        turnID = nil
        acp?.cancel()
        for approval in approvals {
            approval.respond(.deny("Stopped in ironpet"))
            onApprovalResolved?(approval.id)
        }
        approvals = []
        activity = nil
        runStartedAt = nil
        if state == .running { state = .idle }
    }

    /// Stops the agent process for good, e.g. when the app quits.
    func shutdown() {
        stop()
        shutdownAgent()
    }

    /// Text delivered by the Wispr Flow bridge. Skipped if Wispr managed to type it into the field itself.
    func receiveDictation(_ text: String) {
        guard !input.trimmingCharacters(in: .whitespaces).hasSuffix(text) else { return }
        input = input.isEmpty ? text : input + " " + text
        scheduleAutoSend()
    }

    /// Puts text in the input for the user to review; unlike a dictation it is not sent automatically.
    func prefill(_ text: String) {
        prefilling = true
        input = text
    }

    /// Wispr Flow inserts a whole dictation at once; typing grows the text one character at a time.
    func inputChanged(from old: String, to new: String) {
        if prefilling {
            prefilling = false
            return
        }
        if new.count - old.count >= 4 { scheduleAutoSend() }
    }

    private func scheduleAutoSend() {
        guard sendAfterDictation else { return }
        dictationTimer?.invalidate()
        dictationTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.send() }
        }
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
        if !isVisible { onApprovalNeeded?(approval) }
    }

    private func handle(_ event: AgentEvent, turn: UUID) {
        guard turn == turnID else { return }
        switch event {
        case .session(let id):
            threadID = id
            // Saved now, not only when the turn ends, so quitting mid-run keeps the question.
            saveThread()
        case .models(_, let list):
            models = list
            UserDefaults.standard.set(list.map { [$0.id, $0.name] }, forKey: "cachedModels.\(agent.id)")
            if let model, !list.isEmpty, !list.contains(where: { $0.id == model }) { self.model = nil }
        case .toolUpdated(let id, let summary):
            if let itemID = toolItems[id], let index = items.firstIndex(where: { $0.id == itemID }),
               case .tool(_, let ok) = items[index].kind {
                items[index].kind = .tool(summary, ok: ok)
            }
        case .needsSignIn(let methods):
            endTurn()
            signInOptions = methods
            items.append(Item(kind: .error("\(agent.name) needs you to sign in.")))
            state = .failed
        case .needsRuntime:
            endTurn()
            // Not a failure: the chat waits for the user to allow the download.
            runtimeOffer = agent.name
            state = .idle
        case .assistant(let text):
            activity = "Writing"
            if case .assistant(let previous) = items.last?.kind {
                items[items.count - 1].kind = .assistant(previous + text)
            } else {
                items.append(Item(kind: .assistant(text)))
            }
        case .toolStarted(let id, let summary):
            activity = Self.presentTense(summary)
            let item = Item(kind: .tool(summary, ok: nil))
            toolItems[id] = item.id
            items.append(item)
        case .toolFinished(let id, let ok):
            activity = "Thinking"
            if let itemID = toolItems[id], let index = items.firstIndex(where: { $0.id == itemID }),
               case .tool(let summary, _) = items[index].kind {
                items[index].kind = .tool(summary, ok: ok)
            }
        case .finished(let error):
            endTurn()
            if let error { items.append(Item(kind: .error(error))) }
            state = error == nil ? .done : .failed
            saveThread()
            if !isVisible {
                let name = ConfigStore.shared.config.pet.name
                onAttention?(error == nil ? "\(name) finished your task" : "\(name)'s task failed")
            }
        }
    }

    private func endTurn() {
        turnID = nil
        activity = nil
        lastRunDuration = runStartedAt.map { Date().timeIntervalSince($0) }
        runStartedAt = nil
        for approval in approvals {
            approval.respond(.deny("The run ended"))
            onApprovalResolved?(approval.id)
        }
        approvals = []
    }
}
