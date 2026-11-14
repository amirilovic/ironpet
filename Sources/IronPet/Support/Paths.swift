import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    /// `~/.ironpet`. `IRONPET_ROOT` moves it so a second copy of the app, such as an end-to-end test run, keeps its own port,
    /// token, settings and threads.
    static let root = ProcessInfo.processInfo.environment["IRONPET_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? home.appendingPathComponent(".ironpet")
    static let isIsolated = ProcessInfo.processInfo.environment["IRONPET_ROOT"] != nil
    static let bin = root.appendingPathComponent("bin")
    static let hookScript = bin.appendingPathComponent("ironpet-hook")
    static let portFile = root.appendingPathComponent("port")
    static let tokenFile = root.appendingPathComponent("token")
    static let petDir = root.appendingPathComponent("pet")
    static let cursorHooks = home.appendingPathComponent(".cursor/hooks.json")
    static let claudeSettings = home.appendingPathComponent(".claude/settings.json")

    static func ensureRoot() throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }
}
