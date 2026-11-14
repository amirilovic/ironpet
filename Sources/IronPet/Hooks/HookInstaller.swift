import Foundation

/// Adds ironpet's status hooks to the global config of each agent the user chose to watch, leaving every other
/// tool's hooks untouched. The agents differ in file and format, so each `Agent` names its own way in; they all run
/// the same `ironpet-hook <source> <event>` script, and `SessionStore` turns the events into session status.
struct HookInstaller {
    static let cursorEvents = ["sessionStart", "beforeSubmitPrompt", "postToolUse", "afterAgentResponse", "stop", "sessionEnd"]
    /// Events that older versions installed for chat approvals. Installing removes them.
    static let retiredCursorEvents = ["beforeShellExecution", "preToolUse", "beforeMCPExecution"]
    static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                               "Notification", "Stop", "StopFailure", "SessionEnd"]
    static let claudeToolEvents: Set<String> = ["PreToolUse", "PostToolUse"]
    /// Codex reads `~/.codex/hooks.json` in Claude's layout. It only runs hooks the user has trusted in its `/hooks` screen.
    static let codexEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd"]
    static let geminiEvents = ["SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "Notification", "AfterAgent", "SessionEnd"]
    static let copilotEvents = ["sessionStart", "userPromptSubmitted", "preToolUse", "postToolUse", "permissionRequest",
                                "agentStop", "errorOccurred", "sessionEnd"]
    /// First line of the Pi extension, so uninstall only removes a file ironpet wrote.
    static let piMarker = "// ironpet status hook (managed by ironpet; removed when you turn off Watch Pi)"

    enum Agent: String, CaseIterable {
        case cursor, claude, codex, gemini, copilot, pi

        var displayName: String {
            switch self {
            case .cursor: return "Cursor"
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .gemini: return "Gemini CLI"
            case .copilot: return "GitHub Copilot"
            case .pi: return "Pi"
            }
        }

        /// The default config file, for display.
        var configFile: URL {
            switch self {
            case .cursor: return Paths.cursorHooks
            case .claude: return Paths.claudeSettings
            case .codex: return Paths.home.appendingPathComponent(".codex/hooks.json")
            case .gemini: return Paths.home.appendingPathComponent(".gemini/settings.json")
            case .copilot: return Paths.home.appendingPathComponent(".copilot/hooks/ironpet.json")
            case .pi: return Paths.home.appendingPathComponent(".pi/agent/extensions/ironpet.ts")
            }
        }

        /// The command the agent is started with, and the folder it keeps its settings in.
        private var command: String {
            switch self {
            case .cursor: return "cursor-agent"
            case .claude: return "claude"
            case .codex: return "codex"
            case .gemini: return "gemini"
            case .copilot: return "copilot"
            case .pi: return "pi"
            }
        }

        private var settingsFolder: String {
            switch self {
            case .cursor: return ".cursor"
            case .claude: return ".claude"
            case .codex: return ".codex"
            case .gemini: return ".gemini"
            case .copilot: return ".copilot"
            case .pi: return ".pi"
            }
        }

        /// Whether the tool looks installed: its config folder, app or CLI exists.
        var isPresent: Bool {
            let fm = FileManager.default
            if fm.fileExists(atPath: Paths.home.appendingPathComponent(settingsFolder).path) || LoginShell.find(command) != nil { return true }
            return self == .cursor && fm.fileExists(atPath: "/Applications/Cursor.app")
        }

        /// A note shown next to the switch when watching needs a step in the agent itself.
        var watchNote: String? {
            switch self {
            case .codex: return "Codex asks you to trust new hooks: open /hooks in Codex once and approve ironpet's."
            case .pi: return "Adds an extension file; restart Pi or run /reload."
            default: return nil
            }
        }
    }

    /// Where the hook script and the agents' config files live; tests point these at a temporary folder.
    struct Locations {
        var cursorHooks = Paths.cursorHooks
        var claudeSettings = Paths.claudeSettings
        var hookScript = Paths.hookScript
        var codexHooks = Agent.codex.configFile
        var geminiSettings = Agent.gemini.configFile
        var copilotHooks = Agent.copilot.configFile
        var piExtension = Agent.pi.configFile

        init(cursorHooks: URL = Paths.cursorHooks, claudeSettings: URL = Paths.claudeSettings, hookScript: URL = Paths.hookScript,
             codexHooks: URL = Agent.codex.configFile, geminiSettings: URL = Agent.gemini.configFile,
             copilotHooks: URL = Agent.copilot.configFile, piExtension: URL = Agent.pi.configFile) {
            self.cursorHooks = cursorHooks
            self.claudeSettings = claudeSettings
            self.hookScript = hookScript
            self.codexHooks = codexHooks
            self.geminiSettings = geminiSettings
            self.copilotHooks = copilotHooks
            self.piExtension = piExtension
        }
    }

    let locations: Locations
    private let fm = FileManager.default

    init(locations: Locations = Locations()) {
        self.locations = locations
    }

    func file(for agent: Agent) -> URL {
        switch agent {
        case .cursor: return locations.cursorHooks
        case .claude: return locations.claudeSettings
        case .codex: return locations.codexHooks
        case .gemini: return locations.geminiSettings
        case .copilot: return locations.copilotHooks
        case .pi: return locations.piExtension
        }
    }

    /// Adds (or refreshes) the hooks for these agents. Returns the config files that changed.
    @discardableResult
    func install(_ agents: [Agent]) throws -> [URL] {
        guard !agents.isEmpty else { return [] }
        try writeScript()
        return try agents.filter { try update($0, install: true) }.map(file(for:))
    }

    /// Removes ironpet's hooks for these agents, leaving everything else in their configs alone.
    @discardableResult
    func uninstall(_ agents: [Agent] = Agent.allCases) throws -> [URL] {
        try agents.filter { try update($0, install: false) }.map(file(for:))
    }

    func isInstalled(_ agent: Agent) -> Bool {
        guard let data = fm.contents(atPath: file(for: agent).path) else { return false }
        return String(decoding: data, as: UTF8.self).contains("/.ironpet/bin/ironpet-hook")
    }

    private func update(_ agent: Agent, install: Bool) throws -> Bool {
        switch agent {
        case .cursor: return try updateCursor(install: install)
        case .claude: return try updateGroups(.claude, events: Self.claudeEvents, matchAllTools: true, timeout: 5, named: false, install: install)
        case .codex: return try updateGroups(.codex, events: Self.codexEvents, matchAllTools: false, timeout: 5, named: false, install: install)
        case .gemini: return try updateGroups(.gemini, events: Self.geminiEvents, matchAllTools: false, timeout: 5_000, named: true, install: install)
        case .copilot: return try updateCopilot(install: install)
        case .pi: return try updatePi(install: install)
        }
    }

    private func writeScript() throws {
        try fm.createDirectory(at: locations.hookScript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(HookScript.contents.utf8)
        if fm.contents(atPath: locations.hookScript.path) != data {
            try data.write(to: locations.hookScript, options: .atomic)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locations.hookScript.path)
    }

    private func command(_ source: String, _ event: String) -> String {
        "'\(locations.hookScript.path)' \(source) \(event)"
    }

    private func isOurs(_ command: Any?) -> Bool {
        (command as? String)?.contains("/.ironpet/bin/ironpet-hook") == true
    }

    private func updateCursor(install: Bool) throws -> Bool {
        guard install || fm.fileExists(atPath: locations.cursorHooks.path) else { return false }
        var root = try readJSON(locations.cursorHooks) ?? ["version": 1]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            hooks[event] = entries.filter { !isOurs($0["command"]) }
        }
        if install {
            for event in Self.cursorEvents {
                var entries = hooks[event] as? [[String: Any]] ?? []
                entries.append(["command": command("cursor", event), "timeout": 5])
                hooks[event] = entries
            }
        }
        for event in Self.cursorEvents + Self.retiredCursorEvents where (hooks[event] as? [Any])?.isEmpty == true { hooks[event] = nil }
        root["hooks"] = hooks
        return try writeIfChanged(root, to: locations.cursorHooks)
    }

    /// Claude Code, Codex and Gemini CLI share a layout: `hooks.<Event>` is a list of groups, each with a `hooks` list of
    /// commands. Gemini wants a name and a timeout in milliseconds; Claude wants tool events matched with `*`.
    private func updateGroups(_ agent: Agent, events: [String], matchAllTools: Bool, timeout: Int, named: Bool, install: Bool) throws -> Bool {
        let url = file(for: agent)
        guard install || fm.fileExists(atPath: url.path) else { return false }
        var root = try readJSON(url) ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            hooks[event] = groups.filter { group in
                !((group["hooks"] as? [[String: Any]]) ?? []).contains { isOurs($0["command"]) }
            }
        }
        if install {
            for event in events {
                var groups = hooks[event] as? [[String: Any]] ?? []
                var entry: [String: Any] = ["type": "command", "command": command(agent.rawValue, event), "timeout": timeout]
                if named { entry["name"] = "ironpet" }
                var group: [String: Any] = ["hooks": [entry]]
                if matchAllTools, Self.claudeToolEvents.contains(event) { group["matcher"] = "*" }
                groups.append(group)
                hooks[event] = groups
            }
        }
        for event in events where (hooks[event] as? [Any])?.isEmpty == true { hooks[event] = nil }
        if hooks.isEmpty { root["hooks"] = nil } else { root["hooks"] = hooks }
        return try writeIfChanged(root, to: url)
    }

    /// Copilot CLI loads every file in `~/.copilot/hooks/`, so ironpet owns one file there and deletes it on uninstall.
    private func updateCopilot(install: Bool) throws -> Bool {
        let url = locations.copilotHooks
        if !install {
            guard fm.fileExists(atPath: url.path), isInstalled(.copilot) else { return false }
            try fm.removeItem(at: url)
            return true
        }
        var hooks: [String: Any] = [:]
        for event in Self.copilotEvents {
            hooks[event] = [["type": "command", "bash": command("copilot", event), "timeoutSec": 5] as [String: Any]]
        }
        return try writeIfChanged(["version": 1, "hooks": hooks], to: url)
    }

    /// Pi has no hook list; extensions are TypeScript files it loads from `~/.pi/agent/extensions/`. The extension
    /// hands each event to the same hook script, so Pi is one more `source` to the rest of the app.
    private func updatePi(install: Bool) throws -> Bool {
        let url = locations.piExtension
        if !install {
            guard fm.fileExists(atPath: url.path), isInstalled(.pi) else { return false }
            try fm.removeItem(at: url)
            return true
        }
        let script = locations.hookScript.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let text = Self.piExtension(script: script)
        if let existing = fm.contents(atPath: url.path), existing == Data(text.utf8) { return false }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        return true
    }

    static func piExtension(script: String) -> String {
        """
        \(piMarker)
        import { spawn } from "node:child_process";

        const HOOK = "\(script)";

        function send(event: string, ctx: any, extra: Record<string, unknown> = {}) {
          try {
            const child = spawn(HOOK, ["pi", event], { stdio: ["pipe", "ignore", "ignore"], detached: true });
            child.on("error", () => {});
            child.stdin.on("error", () => {});
            child.stdin.end(JSON.stringify({ session_id: ctx.sessionManager.getSessionId(), cwd: ctx.cwd, ...extra }));
            child.unref();
          } catch {}
        }

        export default function (pi: any) {
          pi.on("session_start", (_event: any, ctx: any) => send("session_start", ctx));
          pi.on("before_agent_start", (event: any, ctx: any) => send("agent_start", ctx, { prompt: event?.prompt }));
          pi.on("tool_execution_start", (event: any, ctx: any) => send("tool", ctx, { tool_name: event?.toolName ?? event?.tool_name }));
          pi.on("agent_settled", (_event: any, ctx: any) => send("agent_settled", ctx));
          pi.on("session_shutdown", (_event: any, ctx: any) => send("session_shutdown", ctx));
        }

        """
    }

    private func readJSON(_ url: URL) throws -> [String: Any]? {
        guard let data = fm.contents(atPath: url.path), !data.isEmpty else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return object
    }

    private func writeIfChanged(_ object: [String: Any], to url: URL) throws -> Bool {
        if let existing = try readJSON(url), NSDictionary(dictionary: existing).isEqual(to: object) { return false }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.appendingPathExtension("ironpet-backup")
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return true
    }
}
