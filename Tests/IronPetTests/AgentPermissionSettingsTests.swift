import XCTest
@testable import IronPet

final class AgentPermissionSettingsTests: XCTestCase {
    private var home: URL!
    private var worktrees: URL!
    private var copy: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-agent-settings-\(UUID().uuidString)")
        worktrees = home.appendingPathComponent(".ironpet/worktrees")
        copy = worktrees.appendingPathComponent("app-1a2b3c4d/fix-login")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ json: String, to path: String, in base: URL? = nil) throws {
        let file = (base ?? home).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: file, atomically: true, encoding: .utf8)
    }

    private func settings(_ environment: [String: String] = [:]) -> AgentPermissionSettings {
        AgentPermissionSettings(home: home, environment: environment, claudeManaged: home.appendingPathComponent("managed-settings.json"))
    }

    private func cursor(_ folder: URL? = nil, _ environment: [String: String] = [:]) -> String? {
        settings(environment).refusal(agent: "cursor", name: "Cursor", folder: folder, stop: worktrees)
    }

    private func claude(_ folder: URL? = nil, _ environment: [String: String] = [:]) -> String? {
        settings(environment).refusal(agent: "claude", name: "Claude Code", folder: folder, stop: worktrees)
    }

    func testCursorWithoutSettingsOrWithOnlyReadRulesAsks() throws {
        XCTAssertNil(cursor(copy), "no cli-config.json")
        try write(#"{"approvalMode": "allowlist", "permissions": {"allow": ["Read(src/**)", "WebFetch(github.com)", "WebSearch"], "deny": ["Shell(rm)"]}, "sandbox": {"mode": "disabled"}}"#,
                  to: ".cursor/cli-config.json")
        XCTAssertNil(cursor(copy))
        try write("not json", to: ".cursor/cli-config.json")
        XCTAssertNil(cursor(copy), "a file Cursor itself would regenerate")
    }

    func testCursorRunEverythingAndAllowRulesRefuseWithTheSettingNamed() throws {
        // The shape of this Mac's file when the e2e run found Cursor running commands without a card.
        try write(#"{"approvalMode": "unrestricted", "permissions": {"allow": ["Shell(ls)", "Shell(python)", "Shell(find)", "WebFetch(api.github.com)", "Shell(sleep)", "Mcp(hodor:*)"]}, "sandbox": {"mode": "disabled"}}"#,
                  to: ".cursor/cli-config.json")
        XCTAssertEqual(cursor(), """
            Cursor's own settings would let it run commands or change files without asking ironpet, so it cannot work on a task. \
            ~/.cursor/cli-config.json sets approvalMode to "unrestricted". Set it to "allowlist". \
            ~/.cursor/cli-config.json allows Shell(ls), Shell(python), Shell(find) and 2 more in permissions.allow. Remove them; Read, WebFetch and WebSearch rules can stay.
            """)
        try write(#"{"approvalMode": "allowlist", "permissions": {"allow": ["Shell(ls)"]}}"#, to: ".cursor/cli-config.json")
        XCTAssertEqual(cursor(), """
            Cursor's own settings would let it run commands or change files without asking ironpet, so it cannot work on a task. \
            ~/.cursor/cli-config.json allows Shell(ls) in permissions.allow. Remove them; Read, WebFetch and WebSearch rules can stay.
            """, "Cursor's stock allow rule runs ls unasked too")
        try write(#"{"approvalMode": "auto-review"}"#, to: ".cursor/cli-config.json")
        XCTAssertTrue(cursor()?.contains("sets approvalMode to \"auto-review\"") == true, "a classifier deciding is not the user")
        try write(#"{"sandbox": {"mode": "enabled"}}"#, to: ".cursor/cli-config.json")
        XCTAssertTrue(cursor()?.contains("sets sandbox.mode to \"enabled\"") == true)
    }

    func testCursorConfigFolderFollowsItsEnvironmentVariables() throws {
        try write(#"{"approvalMode": "unrestricted"}"#, to: "custom/cli-config.json")
        try write(#"{"approvalMode": "unrestricted"}"#, to: "xdg/cursor/cli-config.json")
        XCTAssertNil(cursor(), "~/.cursor has no file")
        XCTAssertTrue(cursor(nil, ["CURSOR_CONFIG_DIR": home.appendingPathComponent("custom").path])?.contains("~/custom/cli-config.json") == true)
        XCTAssertTrue(cursor(nil, ["XDG_CONFIG_HOME": home.appendingPathComponent("xdg").path])?.contains("~/xdg/cursor/cli-config.json") == true)
        XCTAssertTrue(cursor(nil, ["CURSOR_CONFIG_DIR": " ", "XDG_CONFIG_HOME": home.appendingPathComponent("xdg").path]) != nil, "a blank CURSOR_CONFIG_DIR is ignored")
    }

    func testCursorProjectFilesInTheCopyCount() throws {
        try write(#"{"approvalMode": "unrestricted"}"#, to: ".cursor/cli.json", in: copy)
        XCTAssertNil(cursor(), "only the user's settings without a folder")
        XCTAssertTrue(cursor(copy)?.contains("\(copy.path.replacingOccurrences(of: home.path, with: "~"))/.cursor/cli.json sets approvalMode") == true)
        let sub = copy.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertNotNil(cursor(sub), "a chat in a subfolder of the copy sees the copy's file, as Cursor walks down from the git root")
        try write(#"{"permissions": {"allow": ["Write(**)"]}}"#, to: ".cursor/cli.json", in: worktrees)
        try FileManager.default.removeItem(at: copy.appendingPathComponent(".cursor"))
        XCTAssertNil(cursor(copy), "nothing above the copies folder is read")
    }

    func testClaudeAllowRulesForCommandsEditsOrMCPToolsRefuse() throws {
        XCTAssertNil(claude(copy))
        try write(#"{"permissions": {"allow": ["Read(~/notes/**)", "Grep", "Glob", "LS", "WebFetch(domain:www.prh.fi)", "WebSearch"], "defaultMode": "bypassPermissions"}}"#,
                  to: ".claude/settings.json")
        XCTAssertNil(claude(copy), "read-only rules can stay, and the run switches the mode itself")
        try write(#"{"permissions": {"allow": ["mcp__hodor__*"]}}"#, to: ".claude/settings.json")
        XCTAssertEqual(claude(), """
            Claude Code's own settings would let it run commands or change files without asking ironpet, so it cannot work on a task. \
            ~/.claude/settings.json allows mcp__hodor__* in permissions.allow. Remove them; Read, Grep, Glob, LS, WebFetch and WebSearch rules can stay.
            """)
        try write(#"{}"#, to: ".claude/settings.json")
        try write(#"{"permissions": {"allow": ["Bash(npm test:*)", "Write(*)"]}}"#, to: ".claude/settings.local.json", in: copy)
        XCTAssertNil(claude(), "the project's files only with a folder")
        XCTAssertTrue(claude(copy)?.contains("/fix-login/.claude/settings.local.json allows Bash(npm test:*) and Write(*)") == true)
    }

    func testClaudeConfigFolderAndManagedSettingsCount() throws {
        try write(#"{"permissions": {"allow": ["Edit"]}}"#, to: "claude-home/settings.json")
        XCTAssertTrue(claude(nil, ["CLAUDE_CONFIG_DIR": home.appendingPathComponent("claude-home").path])?.contains("~/claude-home/settings.json allows Edit") == true)
        try write(#"{"permissions": {"allow": ["Bash"]}}"#, to: "managed-settings.json")
        XCTAssertTrue(claude()?.contains("managed-settings.json allows Bash") == true)
    }

    func testOtherAgentsAreLeftToTheirModes() throws {
        try write(#"{"approvalMode": "unrestricted"}"#, to: ".cursor/cli-config.json")
        XCTAssertNil(settings().refusal(agent: "codex", name: "Codex", folder: copy, stop: worktrees))
        XCTAssertNil(settings().refusal(agent: "gemini", name: "Gemini CLI", folder: copy, stop: worktrees))
    }

    func testRuleTool() {
        XCTAssertEqual(AgentPermissionSettings.ruleTool("Shell(ls)"), "Shell")
        XCTAssertEqual(AgentPermissionSettings.ruleTool(" WebFetch (domain:x) "), "WebFetch")
        XCTAssertEqual(AgentPermissionSettings.ruleTool("mcp__hodor__*"), "mcp__hodor__*")
        XCTAssertEqual(AgentPermissionSettings.ruleTool("Read"), "Read")
    }
}
