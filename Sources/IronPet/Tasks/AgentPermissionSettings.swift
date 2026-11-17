import Foundation

/// Settings in an agent's own files that let it run a command, change a file or call a tool without sending ironpet a
/// permission request. A task run, and a chat in a run's copy, refuses to start Cursor or Claude Code while one is set,
/// because ironpet's card is the only thing between such a run and the user's machine (SECURITY.md › Task runs).
///
/// Read from the agents' own sources, not their docs:
/// - cursor-agent 2026.11 reads `cli-config.json` in `CURSOR_CONFIG_DIR`, else `$XDG_CONFIG_HOME/cursor`, else `~/.cursor`, and merges
///   every `.cursor/cli.json` from the git root down to the folder over it. In `acp` its permission service runs a tool without asking
///   when `approvalMode` is `unrestricted` (Run Everything) or the tool matches `permissions.allow`, and `sandbox.mode: enabled` runs
///   commands in its sandbox unasked.
/// - claude-agent-acp 0.107.0 starts Claude Code with `settingSources: user, project, local`: `settings.json` in `CLAUDE_CONFIG_DIR`
///   (else `~/.claude`), and the folder's `.claude/settings.json` and `.claude/settings.local.json`, plus the managed settings file.
///   A `permissions.allow` rule decides before `canUseTool`, so a matching tool never reaches ironpet. `permissions.defaultMode` needs no
///   check here: a run switches the session to an asking mode (`ACPBackend.runMode`).
struct AgentPermissionSettings {
    var home: URL
    /// The environment the agent starts with (`LoginShell.environment()`), for the config folder variables.
    var environment: [String: String]
    var claudeManaged = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")

    static func live() -> AgentPermissionSettings {
        AgentPermissionSettings(home: FileManager.default.homeDirectoryForCurrentUser, environment: LoginShell.environment())
    }

    /// Rules for tools that only read. Anything else (commands, writes, MCP tools, rules ironpet does not know) refuses.
    static let cursorReadOnlyRules: Set<String> = ["Read", "WebFetch", "WebSearch"]
    static let claudeReadOnlyRules: Set<String> = ["Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch", "NotebookRead", "TodoWrite"]

    /// Why `agent` cannot work unasked here, or nil. `folder` is where it runs; nil checks only the user's own settings. Project files
    /// are read in `folder` and each parent up to, not including, `stop` (the folder that holds the run copies).
    func refusal(agent: String, name: String, folder: URL?, stop: URL?) -> String? {
        let problems: [String]
        switch agent {
        case "cursor": problems = cursor(folder: folder, stop: stop)
        case "claude": problems = claude(folder: folder, stop: stop)
        default: return nil
        }
        guard !problems.isEmpty else { return nil }
        return "\(name)'s own settings would let it run commands or change files without asking ironpet, so it cannot work on a task. "
            + problems.joined(separator: " ")
    }

    // MARK: Cursor

    private func cursorConfigDirectory() -> URL {
        if let dir = environment["CURSOR_CONFIG_DIR"], !dir.trimmingCharacters(in: .whitespaces).isEmpty { return URL(fileURLWithPath: dir) }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("cursor")
        }
        return home.appendingPathComponent(".cursor")
    }

    private func cursor(folder: URL?, stop: URL?) -> [String] {
        var files = [cursorConfigDirectory().appendingPathComponent("cli-config.json")]
        files += Self.folders(from: folder, stop: stop).reversed().map { $0.appendingPathComponent(".cursor/cli.json") }
        var problems: [String] = []
        for file in files {
            guard let json = Self.json(file) else { continue }
            let path = display(file)
            if let mode = json["approvalMode"] as? String, mode != "allowlist" {
                problems.append("\(path) sets approvalMode to \"\(mode)\". Set it to \"allowlist\".")
            }
            if let sandbox = json["sandbox"] as? [String: Any], sandbox["mode"] as? String == "enabled" {
                problems.append("\(path) sets sandbox.mode to \"enabled\", which runs commands in Cursor's sandbox without asking. Set it to \"disabled\".")
            }
            let rules = Self.allowRules(json).filter { !Self.cursorReadOnlyRules.contains(Self.ruleTool($0)) }
            if !rules.isEmpty {
                problems.append("\(path) allows \(Self.listed(rules)) in permissions.allow. Remove them; Read, WebFetch and WebSearch rules can stay.")
            }
        }
        return problems
    }

    // MARK: Claude Code

    private func claude(folder: URL?, stop: URL?) -> [String] {
        let configDir = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        var files = [claudeManaged, configDir.appendingPathComponent("settings.json")]
        for dir in Self.folders(from: folder, stop: stop).reversed() {
            files += [dir.appendingPathComponent(".claude/settings.json"), dir.appendingPathComponent(".claude/settings.local.json")]
        }
        var problems: [String] = []
        for file in files {
            guard let json = Self.json(file) else { continue }
            let rules = Self.allowRules(json).filter { !Self.claudeReadOnlyRules.contains(Self.ruleTool($0)) }
            if !rules.isEmpty {
                problems.append("\(display(file)) allows \(Self.listed(rules)) in permissions.allow. Remove them; Read, Grep, Glob, LS, WebFetch and WebSearch rules can stay.")
            }
        }
        return problems
    }

    // MARK: Reading

    /// `folder` and its parents, nearest first, stopping before `stop`. Without `stop`, only `folder`.
    static func folders(from folder: URL?, stop: URL?) -> [URL] {
        guard let folder else { return [] }
        let start = folder.standardizedFileURL
        guard let stop else { return [start] }
        let limit = RunScope.resolve(stop.path)
        var list: [URL] = []
        var current = start
        while RunScope.resolve(current.path).hasPrefix(limit + "/") {
            list.append(current)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent
        }
        return list.isEmpty ? [start] : list
    }

    private static func json(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func allowRules(_ json: [String: Any]) -> [String] {
        ((json["permissions"] as? [String: Any])?["allow"] as? [Any] ?? []).compactMap { $0 as? String }
    }

    /// "Shell(ls)" is `Shell`, "mcp__hodor__*" is itself.
    static func ruleTool(_ rule: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespaces)
        return trimmed.firstIndex(of: "(").map { String(trimmed[..<$0]).trimmingCharacters(in: .whitespaces) } ?? trimmed
    }

    /// "Shell(ls), Shell(python) and 3 more".
    private static func listed(_ rules: [String]) -> String {
        let shown = Array(rules.prefix(3))
        if rules.count > shown.count { return shown.joined(separator: ", ") + " and \(rules.count - shown.count) more" }
        return shown.dropLast().joined(separator: ", ") + (shown.count > 1 ? " and " : "") + (shown.last ?? "")
    }

    private func display(_ file: URL) -> String {
        let path = file.path, homePath = home.path
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }
}
