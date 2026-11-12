import AppKit

/// An app the "Open" button can take the user to.
struct OpenTarget: Equatable {
    var name: String
    var bundleID: String
    /// `{cwd}` is replaced with the percent-encoded session folder. Nil: open the folder with the app.
    var urlTemplate: String?
    /// When no URL handler is registered, open the folder with the app. Off: only activate the app.
    var folderFallback = true
}

enum Editors {
    static let itermID = "com.googlecode.iterm2"
    static let finderID = "com.apple.finder"
    static let cursorID = SourceJumper.cursorBundleID
    static let auto = "auto"

    static let builtIn: [OpenTarget] = [
        OpenTarget(name: "Cursor", bundleID: cursorID),
        OpenTarget(name: "VS Code", bundleID: "com.microsoft.VSCode", urlTemplate: "vscode://file/{cwd}"),
        OpenTarget(name: "Zed", bundleID: "dev.zed.Zed", urlTemplate: "zed://file/{cwd}"),
        OpenTarget(name: "Band", bundleID: "app.getband.agent", urlTemplate: "band://file/{cwd}", folderFallback: false),
        OpenTarget(name: "Windsurf", bundleID: "com.exafunction.windsurf", urlTemplate: "windsurf://file/{cwd}"),
        OpenTarget(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        OpenTarget(name: "Finder", bundleID: finderID),
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
        if let owner = session.origin.ownerBundleID, !owner.isEmpty {
            if let known = (custom(editors) + builtIn).first(where: { $0.bundleID == owner }) { return known }
            return OpenTarget(name: appName(owner) ?? owner, bundleID: owner, folderFallback: false)
        }
        return builtIn.first { $0.bundleID == cursorID && isInstalled(cursorID) }
            ?? builtIn.first { $0.bundleID == finderID }!
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
        let config = ConfigStore.shared.config
        return resolve(session: session, openIn: config.openIn, custom: config.editors,
                       isInstalled: isInstalled, appName: appName)
    }

    @MainActor static func installed() -> [OpenTarget] {
        available(custom: ConfigStore.shared.config.editors, isInstalled: isInstalled)
    }

    @MainActor static func label(for session: AgentSession) -> String {
        "Open in \(target(for: session).name)"
    }
}
