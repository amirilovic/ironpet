import Foundation

/// An agent that reads skills from a folder in the user's home.
struct SkillAgent: Equatable {
    let id: String
    let name: String
    /// The agent's global skills folder, relative to home.
    let dir: String
    /// Reads `~/.agents/skills`, where the one real copy lives, so it needs no link.
    var universal = false

    static let canonicalDir = ".agents/skills"
}

/// Installs a skill like this: one real copy goes in `~/.agents/skills/<name>`, which
/// Codex, Cline, Pi, Warp, Zed and others read directly. Every other agent found on the Mac gets a relative symlink from its own
/// skills folder to that copy, so an update touches one place. `copy` writes a separate copy per agent instead.
/// A folder with the same name that ironpet did not write is left alone.
struct SkillInstaller {
    /// Agents and their global skills folders.
    static let agents: [SkillAgent] = [
        SkillAgent(id: "claude-code", name: "Claude Code", dir: ".claude/skills"),
        SkillAgent(id: "cursor", name: "Cursor", dir: ".cursor/skills"),
        SkillAgent(id: "gemini-cli", name: "Gemini CLI", dir: ".gemini/skills"),
        SkillAgent(id: "github-copilot", name: "GitHub Copilot", dir: ".copilot/skills"),
        SkillAgent(id: "opencode", name: "OpenCode", dir: ".config/opencode/skills"),
        SkillAgent(id: "droid", name: "Droid", dir: ".factory/skills"),
        SkillAgent(id: "goose", name: "Goose", dir: ".config/goose/skills"),
        SkillAgent(id: "kiro-cli", name: "Kiro CLI", dir: ".kiro/skills"),
        SkillAgent(id: "junie", name: "Junie", dir: ".junie/skills"),
        SkillAgent(id: "kilo", name: "Kilo Code", dir: ".kilo/skills"),
        SkillAgent(id: "qwen-code", name: "Qwen Code", dir: ".qwen/skills"),
        SkillAgent(id: "qoder", name: "Qoder", dir: ".qoder/skills"),
        SkillAgent(id: "mistral-vibe", name: "Mistral Vibe", dir: ".vibe/skills"),
        SkillAgent(id: "augment", name: "Augment", dir: ".augment/skills"),
        SkillAgent(id: "codebuddy", name: "CodeBuddy", dir: ".codebuddy/skills"),
        SkillAgent(id: "windsurf", name: "Windsurf", dir: ".codeium/windsurf/skills"),
        SkillAgent(id: "roo", name: "Roo Code", dir: ".roo/skills"),
        SkillAgent(id: "continue", name: "Continue", dir: ".continue/skills"),
        SkillAgent(id: "crush", name: "Crush", dir: ".config/crush/skills"),
        SkillAgent(id: "devin", name: "Devin for Terminal", dir: ".config/devin/skills"),
        SkillAgent(id: "universal", name: "Codex, Cline, Pi, Warp, Zed and other agents", dir: SkillAgent.canonicalDir, universal: true),
    ]

    let home: URL
    var name: String
    var content: String

    init(home: URL, skill: BundledSkill = BundledSkills.all[0]) {
        self.home = home
        name = skill.name
        content = skill.content
    }

    init(home: URL, name: String, content: String) {
        self.home = home
        self.name = name
        self.content = content
    }

    /// The user's home, or `IRONPET_SKILLS_HOME` for tests and trial runs.
    static var standardHome: URL {
        ProcessInfo.processInfo.environment["IRONPET_SKILLS_HOME"].map { URL(fileURLWithPath: $0) } ?? Paths.home
    }

    static var standard: SkillInstaller { SkillInstaller(home: standardHome) }

    enum State: Equatable { case notInstalled, current, outdated, foreign }

    struct AgentStatus: Equatable {
        let agent: SkillAgent
        let state: State
        /// Whether `skills install` would pick this agent without being asked.
        let detected: Bool
    }

    struct Status: Equatable {
        /// The real copy in `~/.agents/skills`.
        let canonical: State
        let agents: [AgentStatus]

        /// Agents found on this Mac whose folder is missing the skill or has an old one.
        var needsInstall: Bool {
            canonical == .notInstalled || canonical == .outdated
                || agents.contains { $0.detected && !$0.agent.universal && ($0.state == .notInstalled || $0.state == .outdated) }
        }

        var isInstalledAnywhere: Bool { canonical != .notInstalled || agents.contains { $0.state == .current || $0.state == .outdated } }
        var hasOutdated: Bool { canonical == .outdated || agents.contains { $0.state == .outdated } }
        var detectedNames: [String] { agents.filter { $0.detected && !$0.agent.universal }.map(\.agent.name) }
        var linkedNames: [String] { agents.filter { !$0.agent.universal && $0.state == .current }.map(\.agent.name) }
    }

    struct Outcome: Equatable {
        let agent: SkillAgent
        /// `linked`, `copied`, `current`, `skipped` or `failed`, with a reason for the last two.
        let result: String
        let note: String?
    }

    var canonical: URL { home.appendingPathComponent(SkillAgent.canonicalDir).appendingPathComponent(name) }

    private func folder(_ agent: SkillAgent) -> URL { home.appendingPathComponent(agent.dir).appendingPathComponent(name) }

    /// An agent counts as installed when its config folder (the parent of its skills folder) exists.
    func isDetected(_ agent: SkillAgent) -> Bool {
        var isDirectory: ObjCBool = false
        let parent = home.appendingPathComponent(agent.dir).deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Status

    func status() -> Status {
        Status(canonical: state(of: canonical),
               agents: Self.agents.map { AgentStatus(agent: $0, state: $0.universal ? state(of: canonical) : state(of: folder($0)), detected: isDetected($0)) })
    }

    /// What a skill folder holds: nothing, our current text, our old text, or somebody else's skill.
    private func state(of url: URL) -> State {
        guard FileManager.default.fileExists(atPath: url.path) else { return .notInstalled }
        guard let text = try? String(contentsOf: url.appendingPathComponent("SKILL.md"), encoding: .utf8) else { return .foreign }
        if text == content { return .current }
        return text.contains("name: \(name)") ? .outdated : .foreign
    }

    // MARK: Install

    /// Writes the real copy and links or copies it to `agents`. Without `agents`, every agent found on the Mac.
    @discardableResult
    func install(agents requested: [SkillAgent]? = nil, copy: Bool = false) throws -> [Outcome] {
        let fm = FileManager.default
        try fm.createDirectory(at: canonical, withIntermediateDirectories: true)
        try content.write(to: canonical.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let targets = (requested ?? Self.agents.filter { isDetected($0) }).filter { !$0.universal }
        var outcomes = [Outcome(agent: Self.agents.first { $0.universal }!, result: "installed", note: canonical.path)]
        for agent in targets { outcomes.append(link(agent, copy: copy)) }
        return outcomes
    }

    private func link(_ agent: SkillAgent, copy: Bool) -> Outcome {
        let fm = FileManager.default
        let target = folder(agent)
        let parent = target.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            if let destination = try? fm.destinationOfSymbolicLink(atPath: target.path) {
                // Our own link already points at the real copy. A link somewhere else is replaced.
                if !copy, URL(fileURLWithPath: destination, relativeTo: parent).standardizedFileURL.path == canonical.standardizedFileURL.path {
                    return Outcome(agent: agent, result: "current", note: nil)
                }
                try fm.removeItem(at: target)
            } else if fm.fileExists(atPath: target.path) {
                guard state(of: target) != .foreign else {
                    return Outcome(agent: agent, result: "skipped", note: "\(target.path) is a different skill with the same name")
                }
                try fm.removeItem(at: target)
            }
            if copy {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try content.write(to: target.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
                return Outcome(agent: agent, result: "copied", note: nil)
            }
            try fm.createSymbolicLink(atPath: target.path, withDestinationPath: Self.relativePath(from: parent, to: canonical))
            return Outcome(agent: agent, result: "linked", note: nil)
        } catch {
            return Outcome(agent: agent, result: "failed", note: error.localizedDescription)
        }
    }

    /// `../../.agents/skills/name`, the way `skills` writes its links.
    static func relativePath(from folder: URL, to target: URL) -> String {
        let from = folder.standardizedFileURL.pathComponents, to = target.standardizedFileURL.pathComponents
        var common = 0
        while common < from.count, common < to.count, from[common] == to[common] { common += 1 }
        return (Array(repeating: "..", count: from.count - common) + to[common...]).joined(separator: "/")
    }

    // MARK: Remove

    /// Removes the links and copies that ironpet wrote, and the real copy. A folder that is somebody else's is kept.
    @discardableResult
    func remove() -> [Outcome] {
        let fm = FileManager.default
        var outcomes: [Outcome] = []
        for agent in Self.agents where !agent.universal {
            let target = folder(agent)
            let isLink = (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil
            guard isLink || state(of: target) == .current || state(of: target) == .outdated else { continue }
            do { try fm.removeItem(at: target); outcomes.append(Outcome(agent: agent, result: "removed", note: nil)) }
            catch { outcomes.append(Outcome(agent: agent, result: "failed", note: error.localizedDescription)) }
        }
        if state(of: canonical) == .current || state(of: canonical) == .outdated {
            try? fm.removeItem(at: canonical)
            outcomes.append(Outcome(agent: Self.agents.first { $0.universal }!, result: "removed", note: canonical.path))
        }
        return outcomes
    }

    /// A summary for the CLI and the app.
    static func describe(_ outcomes: [Outcome]) -> String {
        outcomes.map { "\($0.agent.name): \($0.result)" + ($0.note.map { " (\($0))" } ?? "") }.joined(separator: "\n")
    }
}

/// Every bundled skill at once: what is installed, installing, removing and updating the ones already installed.
struct SkillManager {
    let home: URL
    var skills: [BundledSkill] = BundledSkills.all

    static var standard: SkillManager { SkillManager(home: SkillInstaller.standardHome) }

    struct Entry: Equatable {
        let skill: BundledSkill
        let status: SkillInstaller.Status
    }

    func installer(_ skill: BundledSkill) -> SkillInstaller { SkillInstaller(home: home, skill: skill) }

    func entries() -> [Entry] { skills.map { Entry(skill: $0, status: installer($0).status()) } }

    /// Installs the named skills (all of them without names) for `agents` (every agent found on the Mac without them).
    @discardableResult
    func install(names: [String]? = nil, agents: [SkillAgent]? = nil, copy: Bool = false) throws -> [(skill: BundledSkill, outcomes: [SkillInstaller.Outcome])] {
        try skills.filter { names?.contains($0.name) ?? true }.map { ($0, try installer($0).install(agents: agents, copy: copy)) }
    }

    @discardableResult
    func remove(names: [String]? = nil) -> [(skill: BundledSkill, outcomes: [SkillInstaller.Outcome])] {
        skills.filter { names?.contains($0.name) ?? true }.map { ($0, installer($0).remove()) }
    }

    /// Brings every installed skill whose text is old up to date, where it is installed. It adds nothing new.
    /// Returns the names it updated.
    @discardableResult
    func updateInstalled() -> [String] {
        var updated: [String] = []
        for entry in entries() where entry.status.hasOutdated {
            let stale = entry.status.agents.filter { !$0.agent.universal && $0.state == .outdated }.map(\.agent)
            if (try? installer(entry.skill).install(agents: stale)) != nil { updated.append(entry.skill.name) }
        }
        return updated
    }
}

/// The bubble that offers to install or update skills. It asks once for each version of a skill.
enum SkillPrompt {
    static let dismissedKey = "skillPromptDismissed"

    static func dismissed() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []) }

    static func dismiss(_ entries: [SkillManager.Entry]) {
        UserDefaults.standard.set(Array(dismissed().union(entries.map(\.skill.hash))), forKey: dismissedKey)
    }

    /// The skills to ask about: missing or out of date, an agent that could use them is on this Mac, and the user has not said
    /// "not now" to this version of the text.
    static func pending(_ entries: [SkillManager.Entry], dismissed: Set<String>) -> [SkillManager.Entry] {
        entries.filter { entry in
            entry.status.needsInstall && !dismissed.contains(entry.skill.hash) && (entry.status.hasOutdated || !entry.status.detectedNames.isEmpty)
        }
    }

    static func message(_ pending: [SkillManager.Entry]) -> (title: String, body: String, button: String) {
        let outdated = pending.filter { $0.status.hasOutdated }
        let names = pending.map(\.skill.name).joined(separator: ", ")
        let agents = Array(Set(pending.flatMap { $0.status.detectedNames })).sorted()
        let where_ = agents.isEmpty ? "your agents" : agents.prefix(3).joined(separator: ", ") + (agents.count > 3 ? " and \(agents.count - 3) more" : "")
        if outdated.count == pending.count {
            return ("Update agent skill\(pending.count == 1 ? "" : "s")", "Newer version of \(names) for \(where_).", "Update")
        }
        return ("Install agent skill\(pending.count == 1 ? "" : "s")",
                "ironpet has \(pending.count == 1 ? "a skill" : "skills") that teach\(pending.count == 1 ? "es" : "") your agents what it can do: \(names). Install for \(where_).", "Install")
    }
}

/// `IronPet skills install|status|remove|list|agents`, in the command line tool.
enum SkillCLI {
    static let usage = """
        usage: IronPet skills <command>
          install [skill]... [--agent <id>]... [--copy]   install skills (default: all, for every agent found on this Mac)
          status                                          show where each skill is installed
          update                                          update the skills that are installed and out of date
          remove [skill]...                               remove what ironpet installed
          list                                            list the skills that ship with ironpet
          agents                                          list the agent ids
        The real copy goes in ~/.agents/skills/<skill>, with a symlink from each agent's skills folder
        --copy writes a separate copy per agent instead.
        """

    private static func label(_ state: SkillInstaller.State) -> String {
        switch state {
        case .notInstalled: return "not installed"
        case .current: return "installed"
        case .outdated: return "outdated"
        case .foreign: return "a different skill with the same name"
        }
    }

    static func execute(_ arguments: [String], manager: SkillManager = .standard) -> (code: Int32, out: String, err: String) {
        guard let command = arguments.first else { return (2, usage, "") }
        var ids: [String] = [], names: [String] = []
        var copy = false
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--copy": copy = true
            case "--agent", "-a": if let id = iterator.next() { ids.append(id) }
            default:
                if argument.hasPrefix("-") { return (2, "", "ironpet: unknown option \(argument)") }
                names.append(argument)
            }
        }
        let unknownSkills = names.filter { name in !manager.skills.contains { $0.name == name } }
        if !unknownSkills.isEmpty { return (1, "", "ironpet: unknown skill \(unknownSkills.joined(separator: ", ")). Run `IronPet skills list`.") }
        func report(_ results: [(skill: BundledSkill, outcomes: [SkillInstaller.Outcome])]) -> String {
            results.map { "\($0.skill.name)\n" + (SkillInstaller.describe($0.outcomes).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n")) }.joined(separator: "\n")
        }
        switch command {
        case "install":
            let known = SkillInstaller.agents.filter { !$0.universal }
            let unknown = ids.filter { id in id != "universal" && !known.contains { $0.id == id } }
            if !unknown.isEmpty { return (1, "", "ironpet: unknown agent \(unknown.joined(separator: ", ")). Run `IronPet skills agents` for the list.") }
            do {
                let results = try manager.install(names: names.isEmpty ? nil : names, agents: ids.isEmpty ? nil : known.filter { ids.contains($0.id) }, copy: copy)
                return (results.contains { $0.outcomes.contains { $0.result == "failed" } } ? 1 : 0, report(results), "")
            } catch {
                return (1, "", "ironpet: \(error.localizedDescription)")
            }
        case "status":
            var lines: [String] = []
            var attention = false
            for entry in manager.entries() {
                lines.append(entry.skill.name)
                lines.append("  ~/.agents/skills/\(entry.skill.name): \(label(entry.status.canonical))")
                for agent in entry.status.agents where !agent.agent.universal && (agent.detected || agent.state != .notInstalled) {
                    lines.append("  \(agent.agent.name): \(label(agent.state))")
                }
                attention = attention || entry.status.needsInstall
            }
            lines.append(attention ? "Run `IronPet skills install` to install, or `IronPet skills update` to update." : "Up to date.")
            return (0, lines.joined(separator: "\n"), "")
        case "update":
            let updated = manager.updateInstalled()
            return (0, updated.isEmpty ? "Nothing to update." : "Updated " + updated.joined(separator: ", "), "")
        case "remove":
            let results = manager.remove(names: names.isEmpty ? nil : names)
            return (0, results.allSatisfy { $0.outcomes.isEmpty } ? "Nothing to remove." : report(results.filter { !$0.outcomes.isEmpty }), "")
        case "list":
            return (0, manager.skills.map { "\($0.name)\t\($0.summary)" }.joined(separator: "\n"), "")
        case "agents":
            return (0, SkillInstaller.agents.map { "\($0.id)\t\($0.name)\t~/\($0.dir)" }.joined(separator: "\n"), "")
        default:
            return (2, "", "ironpet: unknown command \(command)\n" + usage)
        }
    }

    static func run(_ arguments: [String]) -> Int32 {
        let result = execute(arguments)
        if !result.out.isEmpty { print(result.out) }
        if !result.err.isEmpty { FileHandle.standardError.write(Data((result.err + "\n").utf8)) }
        return result.code
    }
}
