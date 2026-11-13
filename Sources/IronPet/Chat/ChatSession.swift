import Foundation

/// One quick-chat thread with the pet, backed by headless agent CLI turns (cursor-agent or Claude Code).
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
        /// Cursor checks some tool calls twice (e.g. one file write fires preToolUse twice); identical
        /// requests share one card and one decision.
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
    @Published private var cursorModels: [ChatModel] = ModelCatalog.cached
    @Published private(set) var backend: BackendKind =
        BackendKind(rawValue: UserDefaults.standard.string(forKey: "chatBackend") ?? "") ?? .cursor
    /// nil uses the CLI's default model. Stored per backend.
    @Published var model: String? {
        didSet { UserDefaults.standard.set(model, forKey: "chatModel.\(backend.rawValue)") }
    }

    var models: [ChatModel] { backend == .cursor ? cursorModels : ClaudeCodeBackend.models }

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
    private var runner: CLIBackend?
    private var toolItems: [String: UUID] = [:]
    /// Decisions made during the current run, so a repeated identical check isn't asked twice.
    private var decided: [String: Bool] = [:]
    private var dictationTimer: Timer?
    private var prefilling = false

    /// Cursor preToolUse tools allowed without asking. Shell is gated on beforeShellExecution, MCP on beforeMCPExecution.
    static let cursorUngated: Set<String> = ["Read", "Grep", "Glob", "LS", "SemanticSearch", "ReadLints", "WebSearch",
                                             "WebFetch", "TodoWrite", "Shell"]
    /// Claude Code tools that change files; Bash is handled as a shell command. Everything else is allowed.
    static let claudeEditTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    static let destructive = try! NSRegularExpression(pattern: #"""
        \brm\s+-[a-zA-Z]*(rf|fr)|\brm\s+-[a-zA-Z]*r[a-zA-Z]*\s+-[a-zA-Z]*f|git\s+reset\s+--hard|git\s+push\b.*(--force|\s-f\b)|git\s+clean\s+-[a-zA-Z]*f|\bdrop\s+(table|database|schema)\b|\btruncate\s+table\b|\bmkfs\b|\bdd\s+if=
        """#, options: [.caseInsensitive])

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
        model = UserDefaults.standard.string(forKey: "chatModel.\(backend.rawValue)")
            ?? (backend == .cursor ? UserDefaults.standard.string(forKey: "chatModel") : nil)
        Task { cursorModels = await ModelCatalog.refresh() }
        if restore { restoreLastChat() }
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

    func setBackend(_ kind: BackendKind) {
        guard kind != backend, !isRunning else { return }
        backend = kind
        UserDefaults.standard.set(kind.rawValue, forKey: "chatBackend")
        model = UserDefaults.standard.string(forKey: "chatModel.\(kind.rawValue)")
        if !items.isEmpty { newChat() }
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

    func newChat() {
        stop()
        items = []
        threadID = nil
        autoMode = false
        state = .idle
        lastRunDuration = nil
    }

    func open(_ thread: ChatThread) {
        stop()
        apply(thread)
    }

    private func apply(_ thread: ChatThread) {
        let kind = thread.backend ?? .cursor
        if kind != backend {
            backend = kind
            UserDefaults.standard.set(kind.rawValue, forKey: "chatBackend")
            model = UserDefaults.standard.string(forKey: "chatModel.\(kind.rawValue)")
        }
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
                                    items: items, backend: backend))
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
        // Approvals (and the destructive-command guard in Auto mode) run through the agent's hooks; without them the
        // agent could edit and run things unchecked, so don't start.
        let hookAgent: HookInstaller.Agent = backend == .cursor ? .cursor : .claude
        guard HookInstaller().isInstalled(hookAgent) else {
            items.append(Item(kind: .error(
                "\(ConfigStore.shared.config.pet.name) needs the \(hookAgent.displayName) hooks to ask before editing files or running commands. Turn on Watch \(hookAgent.displayName) in Settings (⌘,), then send again.")))
            state = .failed
            return
        }
        if prompt.isEmpty { prompt = "Help me with what's on my screen." }
        input = ""
        let shots = attachments
        attachments = []
        items += shots.map { Item(kind: .screenshot($0.path)) }
        items.append(Item(kind: .user(prompt)))
        state = .running
        activity = "Thinking"
        runStartedAt = Date()
        lastRunDuration = nil
        decided = [:]
        let runner = backend.make()
        self.runner = runner
        var request = prompt
        if !shots.isEmpty {
            request = "Screenshot\(shots.count > 1 ? "s" : "") of my screen (open and look at \(shots.count > 1 ? "them" : "it") first): "
                + shots.map(\.path).joined(separator: ", ") + "\n\n" + prompt
        }
        let fullPrompt = threadID == nil ? Memory.preamble(for: workspace) + "\n" + request : request
        do {
            try runner.start(RunRequest(prompt: fullPrompt, workspace: workspace, resume: threadID, auto: autoMode, model: model)) {
                [weak self] event in self?.handle(event, from: runner)
            }
        } catch {
            self.runner = nil
            items.append(Item(kind: .error(error.localizedDescription)))
            activity = nil
            runStartedAt = nil
            state = .failed
        }
    }

    func stop() {
        runner?.stop()
        runner = nil
        for approval in approvals {
            approval.respond(.deny("Stopped in ironpet"))
            onApprovalResolved?(approval.id)
        }
        approvals = []
        activity = nil
        runStartedAt = nil
        if state == .running { state = .idle }
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

    func handleApproval(_ request: ApprovalRequest, respond: @escaping (ApprovalDecision) -> Void) {
        guard let runner, request.runID == runner.runID else { return respond(.deny("Unknown ironpet run")) }
        let input = request.payload["tool_input"] as? [String: Any] ?? [:]
        let tool = request.payload["tool_name"] as? String ?? "a tool"

        switch request.event {
        case "beforeShellExecution":
            gateShell(request.payload["command"] as? String ?? "", respond: respond)
        case "beforeMCPExecution":
            gateMCP(tool: tool, input: request.payload["tool_input"], server: (request.payload["url"] ?? request.payload["command"]) as? String,
                    respond: respond)
        case "PreToolUse" where tool.hasPrefix("mcp__"):
            let parts = tool.components(separatedBy: "__")
            gateMCP(tool: parts.last ?? tool, input: request.payload["tool_input"], server: parts.count > 2 ? parts[1] : nil,
                    respond: respond)
        case "PreToolUse" where tool == "Bash":
            gateShell(input["command"] as? String ?? "", respond: respond)
        case "PreToolUse" where !Self.claudeEditTools.contains(tool):
            respond(.allow)
        case "preToolUse" where Self.cursorUngated.contains(tool) || tool.hasPrefix("MCP:"):
            // Cursor reports MCP calls as "MCP:<tool>" here and again on beforeMCPExecution, which gates them.
            respond(.allow)
        default:
            let path = (input["file_path"] ?? input["path"] ?? input["target_file"] ?? input["notebook_path"]) as? String
            if autoMode || path.map(Memory.contains) == true { return respond(.allow) }
            let preview = ((input["content"] ?? input["new_string"] ?? input["new_source"]) as? String)?
                .split(separator: "\n", omittingEmptySubsequences: false).prefix(8).joined(separator: "\n")
            let title = path.map { "\(tool) \(URL(fileURLWithPath: $0).lastPathComponent)?" } ?? "Use \(tool)?"
            ask(title: title, detail: [path, preview].compactMap { $0 }.joined(separator: "\n\n"), respond: respond)
        }
    }

    /// MCP tool name prefixes treated as read-only (e.g. Sentry `search_issues`, Langfuse `getHealth`).
    static let readOnlyMCPVerbs = ["get", "list", "search", "find", "fetch", "read", "describe", "whoami", "lookup", "show", "count"]

    static func isReadOnlyMCP(_ tool: String) -> Bool {
        let name = tool.lowercased()
        return readOnlyMCPVerbs.contains { name == $0 || name.hasPrefix($0 + "_") || name.hasPrefix($0) && tool.dropFirst($0.count).first?.isUppercase == true }
    }

    /// MCP servers can change real systems (databases, issue trackers), so anything not read-only asks first.
    private func gateMCP(tool: String, input: Any?, server: String?, respond: @escaping (ApprovalDecision) -> Void) {
        if Self.isReadOnlyMCP(tool) { return respond(.allow) }
        let arguments: String
        if let text = input as? String {
            arguments = text
        } else if let object = input, JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            arguments = String(decoding: data, as: UTF8.self)
        } else {
            arguments = ""
        }
        let dangerous = Self.destructive.firstMatch(in: arguments, range: NSRange(arguments.startIndex..., in: arguments)) != nil
        if autoMode, !dangerous { return respond(.allow) }
        let host = server.map { URL(string: $0)?.host ?? $0 }
        let title = (dangerous ? "Run a destructive tool: " : "Use ") + tool + (host.map { " (\($0))" } ?? "") + "?"
        ask(title: title, detail: String(arguments.prefix(600)), respond: respond)
    }

    private func gateShell(_ command: String, respond: @escaping (ApprovalDecision) -> Void) {
        let dangerous = Self.destructive.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
        if autoMode, !dangerous { return respond(.allow) }
        ask(title: dangerous ? "Run a destructive command?" : "Run this command?", detail: command, respond: respond)
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

    private func handle(_ event: AgentEvent, from source: CLIBackend) {
        guard source === runner else { return }
        switch event {
        case .session(let id):
            threadID = id
            // Saved now, not only when the turn ends, so quitting mid-run keeps the question.
            saveThread()
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
            runner = nil
            activity = nil
            lastRunDuration = runStartedAt.map { Date().timeIntervalSince($0) }
            runStartedAt = nil
            for approval in approvals {
                approval.respond(.deny("The run ended"))
                onApprovalResolved?(approval.id)
            }
            approvals = []
            if let error { items.append(Item(kind: .error(error))) }
            state = error == nil ? .done : .failed
            saveThread()
            if !isVisible {
                let name = ConfigStore.shared.config.pet.name
                onAttention?(error == nil ? "\(name) finished your task" : "\(name)'s task failed")
            }
        }
    }
}
