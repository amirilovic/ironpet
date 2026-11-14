import AppKit

/// End-to-end test hooks, served at `/test/*` only when ironpet runs with `--test-mode`.
/// They drive the same code paths as the UI (show chat, send, Allow/Deny, notification click, capture),
/// so `scripts/e2e.sh` can exercise real agent runs without UI automation.
@MainActor
final class TestControl {
    static var isEnabled: Bool { CommandLine.arguments.contains("--test-mode") }

    struct Actions {
        let showChat: () -> Void
        /// The chat panel's frame in top-left screen coordinates, for `screencapture -R`.
        let chatWindowID: () -> Int
        let chatFrame: () -> CGRect
        let openSession: (String) -> Void
        let showSettings: (String?) -> Int
        let capture: (Bool) -> Void
        /// The handler a notification's Allow / Deny button calls.
        let notificationAction: (UUID, Bool) -> Void
        let signals: SignalStore
        let github: GitHubWatcher
        let meeting: MeetingController
        /// The meeting panel's frame in top-left screen coordinates, or `.zero` while it is hidden.
        let meetingFrame: () -> CGRect
        /// The title of the pet menu's meeting item, or "" when the menu has none.
        let meetingMenuTitle: () -> String
        /// Whether the meeting bubble is on screen, and whether the pet shows its Recording button.
        let meetingUI: () -> (bubble: Bool, button: Bool)
        /// Closes the meeting bubble as the user would (`false`), or clicks the pet's Recording button (`true`).
        let meetingBubble: (_ show: Bool) -> Void
        /// Plays a call event for an app as if the detector had reported it: "started", "ended", "record" or "not-now".
        let simulateCall: (_ bundleID: String, _ event: String) -> Void
        /// The title of the call bubble on screen, or "".
        let callOffer: () -> String
    }

    private let chat: ChatSession
    private let actions: Actions
    private(set) var attention: [[String: String]] = []

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
        case ("POST", "/test/approve"):
            guard let first = chat.approvals.first else { return Self.encode(["ok": false, "error": "no pending approval"]) }
            chat.decide(first, allow: body["allow"] as? Bool ?? false)
            return Self.encode(["ok": true, "title": first.title])
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
        case ("POST", "/test/github-apply"):
            actions.github.apply(host: body["host"] as? String ?? "test.example", data: body["data"] as? [String: Any] ?? [:])
            return signalsSnapshot()
        case ("POST", "/test/github-poll"):
            actions.github.poll()
            return Self.encode(["ok": true])
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
            return Self.encode(["windowId": actions.showSettings(body["snapshot"] as? String)])
        case ("POST", "/test/stop"):
            chat.stop()
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
        case ("GET", "/test/signals"):
            return signalsSnapshot()
        default:
            return Self.encode(["ok": false, "error": "unknown test endpoint \(request.method) \(request.path)"])
        }
        return snapshot()
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

    private func signalsSnapshot() -> Data {
        Self.encode(["signals": actions.signals.signals.map {
            ["id": $0.id, "kind": $0.kind.rawValue, "title": $0.title, "subtitle": $0.subtitle, "url": $0.url.absoluteString]
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
            case .user(let text): return ["kind": "user", "text": text]
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
