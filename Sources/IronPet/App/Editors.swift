import AppKit

/// An app the "Open" button can take the user to.
struct OpenTarget: Equatable {
    var name: String
    var bundleID: String
    /// `{cwd}` is replaced with the percent-encoded session folder. Nil: open the folder with the app.
    /// Session placeholders (`{session}`, `{cmux_workspace}`, `{cmux_surface}`, `{t3_env}`, `{t3_thread}`) are
    /// percent-encoded too. A template whose placeholder has no value is skipped and the app is only activated.
    var urlTemplate: String?
    /// When no URL handler is registered, open the folder with the app. Off: only activate the app.
    var folderFallback = true
    /// `{session}` only fills for sessions of this agent. Nil: any agent.
    var source: AgentSource?
    /// Runs before the app is activated, to focus the session inside it. Wins over `urlTemplate`.
    var command: OpenCommand?
}

/// A program and its argument list, run without a shell. `{herdr_terminal}` in an argument is replaced as a whole,
/// so an id with spaces or `;` stays one argument. The executable is a bare name found on `PATH`, in the usual
/// install folders or inside the app bundle, never a value taken from a session.
struct OpenCommand: Equatable {
    var executable: String
    var arguments: [String]
}

enum Editors {
    static let itermID = "com.googlecode.iterm2"
    static let finderID = "com.apple.finder"
    static let cursorID = SourceJumper.cursorBundleID
    static let auto = "auto"

    static let cmuxID = "com.cmuxterm.app"
    static let t3CodeID = "com.t3tools.t3code"
    static let herdrID = "dev.herdr.app"
    /// The headless daemon a herdr agent's process tree reaches first. The desktop app is `herdrID`.
    static let herdrCoreID = "dev.herdr.core"
    static let claudeDesktopID = "com.anthropic.claudefordesktop"
    /// The Codex app ships inside ChatGPT.app and uses this bundle id.
    static let codexID = "com.openai.codex"

    static let builtIn: [OpenTarget] = [
        OpenTarget(name: "Cursor", bundleID: cursorID),
        OpenTarget(name: "VS Code", bundleID: "com.microsoft.VSCode", urlTemplate: "vscode://file/{cwd}"),
        OpenTarget(name: "Zed", bundleID: "dev.zed.Zed", urlTemplate: "zed://file/{cwd}"),
        OpenTarget(name: "Band", bundleID: "app.getband.agent", urlTemplate: "band://file/{cwd}", folderFallback: false),
        OpenTarget(name: "Windsurf", bundleID: "com.exafunction.windsurf", urlTemplate: "windsurf://file/{cwd}"),
        OpenTarget(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        OpenTarget(name: "Finder", bundleID: finderID),
        // Deep links for these come from each app's source or bundle, not from documentation.
        OpenTarget(name: "cmux", bundleID: cmuxID,
                   urlTemplate: "cmux://workspace/{cmux_workspace}/surface/{cmux_surface}", folderFallback: false),
        OpenTarget(name: "T3 Code", bundleID: t3CodeID,
                   urlTemplate: "t3code://threads/{t3_env}/{t3_thread}", folderFallback: false),
        OpenTarget(name: "herdr", bundleID: herdrID, folderFallback: false,
                   command: OpenCommand(executable: "herdr-app",
                                        arguments: ["do", "agent.focus", "--terminal", "{herdr_terminal}"])),
        OpenTarget(name: "Claude", bundleID: claudeDesktopID,
                   urlTemplate: "claude://code/needs-input?session={session}", folderFallback: false, source: .claude),
        OpenTarget(name: "Codex", bundleID: codexID,
                   urlTemplate: "codex://threads/{session}", folderFallback: false, source: .codex),
    ]

    static let iterm = OpenTarget(name: "iTerm", bundleID: itermID, folderFallback: false)

    static func custom(_ editors: [Config.Editor]) -> [OpenTarget] {
        editors.map { OpenTarget(name: $0.name, bundleID: $0.bundleId, urlTemplate: $0.urlTemplate) }
    }

    /// What the picker offers: installed built-ins, then every custom entry. A custom entry replaces the
    /// built-in with the same bundle id.
    static func available(custom editors: [Config.Editor], isInstalled: (String) -> Bool) -> [OpenTarget] {
        let customs = custom(editors)
        let ids = Set(customs.map(\.bundleID))
        return builtIn.filter { !ids.contains($0.bundleID) && isInstalled($0.bundleID) } + customs
    }

    /// The app a session's button opens. `openIn` is `auto` or a bundle id.
    static func resolve(
        session: AgentSession, openIn: String, custom editors: [Config.Editor],
        isInstalled: (String) -> Bool, appName: (String) -> String?
    ) -> OpenTarget {
        let all = available(custom: editors, isInstalled: isInstalled)
        if openIn != auto, let fixed = all.first(where: { $0.bundleID == openIn }) { return fixed }
        if session.isInIterm { return iterm }
        if let raw = session.origin.ownerBundleID, !raw.isEmpty {
            let owner = canonicalOwner(raw)
            if let known = (custom(editors) + builtIn).first(where: { $0.bundleID == owner }) { return known }
            return OpenTarget(name: appName(owner) ?? owner, bundleID: owner, folderFallback: false)
        }
        return builtIn.first { $0.bundleID == cursorID && isInstalled(cursorID) }
            ?? builtIn.first { $0.bundleID == finderID }!
    }

    /// herdr's agents run under the headless `dev.herdr.core`; the app to bring forward is `dev.herdr.app`.
    static func canonicalOwner(_ bundleID: String) -> String {
        bundleID == herdrCoreID ? herdrID : bundleID
    }

    /// The URL that opens `session` in `target`, or nil when the template needs a value the session does not
    /// have. Every session value is percent-encoded down to unreserved characters.
    static func link(
        _ template: String, target: OpenTarget, session: AgentSession?, folder: String?,
        t3EnvironmentID: () -> String?
    ) -> String? {
        var text = template
        if text.contains("{cwd}") {
            guard let folder else { return nil }
            text = expand(text, cwd: folder)
        }
        for (name, value) in values(for: target, session: session, t3EnvironmentID: t3EnvironmentID, only: text) {
            text = text.replacingOccurrences(of: "{\(name)}", with: encode(value))
        }
        return placeholder.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil ? text : nil
    }

    /// The command's arguments with placeholders filled, or nil when one has no value.
    static func arguments(_ command: OpenCommand, target: OpenTarget, session: AgentSession?) -> [String]? {
        let known = values(for: target, session: session, t3EnvironmentID: { nil }, only: command.arguments.joined())
        var result: [String] = []
        for argument in command.arguments {
            let whole = NSRange(argument.startIndex..., in: argument)
            if argument.hasPrefix("{"), argument.hasSuffix("}"), placeholder.firstMatch(in: argument, range: whole)?.range == whole {
                guard let value = known[String(argument.dropFirst().dropLast())] else { return nil }
                result.append(value)
            } else {
                result.append(argument)
            }
        }
        return result
    }

    private static let placeholder = try! NSRegularExpression(pattern: #"\{[a-z0-9_]+\}"#)

    /// Values for the placeholders that appear in `only`. The `t3_env` file is read only when needed.
    private static func values(
        for target: OpenTarget, session: AgentSession?, t3EnvironmentID: () -> String?, only text: String
    ) -> [String: String] {
        guard let session else { return [:] }
        var result: [String: String] = [:]
        if target.source == nil || target.source == session.source, let id = session.agentSessionID { result["session"] = id }
        let origin = session.origin
        for (name, value) in [("cmux_workspace", origin.cmuxWorkspaceID), ("cmux_surface", origin.cmuxSurfaceID),
                              ("t3_thread", origin.t3ThreadID), ("herdr_terminal", origin.herdrTerminalID)] {
            if let value { result[name] = value }
        }
        if text.contains("{t3_env}"), let env = AppIDs.clean(t3EnvironmentID()) { result["t3_env"] = env }
        return result
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    /// T3 Code keeps its environment id in this file.
    static func t3EnvironmentID(home: String = NSHomeDirectory()) -> String? {
        let url = URL(fileURLWithPath: home).appendingPathComponent(".t3/userdata/environment-id")
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replaces `{cwd}` with the folder as a percent-encoded path. After a `/` the path's own leading slash is
    /// dropped, so `zed://file/{cwd}` gives `zed://file/Users/me/x`, not `zed://file//Users/me/x`.
    static func expand(_ template: String, cwd: String) -> String {
        let encoded = cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cwd
        var result = ""
        var rest = Substring(template)
        while let range = rest.range(of: "{cwd}") {
            result += rest[..<range.lowerBound]
            result += result.hasSuffix("/") && encoded.hasPrefix("/") ? String(encoded.dropFirst()) : encoded
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    // MARK: Live lookups

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func appName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let info = Bundle(url: url)?.infoDictionary
        return (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    @MainActor static func target(for session: AgentSession) -> OpenTarget {
        let config = SettingsAPI.live.config
        return resolve(session: session, openIn: config.openIn, custom: config.editors,
                       isInstalled: isInstalled, appName: appName)
    }

    @MainActor static func installed() -> [OpenTarget] {
        available(custom: SettingsAPI.live.config.editors, isInstalled: isInstalled)
    }

    @MainActor static func label(for session: AgentSession) -> String {
        session.source == .job ? "Open the job's thread" : "Open in \(target(for: session).name)"
    }
}
