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
            hookScript: home.appendingPathComponent(".ironpet/bin/ironpet-hook"),
            codexHooks: home.appendingPathComponent(".codex/hooks.json"),
            geminiSettings: home.appendingPathComponent(".gemini/settings.json"),
            copilotHooks: home.appendingPathComponent(".copilot/hooks/ironpet.json"),
            piExtension: home.appendingPathComponent(".pi/agent/extensions/ironpet.ts")))
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

    func testInstallRemovesTheRetiredChatApprovalHooks() throws {
        let old = ["version": 1, "hooks": ["beforeShellExecution": [["command": "'/x/.ironpet/bin/ironpet-hook' cursor beforeShellExecution", "timeout": 2_000_000],
                                                                    ["command": "other-tool"]]]] as [String: Any]
        try FileManager.default.createDirectory(at: cursor.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: old).write(to: cursor)
        try installer.install([.cursor])
        let hooks = try XCTUnwrap(try json(cursor)["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(hooks["beforeShellExecution"]?.compactMap { $0["command"] as? String }, ["other-tool"])
        XCTAssertNil(hooks["preToolUse"])
        XCTAssertNotNil(hooks["stop"])
    }

    /// Runs the hook script with a stand-in `curl` that records every call, and returns how many calls were made.
    private func runHook(source: String, event: String, env: [String: String]) throws -> (calls: Int, output: String) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hook-home-\(UUID().uuidString)")
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ironpet"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "47321".write(to: home.appendingPathComponent(".ironpet/port"), atomically: true, encoding: .utf8)
        try "token".write(to: home.appendingPathComponent(".ironpet/token"), atomically: true, encoding: .utf8)
        let curl = bin.appendingPathComponent("curl")
        try "#!/bin/sh\necho call >> \"$HOME/curl.log\"\ncat >/dev/null\n".write(to: curl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
        let script = home.appendingPathComponent("hook")
        try HookScript.contents.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, source, event]
        process.environment = ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin"].merging(env) { $1 }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let log = (try? String(contentsOf: home.appendingPathComponent("curl.log"), encoding: .utf8)) ?? ""
        return (log.split(separator: "\n").count, String(decoding: data, as: UTF8.self))
    }

    func testHookReportsExternalSessionsButSkipsChatsRunOverACP() throws {
        XCTAssertEqual(try runHook(source: "claude", event: "Stop", env: [:]).calls, 1)
        XCTAssertEqual(try runHook(source: "cursor", event: "stop", env: [:]).output.trimmingCharacters(in: .whitespacesAndNewlines), "{}")
        XCTAssertEqual(try runHook(source: "claude", event: "Stop", env: ["IRONPET_ACP_RUN": "1"]).calls, 0)
        let skipped = try runHook(source: "cursor", event: "beforeSubmitPrompt", env: ["IRONPET_ACP_RUN": "1"])
        XCTAssertEqual(skipped.calls, 0)
        XCTAssertEqual(skipped.output.trimmingCharacters(in: .whitespacesAndNewlines), #"{"continue":true}"#, "Cursor still gets the reply it needs")
    }

    func testHookScriptHasNoApprovalGateAnymore() {
        XCTAssertFalse(HookScript.contents.contains("/approval"))
        XCTAssertFalse(HookScript.contents.contains("IRONPET_RUN_ID"))
    }

    // MARK: Codex, Gemini, Copilot, Pi

    private func commands(_ url: URL, event: String) throws -> [String] {
        let hooks = try XCTUnwrap(try json(url)["hooks"] as? [String: [[String: Any]]])
        return (hooks[event] ?? []).flatMap { group -> [String] in
            ((group["hooks"] as? [[String: Any]]) ?? [group]).compactMap { ($0["command"] ?? $0["bash"]) as? String }
        }
    }

    func testCodexAndGeminiShareTheGroupLayoutAndKeepOtherHooks() throws {
        let codex = installer.locations.codexHooks, gemini = installer.locations.geminiSettings
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gemini.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"other-codex-tool"}]}]}}"#.write(to: codex, atomically: true, encoding: .utf8)
        try #"{"theme":"dark","hooks":{"AfterAgent":[{"hooks":[{"type":"command","command":"other-gemini-tool"}]}]}}"#
            .write(to: gemini, atomically: true, encoding: .utf8)
        try installer.install([.codex, .gemini])
        XCTAssertTrue(installer.isInstalled(.codex))
        XCTAssertTrue(installer.isInstalled(.gemini))
        XCTAssertEqual(try commands(codex, event: "Stop").count, 2)
        XCTAssertTrue(try commands(codex, event: "Stop").contains("other-codex-tool"))
        XCTAssertTrue(try commands(codex, event: "UserPromptSubmit")[0].hasSuffix(" codex UserPromptSubmit"))
        XCTAssertTrue(try commands(gemini, event: "BeforeAgent")[0].hasSuffix(" gemini BeforeAgent"))
        XCTAssertEqual(try json(gemini)["theme"] as? String, "dark")
        let entry = try XCTUnwrap(((try json(gemini)["hooks"] as? [String: [[String: Any]]])?["BeforeTool"]?.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["timeout"] as? Int, 5_000, "Gemini counts timeouts in milliseconds")
        XCTAssertEqual(entry["name"] as? String, "ironpet")

        try installer.uninstall([.codex, .gemini])
        XCTAssertFalse(installer.isInstalled(.codex))
        XCTAssertEqual(try commands(codex, event: "Stop"), ["other-codex-tool"])
        XCTAssertEqual(try commands(gemini, event: "AfterAgent"), ["other-gemini-tool"])
        XCTAssertEqual(try json(gemini)["theme"] as? String, "dark")
    }

    func testCopilotGetsItsOwnFileThatUninstallDeletes() throws {
        try installer.install([.copilot])
        let file = installer.locations.copilotHooks
        XCTAssertEqual(try json(file)["version"] as? Int, 1)
        XCTAssertTrue(try commands(file, event: "agentStop")[0].hasSuffix(" copilot agentStop"))
        XCTAssertTrue(installer.isInstalled(.copilot))
        try installer.uninstall([.copilot])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testPiExtensionIsWrittenAndOnlyOurOwnFileIsRemoved() throws {
        try installer.install([.pi])
        let file = installer.locations.piExtension
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(HookInstaller.piMarker))
        XCTAssertTrue(text.contains(installer.locations.hookScript.path))
        XCTAssertTrue(installer.isInstalled(.pi))
        XCTAssertEqual(try installer.install([.pi]), [], "a second install changes nothing")
        try installer.uninstall([.pi])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try "export default function () {}\n".write(to: file, atomically: true, encoding: .utf8)
        try installer.uninstall([.pi])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "a file ironpet did not write is left alone")
    }

    func testHookReplyIsJSONForAgentsThatParseStdout() throws {
        for source in ["codex", "gemini", "copilot", "pi", "cursor"] {
            XCTAssertEqual(try runHook(source: source, event: "Stop", env: [:]).output.trimmingCharacters(in: .whitespacesAndNewlines), "{}", source)
        }
        XCTAssertEqual(try runHook(source: "claude", event: "Stop", env: [:]).output, "", "Claude Code takes no reply")
    }

    func testRefusesToOverwriteACorruptConfig() throws {
        try "{ not json".write(to: claude, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try installer.install([.claude]))
        XCTAssertEqual(try String(contentsOf: claude, encoding: .utf8), "{ not json")
    }
}
