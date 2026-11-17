import AppKit

/// End-to-end test hooks, served at `/test/*` only when ironpet runs with `--test-mode`.
/// They drive the same code paths as the UI (show chat, send, Allow/Deny, notification click, capture),
/// so `scripts/e2e.sh` can exercise real agent runs without UI automation.
@MainActor
final class TestControl {
    static var isEnabled: Bool { CommandLine.arguments.contains("--test-mode") }

    struct Actions {
        let showChat: () -> Void
        /// Sends the "build a new pet" request as the gallery tile does.
        let buildPet: (String) -> Void
        /// The ironpet window's frame while it shows Chat, in top-left screen coordinates, for `screencapture -R`.
        let chatWindowID: () -> Int
        let chatFrame: () -> CGRect
        let openSession: (String) -> Void
        /// Scrolls the chat transcript to `fraction` (0 top, 1 bottom) as a reader would, when given, and saves a PNG of the
        /// chat to `snapshotPath` when given. Returns its geometry.
        let scrollChat: (_ fraction: Double?, _ snapshotPath: String?) -> [String: Any]
        let showSettings: (_ tab: String?, _ snapshot: String?) -> Int
        let capture: (Bool) -> Void
        /// The handler a notification's Allow / Deny button calls.
        let notificationAction: (UUID, Bool) -> Void
        let signals: SignalStore
        let meeting: MeetingController
        /// The meeting panel's frame in top-left screen coordinates, or `.zero` while it is hidden.
        let meetingFrame: () -> CGRect
        /// The title of the pet menu's meeting item, or "" when the menu has none.
        let meetingMenuTitle: () -> String
        /// Whether the meeting bubble is on screen, and whether the pet shows its Recording button.
        let meetingUI: () -> (bubble: Bool, button: Bool)
        /// Closes the meeting bubble as the user would (`false`), or clicks the pet's Recording button (`true`).
        let meetingBubble: (_ show: Bool) -> Void
        let telegram: TelegramBridge
        /// Plays a call event for an app as if the detector had reported it: "started", "ended", "record" or "not-now".
        let simulateCall: (_ bundleID: String, _ event: String) -> Void
        /// The title of the call bubble on screen, or "".
        let callOffer: () -> String
        let automations: AutomationService
        /// Moves the automation clock forward, so a test does not wait in real time.
        let advanceClock: (TimeInterval) -> Void
        /// The bubbles on screen: id, title, body and the titles of their buttons.
        let bubbles: () -> [[String: Any]]
        /// Presses the button with this title on the bubble with this id. False when there is none.
        let pressBubbleButton: (_ id: String, _ title: String) -> Bool
    }

    private let chat: ChatSession
    private let actions: Actions
    private(set) var attention: [[String: String]] = []
    /// What the app does with a finished meeting summary (mine action items, suggest them, show the bubble), so
    /// `/test/tasks/suggest` runs that path. Without it the endpoint only mines and suggests.
    var onMeetingSummaryText: ((String, URL) -> Void)?
    /// Screen capture, for the `/test/screen/*` endpoints. They feed synthetic captures in, so no test reads the real screen.
    var screen: CaptureService?
    private(set) var proposals: [CaptureProposal] = []
    /// Shows a proposal as the analyzer's result would, with its Add, Edit and Ignore buttons.
    var showProposal: ((CaptureProposal) -> Void)?
    /// Opens the capture viewer and returns its window number.
    var showInspector: (() -> Int)?
    /// The welcome back summary, and the stand-in for the system idle time it samples (nil gives the real one back).
    var welcomeBack: WelcomeBack?
    var setIdleSeconds: ((TimeInterval?) -> Void)?
    /// Builds the brief or the recap from the stores, as a `digest` automation would.
    var buildBrief: ((Brief.Kind) -> Brief?)?
    /// The ironpet window: visible, section, whether Today is listed and which page it shows.
    var windowState: (() -> [String: Any])?
    /// Presses a Today row, as a click would.
    var openBrief: ((Brief.Target) -> Void)?

    func recordProposal(_ proposal: CaptureProposal) {
        proposals.append(proposal)
    }

    init(chat: ChatSession, actions: Actions) {
        self.chat = chat
        self.actions = actions
    }

    func recordAttention(_ session: AgentSession) {
        attention.append(["session": session.id, "status": session.status.label, "workspace": session.workspaceName,
                          "iterm": session.origin.itermSessionID ?? ""])
    }

    func handle(_ request: HTTPRequest) -> Data {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        if request.path.hasPrefix("/test/task-runs") { return handleTaskRuns(request.method, request.path, body) }
        switch (request.method, request.path) {
        case ("GET", "/test/chat"):
            break
        case ("POST", "/test/show-chat"):
            if body["newChat"] as? Bool == true {
                chat.newChat()
                chat.input = ""
            }
            actions.showChat()
        case ("POST", "/test/chat"):
            actions.showChat()
            if body["newChat"] as? Bool == true { chat.newChat() }
            if let raw = (body["agent"] ?? body["backend"]) as? String, let agent = AgentCatalog.agent(id: raw) { chat.setAgent(agent) }
            if let raw = body["model"] as? String { chat.model = raw.isEmpty ? nil : raw }
            if body["noProject"] as? Bool == true { chat.useNoProject() }
            if let path = body["workspace"] as? String { chat.use(URL(fileURLWithPath: path)) }
            if let auto = body["auto"] as? Bool { chat.autoMode = auto }
            chat.input = body["prompt"] as? String ?? ""
            chat.send()
        case ("POST", "/test/build-pet"):
            let description = (body["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty else { return Self.encode(["ok": false, "error": "description is required"]) }
            actions.buildPet(description)
            return Self.encode(["ok": true])
        case ("POST", "/test/approve"):
            guard let first = chat.approvals.first else { return Self.encode(["ok": false, "error": "no pending approval"]) }
            chat.decide(first, allow: body["allow"] as? Bool ?? false)
            return Self.encode(["ok": true, "title": first.title])
        case ("GET", "/test/cursor"):
            // The cursor the app has pushed or set, for checking pointing-hand hover without a screenshot.
            let cursor = NSCursor.current
            let name = cursor == NSCursor.pointingHand ? "pointingHand" : cursor == NSCursor.arrow ? "arrow"
                : cursor == NSCursor.iBeam ? "iBeam" : "other"
            return Self.encode(["cursor": name])
        case ("POST", "/test/scroll"):
            return Self.encode(actions.scrollChat(body["fraction"] as? Double, body["snapshot"] as? String))
        case ("POST", "/test/open-session"):
            actions.openSession(body["session"] as? String ?? "")
            return Self.encode(["ok": true])
        case ("POST", "/test/capture"):
            guard ScreenCapture.hasPermission else { return Self.encode(["ok": false, "permission": false]) }
            actions.capture(body["region"] as? Bool ?? false)
            return Self.encode(["ok": true, "permission": true])
        case ("GET", "/test/attention"):
            return Self.encode(["events": attention])
        case ("POST", "/test/notification-action"):
            guard let first = chat.approvals.first else { return Self.encode(["ok": false, "error": "no pending approval"]) }
            actions.notificationAction(first.id, body["allow"] as? Bool ?? false)
            return Self.encode(["ok": true, "title": first.title])
        case ("POST", "/test/voice/start"):
            // Records from a WAV file instead of the microphone, through the same states and UI.
            guard ConfigStore.shared.config.voice.enabled else { return Self.encode(["ok": false, "error": "voice notes are off"]) }
            guard let path = body["file"] as? String, FileManager.default.fileExists(atPath: path) else {
                return Self.encode(["ok": false, "error": "file is missing"])
            }
            actions.showChat()
            if body["newChat"] as? Bool == true {
                chat.newChat()
                chat.input = ""
            }
            if let auto = body["autoSend"] as? Bool { chat.sendAfterDictation = auto }
            if let workspace = body["workspace"] as? String { chat.use(URL(fileURLWithPath: workspace)) }
            chat.voice.start(.file(URL(fileURLWithPath: path)))
        case ("POST", "/test/voice/stop"):
            chat.voice.stop()
        case ("POST", "/test/show-settings"):
            // "light" or "dark" forces the app's appearance, for screenshots; anything else leaves the system's.
            if let name = body["appearance"] as? String { NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua) }
            return Self.encode(["windowId": actions.showSettings(body["tab"] as? String, body["snapshot"] as? String)])
        case ("POST", "/test/stop"):
            chat.stop()
        case ("POST", "/test/seed-transcript"):
            // Replaces the open chat's items with the `items` of a saved thread JSON, as a resumed long session would.
            guard let path = body["file"] as? String, let data = FileManager.default.contents(atPath: path) else {
                return Self.encode(["ok": false, "error": "file is missing"])
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // Threads saved before ACP have no "agent", so decode only the items.
            struct Saved: Decodable { var items: [ChatSession.Item] }
            guard let thread = try? decoder.decode(Saved.self, from: data) else { return Self.encode(["ok": false, "error": "not a thread"]) }
            chat.newChat()
            actions.showChat() // before the items, because showing can start a new chat for the detected folder
            chat.items = thread.items
            return Self.encode(["ok": true, "items": thread.items.count])
        case ("POST", "/test/stream-reply"):
            // Grows one assistant reply by `tokens` words, as a streamed turn does.
            let tokens = max(0, min((body["tokens"] as? Int) ?? 2000, 100_000))
            chat.items.append(.init(kind: .assistant("")))
            let id = chat.items[chat.items.count - 1].id
            Task { @MainActor in
                var text = ""
                for i in 0..<tokens {
                    text += "tok\(i) "
                    guard let index = chat.items.firstIndex(where: { $0.id == id }) else { return }
                    chat.items[index].kind = .assistant(text)
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            return Self.encode(["ok": true])
        case ("POST", "/test/open-thread"):
            guard let thread = chat.history.first(where: { $0.id == body["id"] as? String }) ?? (body["id"] == nil ? chat.history.first : nil) else {
                return Self.encode(["ok": false, "error": "no such thread"])
            }
            actions.showChat()
            chat.open(thread)
        case ("POST", "/test/install-runtime"):
            chat.installRuntime()
        case ("POST", "/test/retry"):
            chat.retryAfterFix()
        case ("POST", "/test/voice/cancel"):
            chat.voice.cancel()
        case ("POST", "/test/voice/retry"):
            chat.retryVoice()
        case ("GET", "/test/meeting"):
            return meetingSnapshot()
        case ("POST", "/test/meeting/picker"):
            actions.meeting.showPicker()
            return meetingSnapshot()
        case ("POST", "/test/meeting/start"):
            return startMeeting(body)
        case ("POST", "/test/meeting/stop"):
            actions.meeting.stop()
            return meetingSnapshot()
        case ("POST", "/test/meeting/cancel"):
            // The panel's Cancel button asks first; the test goes straight to what a confirmed Cancel does.
            actions.meeting.discard()
            return meetingSnapshot()
        case ("POST", "/test/meeting/retry"):
            actions.meeting.retryFailed()
            return meetingSnapshot()
        case ("POST", "/test/meeting/hide-bubble"):
            actions.meetingBubble(false)
            return meetingSnapshot()
        case ("POST", "/test/meeting/show-bubble"):
            actions.meetingBubble(true)
            return meetingSnapshot()
        case ("POST", "/test/meeting/call"):
            actions.simulateCall(body["app"] as? String ?? "", body["event"] as? String ?? "started")
            return meetingSnapshot()
        case ("POST", "/test/meeting/dismiss"):
            actions.meeting.dismiss()
            return meetingSnapshot()
        case ("POST", "/test/meeting/open-in-chat"):
            actions.meeting.openInChat()
            return meetingSnapshot()
        case ("GET", "/test/telegram"):
            return telegramSnapshot()
        case ("POST", "/test/telegram/token"):
            return Self.encode(["ok": actions.telegram.saveToken(body["token"] as? String ?? "")])
        case ("POST", "/test/telegram/enable"):
            ConfigStore.shared.update { $0.telegram.enabled = body["enabled"] as? Bool ?? true }
            return telegramSnapshot()
        case ("POST", "/test/telegram/test"):
            telegramTest = "running"
            Task {
                switch await actions.telegram.test() {
                case .success(let name): telegramTest = name
                case .failure(let error): telegramTest = "error: \(error.localizedDescription)"
                }
            }
            return telegramSnapshot()
        case ("POST", "/test/telegram/allow"):
            actions.telegram.allow((body["id"] as? NSNumber)?.int64Value ?? 0)
            return telegramSnapshot()
        case ("POST", "/test/telegram/deny"):
            actions.telegram.deny((body["id"] as? NSNumber)?.int64Value ?? 0)
            return telegramSnapshot()
        case ("GET", "/test/signals"):
            return signalsSnapshot()
        case ("GET", "/test/automations"):
            return automationsSnapshot()
        case ("GET", "/test/automations/logs"):
            let logs = actions.automations.engine.state.logs(automation: body["id"] as? String, limit: 100)
            return Self.encode(["logs": logs.map { ["automation": $0.automation, "outcome": $0.outcome, "summary": $0.summary, "detail": $0.detail,
                                                    "duration": $0.duration, "time": AutomationClock.format($0.date)] as [String: Any] }])
        case ("POST", "/test/automations/advance"):
            actions.advanceClock((body["seconds"] as? NSNumber)?.doubleValue ?? 0)
            actions.automations.engine.tick()
            return automationsSnapshot()
        case ("POST", "/test/automations/tick"):
            actions.automations.engine.tick()
            return automationsSnapshot()
        case ("POST", "/test/automations/stub-prompt"):
            // Answers `prompt` actions without starting an agent.
            let answer = body["answer"] as? String ?? "stub answer"
            actions.automations.runPrompt = { _, _ in .success(answer) }
            return Self.encode(["ok": true])
        case ("POST", "/test/automations/approval"):
            guard let id = body["id"] as? String else { return Self.encode(["ok": false, "error": "id is required"]) }
            if body["approve"] as? Bool == true { actions.automations.approve(id) } else { actions.automations.reject(id) }
            return automationsSnapshot()
        case ("POST", "/test/automations/bubble"):
            // Presses a bubble button by title, as a click would.
            let id = body["id"] as? String ?? "", title = body["button"] as? String ?? ""
            let pressed = actions.pressBubbleButton(id, title)
            return Self.encode(["ok": pressed])
        case ("POST", "/test/presence"):
            // Sets how long the user has been idle, then samples at once when asked, through the same tick as the timer.
            setIdleSeconds?((body["idle"] as? NSNumber)?.doubleValue)
            for id in body["dismiss"] as? [String] ?? [] { welcomeBack?.bubbles.dismiss(id) }
            if body["tick"] as? Bool == true { welcomeBack?.tick() }
            return welcomeBackSnapshot()
        case ("GET", "/test/welcome-back"):
            return welcomeBackSnapshot()
        case ("POST", "/test/digest"):
            guard let kind = Brief.Kind(rawValue: body["kind"] as? String ?? "brief"), let brief = buildBrief?(kind) else {
                return Self.encode(["ok": false, "error": "kind must be brief or recap"])
            }
            return Self.encode(Self.json(brief))
        case ("GET", "/test/window"):
            return Self.encode(windowState?() ?? [:])
        case ("POST", "/test/today/open"):
            // The row with this id on the brief or recap page.
            let kind = Brief.Kind(rawValue: body["kind"] as? String ?? "brief") ?? .brief
            let id = body["item"] as? String ?? ""
            guard let item = buildBrief?(kind)?.sections.flatMap(\.items).first(where: { $0.id == id }) else {
                return Self.encode(["ok": false, "error": "no item \(id)"])
            }
            openBrief?(item.target)
            var result = windowState?() ?? [:]
            result["ok"] = true
            return Self.encode(result)
        case ("GET", "/test/tasks"):
            return tasksSnapshot()
        case ("POST", "/test/tasks/reset"):
            guard let store = TaskStore.shared else { return Self.encode(["ok": false, "error": "no task store"]) }
            for item in store.tasks { try? store.delete(item.id, by: "test") }
            for suggestion in store.suggestions { store.skip(suggestion.id) }
            return tasksSnapshot()
        case ("POST", "/test/tasks/suggest"):
            return suggestTasks(body)
        case ("POST", "/test/tasks/accept-all"):
            guard let store = TaskStore.shared else { return Self.encode(["ok": false, "error": "no task store"]) }
            // The suggestions bubble's Add all when it is on screen, as a click would.
            let bubble = actions.bubbles().first { ($0["buttons"] as? [String])?.contains("Add all") == true }
            let pressed = (bubble?["id"] as? String).map { actions.pressBubbleButton($0, "Add all") } ?? false
            if !pressed { store.acceptAll() }
            var result = (try? JSONSerialization.jsonObject(with: tasksSnapshot())) as? [String: Any] ?? [:]
            result["pressedBubble"] = pressed
            return Self.encode(result)
        case ("GET", "/test/screen"):
            return screenSnapshot()
        case ("POST", "/test/screen/ingest"), ("POST", "/test/screen/filter"), ("POST", "/test/screen/send"), ("POST", "/test/screen/propose"), ("POST", "/test/screen/inspector"), ("POST", "/test/screen/stub"), ("POST", "/test/screen/reset"):
            return screenEndpoint(request.method, request.path, body)
        default:
            return Self.encode(["ok": false, "error": "unknown test endpoint \(request.method) \(request.path)"])
        }
        return snapshot()
    }

    private func screenSnapshot() -> Data {
        guard let screen else { return Self.encode(["ok": false, "error": "screen capture is not built"]) }
        let store = screen.store
        let counts = Dictionary(uniqueKeysWithValues: ["new", "ready", "local", "sent"].map { ($0, store.count(inState: $0)) })
        var status = "unknown"
        var reason = ""
        switch screen.filter.status {
        case .unknown: break
        case .ready(let model): status = "ready"; reason = model
        case .unavailable(let why): status = "unavailable"; reason = why
        }
        return Self.encode([
            "ok": true,
            "enabled": ConfigStore.shared.config.screenCapture.enabled,
            "running": screen.isRunning,
            "items": store.itemCount,
            "states": counts,
            "decision": ["status": status, "reason": reason],
            "tasks": (TaskStore.shared?.tasks ?? []).map { ["id": $0.id, "title": $0.title, "status": $0.status.rawValue, "source": $0.source.rawValue] },
            "sendLog": store.sendLog().map { ["harness": $0.harness, "model": $0.model, "items": $0.items.map(Int.init), "bytes": $0.bytes, "outcome": $0.outcome] },
            "proposals": proposals.map { ["id": $0.id, "kind": $0.kind.rawValue, "title": $0.title] },
            "sending": screen.model.sending,
        ])
    }

    private func screenEndpoint(_ method: String, _ path: String, _ body: [String: Any]) -> Data {
        guard let screen else { return Self.encode(["ok": false, "error": "screen capture is not built"]) }
        switch path {
        case "/test/screen/ingest":
            // A synthetic capture, as the pipeline would store it. `messages` is a list of "Author: text" lines.
            let lines = (body["messages"] as? [String]) ?? []
            let messages = lines.map { line -> CaptureMessage in
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 ? CaptureMessage(author: parts[0], text: parts[1]) : CaptureMessage(text: line)
            }
            let thread = body["thread"] as? String ?? "test:thread"
            let item = CaptureItem(app: CaptureApp(bundleId: body["app"] as? String ?? "com.example.chat", name: body["appName"] as? String ?? "Chat"),
                                   threadKey: thread, threadTitle: body["title"] as? String ?? thread,
                                   content: .conversation(title: thread, isGroup: false, messages: messages), parser: "test")
            let at = Date().addingTimeInterval(-((body["ageSeconds"] as? NSNumber)?.doubleValue ?? 0))
            _ = try? screen.store.ingest(item, now: at)
            screen.scheduleFilter()
        case "/test/screen/stub":
            screen.useStubs(answer: body["answer"] as? String ?? "{}", secretWords: body["secretWords"] as? [String] ?? [])
        case "/test/screen/reset":
            screen.store.clearCaptures()
            screen.store.clearIgnored()
            screen.refreshModel()
        case "/test/screen/inspector":
            return Self.encode(["ok": true, "windowId": showInspector?() ?? 0])
        case "/test/screen/propose":
            let title = body["title"] as? String ?? "Send the invoice"
            let kind = CaptureProposal.Kind(rawValue: body["kind"] as? String ?? "new_task") ?? .newTask
            let proposal = CaptureProposal(id: CaptureStore.fingerprint(kind: kind.rawValue, title: title), kind: kind, title: title, notes: "", due: body["due"] as? String,
                                           taskId: body["taskId"] as? String, status: nil, sources: [1], quote: body["quote"] as? String ?? "", diff: [])
            showProposal?(proposal)
        case "/test/screen/filter":
            Task { let result = await screen.filter.run(on: screen.store, tasks: screen.tasks); if result.ready > 0 { screen.analyzer.noteReady() }; screen.refreshModel() }
        case "/test/screen/send":
            // Sends the pending batch now instead of waiting for the delay.
            Task { _ = await screen.analyzer.run(); screen.refreshModel() }
        default:
            break
        }
        return screenSnapshot()
    }

    /// Files named by `mic` and `them` stand in for the microphone and the app's audio.
    private func startMeeting(_ body: [String: Any]) -> Data {
        let meeting = actions.meeting
        guard ConfigStore.shared.config.meetings.enabled else { return Self.encode(["ok": false, "error": "meetings are off"]) }
        let them = body["them"] as? String
        guard let mic = body["mic"] as? String, FileManager.default.fileExists(atPath: mic),
              them == nil || FileManager.default.fileExists(atPath: them!) else {
            return Self.encode(["ok": false, "error": "mic or them file is missing"])
        }
        var lengths = MeetingController.ChunkLengths()
        if let seconds = (body["chunkSeconds"] as? NSNumber)?.doubleValue, seconds > 0 { lengths = .test(seconds) }
        if let delay = (body["retrySeconds"] as? NSNumber)?.doubleValue { meeting.backoff = { _ in delay } }
        do {
            try meeting.startTest(mic: URL(fileURLWithPath: mic), them: them.map { URL(fileURLWithPath: $0) },
                                  appName: body["app"] as? String ?? "Test audio", lengths: lengths)
        } catch {
            return Self.encode(["ok": false, "error": error.localizedDescription])
        }
        return meetingSnapshot()
    }

    private(set) var meetingNotified: [String] = []

    func recordMeetingNotified(_ url: URL) {
        meetingNotified.append(url.path)
    }

    private func meetingSnapshot() -> Data {
        let meeting = actions.meeting
        let counts = meeting.counts
        let summary: String = switch meeting.summary {
        case .none: "none"
        case .running: "running"
        case .ready: "ready"
        case .failed(let message): "failed: \(message)"
        }
        let frame = actions.meetingFrame()
        return Self.encode([
            "ok": true,
            "phase": meeting.phase.rawValue,
            "chunks": ["done": counts.done, "waiting": counts.waiting, "failed": counts.failed],
            "folder": meeting.folder?.path ?? "",
            "transcript": meeting.transcriptURL?.path ?? "",
            "summary": summary,
            "summaryAgent": meeting.lastSummaryRequest?.agent ?? "",
            "summaryModel": meeting.lastSummaryRequest?.model ?? "",
            "summaryRan": meeting.lastSummaryRequest != nil,
            "notified": meetingNotified,
            "lines": meeting.recentLines.map { "\($0.track.rawValue): \($0.text)" },
            "notice": meeting.notice ?? "",
            "app": meeting.appName,
            "choices": meeting.apps.map(\.name) + ["All system audio"],
            "selected": meeting.choice.name,
            "frame": [frame.minX, frame.minY, frame.width, frame.height],
            "menuTitle": actions.meetingMenuTitle(),
            "callOffer": actions.callOffer(),
            "bubbleShown": actions.meetingUI().bubble,
            "recordingButton": actions.meetingUI().button,
        ])
    }

    private func automationsSnapshot() -> Data {
        let service = actions.automations
        let list = service.store.automations.map { service.detail($0) }
        return Self.encode(["automations": list, "bubbles": actions.bubbles(), "error": service.store.error ?? ""])
    }

    private func welcomeBackSnapshot() -> Data {
        guard let welcomeBack else { return Self.encode(["ok": false, "error": "welcome back is not set up"]) }
        let digest = welcomeBack.lastDigest
        return Self.encode([
            "ok": true,
            "away": welcomeBack.tracker.awaySince != nil,
            "pending": welcomeBack.pendingSince != nil,
            "digest": (digest?.items ?? []).map { ["kind": $0.kind.rawValue, "count": $0.count, "refs": $0.events.map(\.ref)] as [String: Any] },
            "bubbles": actions.bubbles(),
        ])
    }

    private func tasksSnapshot() -> Data {
        guard let store = TaskStore.shared else { return Self.encode(["ok": false, "error": "no task store"]) }
        return Self.encode([
            "ok": true,
            "tasks": store.ordered.map { item -> [String: Any] in
                var object = TaskStore.json(item)
                object["history"] = store.history(item.id).map(TaskStore.json)
                return object
            },
            "suggestions": store.suggestions.map(Self.json),
        ])
    }

    /// `summary` is the markdown of a meeting summary and `meeting` its folder.
    private func suggestTasks(_ body: [String: Any]) -> Data {
        guard let store = TaskStore.shared else { return Self.encode(["ok": false, "error": "no task store"]) }
        guard let summary = body["summary"] as? String, let path = body["meeting"] as? String, !path.isEmpty else {
            return Self.encode(["ok": false, "error": "summary and meeting are required"])
        }
        let meeting = URL(fileURLWithPath: path)
        let before = Set(store.suggestions.map(\.id))
        if let onMeetingSummaryText {
            onMeetingSummaryText(summary, meeting)
        } else {
            store.suggest(ActionItems.suggestions(summary), meeting: meeting)
        }
        return Self.encode([
            "ok": true,
            "appPath": onMeetingSummaryText != nil,
            "created": store.suggestions.filter { !before.contains($0.id) }.map(Self.json),
            "suggestions": store.suggestions.map(Self.json),
            "bubbles": actions.bubbles(),
        ])
    }

    static func json(_ brief: Brief) -> [String: Any] {
        func target(_ t: Brief.Target) -> [String: Any] {
            switch t {
            case .task(let id): return ["type": "task", "id": id]
            case .session(let id, let workspace, let bundleID, let iterm):
                return ["type": "session", "id": id, "workspace": workspace ?? "", "bundleID": bundleID ?? "", "iterm": iterm ?? ""]
            case .alert(let id, let url): return ["type": "alert", "id": id, "url": url?.absoluteString ?? ""]
            case .meeting(let id): return ["type": "meeting", "id": id]
            }
        }
        return ["ok": true, "kind": brief.kind.rawValue, "empty": brief.isEmpty, "lines": brief.lines,
                "sections": brief.sections.map { section in
                    ["id": section.id, "title": section.title, "items": section.items.map { item in
                        ["id": item.id, "title": item.title, "subtitle": item.subtitle ?? "", "target": target(item.target)] as [String: Any]
                    }] as [String: Any]
                }]
    }

    private static func json(_ suggestion: TaskSuggestion) -> [String: Any] {
        var object: [String: Any] = ["id": suggestion.id, "title": suggestion.title, "due": suggestion.due ?? NSNull(),
                                     "meeting": suggestion.meeting?.path ?? NSNull(), "url": suggestion.url?.absoluteString ?? NSNull(),
                                     "waiting_on": suggestion.waitingOn ?? NSNull()]
        if case .automation(let id, let name) = suggestion.origin { object["automation"] = ["id": id, "name": name] }
        return object
    }

    private var telegramTest = ""

    private func telegramSnapshot() -> Data {
        let bridge = actions.telegram
        let status: String = switch bridge.status {
        case .off: "off"
        case .connecting: "connecting"
        case .polling(let bot): "polling \(bot)"
        case .error(let message, _): "error: \(message)"
        }
        let config = ConfigStore.shared.config.telegram
        return Self.encode([
            "enabled": config.enabled, "status": status, "hasToken": bridge.hasToken, "test": telegramTest,
            "pending": bridge.pending.map { ["id": $0.id, "name": $0.user.displayName] },
            "users": config.allowedUsers.map { ["id": $0.id, "name": $0.name] },
        ])
    }

    private func signalsSnapshot() -> Data {
        Self.encode(["signals": actions.signals.signals.map {
            ["id": $0.id, "label": $0.label, "title": $0.title, "subtitle": $0.subtitle, "url": $0.url?.absoluteString ?? ""]
        }, "notified": notified])
    }

    /// Signals that went out as notifications, for checking the "don't notify on first poll" rule.
    private(set) var notified: [String] = []

    func recordNotified(_ signal: Signal) {
        notified.append(signal.id)
    }

    private func snapshot() -> Data {
        let items: [[String: Any]] = chat.items.map { item in
            switch item.kind {
            case .user(let text): return ["kind": "user", "text": text, "origin": item.origin ?? ""]
            case .screenshot(let path): return ["kind": "screenshot", "text": path]
            case .assistant(let text): return ["kind": "assistant", "text": text]
            case .tool(let summary, let ok): return ["kind": "tool", "text": summary, "ok": ok.map { $0 ? "yes" : "no" } ?? "running"]
            case .error(let text): return ["kind": "error", "text": text]
            }
        }
        let state: String = switch chat.state {
        case .idle: "idle"
        case .running: "running"
        case .done: "done"
        case .failed: "failed"
        }
        return Self.encode([
            "state": state,
            "activity": chat.activity ?? "",
            "approvals": chat.approvals.map { ["title": $0.title, "detail": $0.detail] },
            "items": items,
            "visible": chat.isVisible,
            "workspace": chat.workspace?.path ?? "",
            "needsWorkspace": chat.needsWorkspace,
            "backend": chat.agent.id,
            "agent": chat.agent.id,
            "agents": chat.agents.map(\.id),
            "models": chat.models.map { ["id": $0.id, "name": $0.name] },
            "model": chat.model ?? "",
            "sessionId": chat.sessionID ?? "",
            "activeModel": chat.activeModel ?? "",
            "installingRuntime": chat.installingRuntime,
            "history": chat.history.map { ["id": $0.id, "title": $0.title, "agent": $0.agent] },
            "pid": chat.processID.map { Int($0) } ?? 0,
            "runtimeOffer": chat.runtimeOffer ?? "",
            "signIn": chat.signInOptions.map(\.name),
            "attachments": chat.attachments.map(\.path),
            "input": chat.input,
            "windowId": actions.chatWindowID(),
            "frame": { let f = actions.chatFrame(); return [f.minX, f.minY, f.width, f.height] }(),
            "voice": chat.voice.phase.rawValue,
            "voiceRetry": chat.voiceRetryItem != nil,
        ])
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

// MARK: - Task runs

extension TestControl {
    /// What Open PR would have run. Test mode never pushes.
    static var openPRCommands: [[String]] = []
    /// Why the last `/test/task-runs/start`, `open-pr` or `remove-copy` failed, or nil.
    static var taskRunError: String?

    func handleTaskRuns(_ method: String, _ path: String, _ body: [String: Any]) -> Data {
        guard let runner = TaskRunner.shared else { return Self.encode(["ok": false, "error": "no task runner"]) }
        let task = body["task"] as? String ?? ""
        switch (method, path) {
        case ("GET", "/test/task-runs"):
            break
        case ("POST", "/test/task-runs/start"):
            Self.taskRunError = nil
            let agent = AgentCatalog.agent(id: body["agent"] as? String) ?? runner.defaultAgent()?.agent
            guard let agent else { return Self.encode(["ok": false, "error": "no agent"]) }
            let project = (body["project"] as? String).map { URL(fileURLWithPath: $0) }
            let model = body["model"] as? String
            Task { Self.taskRunError = await runner.start(task: task, project: project, agent: agent, model: model) }
        case ("POST", "/test/task-runs/approve"):
            guard let approval = runner.run(for: task)?.approval else { return Self.encode(["ok": false, "error": "no approval"]) }
            let allow = body["allow"] as? Bool ?? false
            // The bubble's button when it is on screen, as a click would.
            let pressed = actions.pressBubbleButton(Announcer.taskRunApprovalID(approval.id), allow ? "Allow" : "Deny")
            if !pressed { runner.decide(id: approval.id, allow: allow) }
        case ("POST", "/test/task-runs/stop"):
            runner.stop(task: task)
        case ("POST", "/test/task-runs/open-pr"):
            Self.taskRunError = nil
            Task { Self.taskRunError = await runner.openPR(task: task) }
        case ("POST", "/test/task-runs/remove-copy"):
            Self.taskRunError = nil
            Task { Self.taskRunError = await runner.removeCopy(task: task) }
        default:
            return Self.encode(["ok": false, "error": "unknown endpoint \(path)"])
        }
        return taskRunsSnapshot(runner)
    }

    private func taskRunsSnapshot(_ runner: TaskRunner) -> Data {
        let runs = runner.runs.values.sorted { $0.started < $1.started }.map { run -> [String: Any] in
            var object: [String: Any] = [
                "task": run.task, "state": run.state.rawValue, "repo": run.repo.path, "worktree": run.worktree.path,
                "branch": run.branch, "base": run.base, "agent": run.agent, "commits": run.commits,
                "dirty": run.dirty, "cleanup": run.cleanup.rawValue, "canOpenPR": run.canOpenPR,
            ]
            object["baseBranch"] = run.baseBranch
            object["session"] = run.session
            object["summary"] = run.summary
            object["error"] = run.error
            object["activity"] = run.activity
            object["gitDir"] = run.gitDir?.path
            object["pushRemote"] = run.pushRemote
            if let approval = run.approval { object["approval"] = ["id": approval.id.uuidString, "title": approval.title, "detail": approval.detail] }
            return object
        }
        var result: [String: Any] = ["ok": true, "runs": runs, "openPR": Self.openPRCommands, "live": runner.liveCount]
        result["error"] = Self.taskRunError
        return Self.encode(result)
    }
}
