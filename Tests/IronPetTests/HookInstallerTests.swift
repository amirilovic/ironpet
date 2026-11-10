import XCTest
@testable import IronPet

/// The installer edits other tools' config files, so it must add and remove only its own entries.
final class HookInstallerTests: XCTestCase {
    private var home: URL!
    private var installer: HookInstaller!
    private var cursor: URL { installer.locations.cursorHooks }
    private var claude: URL { installer.locations.claudeSettings }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        installer = HookInstaller(locations: .init(
            cursorHooks: home.appendingPathComponent(".cursor/hooks.json"),
            claudeSettings: home.appendingPathComponent(".claude/settings.json"),
            hookScript: home.appendingPathComponent(".ironpet/bin/ironpet-hook")))
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    private func writeClaudeSettings() throws {
        try #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"other-tool"}]}]}}"#
            .write(to: claude, atomically: true, encoding: .utf8)
    }

    func testInstallsOnlyTheChosenAgent() throws {
        try writeClaudeSettings()
        XCTAssertEqual(try installer.install([.claude]), [claude])
        XCTAssertTrue(installer.isInstalled(.claude))
        XCTAssertFalse(installer.isInstalled(.cursor))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cursor.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installer.locations.hookScript.path))
    }

    func testKeepsOtherToolsHooksAndSettings() throws {
        try writeClaudeSettings()
        try installer.install([.claude])
        let root = try json(claude)
        XCTAssertEqual(root["model"] as? String, "opus")
        let stop = try XCTUnwrap((root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2, "the other tool's Stop hook plus ironpet's")
    }

    func testBacksUpTheOriginalOnce() throws {
        try writeClaudeSettings()
        let original = try Data(contentsOf: claude)
        try installer.install([.claude])
        try installer.uninstall([.claude])
        try installer.install([.claude])
        let backup = claude.appendingPathExtension("ironpet-backup")
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testReinstallIsANoOp() throws {
        try installer.install([.cursor, .claude])
        XCTAssertEqual(try installer.install([.cursor, .claude]), [])
    }

    func testUninstallRestoresEverythingElse() throws {
        try writeClaudeSettings()
        try installer.install([.claude])
        try installer.uninstall([.claude])
        XCTAssertFalse(installer.isInstalled(.claude))
        let root = try json(claude)
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertEqual((root["hooks"] as? [String: Any])?.keys.sorted(), ["Stop"])
    }

    func testUninstallWithoutConfigFilesCreatesNothing() throws {
        XCTAssertEqual(try installer.uninstall(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cursor.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.path))
    }

    func testApprovalGatesHaveFiniteTimeouts() throws {
        try installer.install([.cursor])
        let hooks = try XCTUnwrap(try json(cursor)["hooks"] as? [String: [[String: Any]]])
        for event in HookInstaller.cursorGateEvents {
            let timeout = try XCTUnwrap(hooks[event]?.first?["timeout"] as? Int, event)
            XCTAssertLessThan(timeout, Int(Int32.max) / 1000, "Cursor skips (fails open on) hooks with overflowing timeouts")
        }
    }

    func testRefusesToOverwriteACorruptConfig() throws {
        try "{ not json".write(to: claude, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try installer.install([.claude]))
        XCTAssertEqual(try String(contentsOf: claude, encoding: .utf8), "{ not json")
    }
}
