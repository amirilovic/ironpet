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
        case ("GET", "/test/signals"):
            return signalsSnapshot()
        default:
            return Self.encode(["ok": false, "error": "unknown test endpoint \(request.method) \(request.path)"])
        }
        return snapshot()
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
