import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let root = home.appendingPathComponent(".ironpet")
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
