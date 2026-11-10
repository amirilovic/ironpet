import Foundation

/// Merges ironpet's status hooks into the global Cursor and Claude Code configs,
/// leaving every other tool's hooks untouched.
struct HookInstaller {
    static let cursorEvents = ["sessionStart", "beforeSubmitPrompt", "postToolUse", "afterAgentResponse", "stop", "sessionEnd",
                               "beforeShellExecution", "preToolUse", "beforeMCPExecution"]
    static let cursorGateEvents: Set<String> = ["beforeShellExecution", "preToolUse", "beforeMCPExecution"]
    /// Approval gates wait for the user; hooks need a finite timeout. Cursor silently skips a hook whose
    /// timeout overflows (somewhere above ~24.8 days, i.e. Int32 milliseconds), which fails open, so stay below it.
    /// Gates return immediately for agents the pet did not start.
    static let gateTimeout = 2_000_000
    static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                               "Notification", "Stop", "StopFailure", "SessionEnd"]
    static let claudeToolEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    enum Agent: String, CaseIterable {
        case cursor, claude

        var displayName: String { self == .cursor ? "Cursor" : "Claude Code" }

        /// The default config file, for display.
        var configFile: URL { self == .cursor ? Paths.cursorHooks : Paths.claudeSettings }

        /// Whether the tool looks installed: its config folder, app or CLI exists.
        var isPresent: Bool {
            let fm = FileManager.default
            switch self {
            case .cursor:
                return fm.fileExists(atPath: Paths.home.appendingPathComponent(".cursor").path)
                    || fm.fileExists(atPath: "/Applications/Cursor.app") || CursorAgentBackend.executable() != nil
            case .claude:
                return fm.fileExists(atPath: Paths.home.appendingPathComponent(".claude").path)
                    || ClaudeCodeBackend.executable() != nil
            }
        }
    }

    /// Where the hook script and the agents' config files live; tests point these at a temporary folder.
    struct Locations {
        var cursorHooks = Paths.cursorHooks
        var claudeSettings = Paths.claudeSettings
        var hookScript = Paths.hookScript
    }

    let locations: Locations
    private let fm = FileManager.default

    init(locations: Locations = Locations()) {
        self.locations = locations
    }

    func file(for agent: Agent) -> URL {
        agent == .cursor ? locations.cursorHooks : locations.claudeSettings
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
        agent == .cursor ? try updateCursor(install: install) : try updateClaude(install: install)
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
                entries.append(["command": command("cursor", event), "timeout": Self.cursorGateEvents.contains(event) ? Self.gateTimeout : 5])
                hooks[event] = entries
            }
        }
        for event in Self.cursorEvents where (hooks[event] as? [Any])?.isEmpty == true { hooks[event] = nil }
        root["hooks"] = hooks
        return try writeIfChanged(root, to: locations.cursorHooks)
    }

    private func updateClaude(install: Bool) throws -> Bool {
        guard install || fm.fileExists(atPath: locations.claudeSettings.path) else { return false }
        var root = try readJSON(locations.claudeSettings) ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            hooks[event] = groups.filter { group in
                !((group["hooks"] as? [[String: Any]]) ?? []).contains { isOurs($0["command"]) }
            }
        }
        if install {
            for event in Self.claudeEvents {
                var groups = hooks[event] as? [[String: Any]] ?? []
                let timeout = event == "PreToolUse" ? Self.gateTimeout : 5
                var group: [String: Any] = ["hooks": [["type": "command", "command": command("claude", event), "timeout": timeout]]]
                if Self.claudeToolEvents.contains(event) { group["matcher"] = "*" }
                groups.append(group)
                hooks[event] = groups
            }
        }
        for event in Self.claudeEvents where (hooks[event] as? [Any])?.isEmpty == true { hooks[event] = nil }
        if hooks.isEmpty { root["hooks"] = nil } else { root["hooks"] = hooks }
        return try writeIfChanged(root, to: locations.claudeSettings)
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
