import XCTest
@testable import IronPet

final class SkillInstallerTests: XCTestCase {
    private var home: URL!
    private var installer: SkillInstaller { SkillInstaller(home: home) }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    private func skillFile(_ path: String) -> String? {
        try? String(contentsOf: home.appendingPathComponent(path).appendingPathComponent("SKILL.md"), encoding: .utf8)
    }

    private func linkDestination(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(path).path)
    }

    func testEverySkillFolderInTheRepoIsBundledAndUpToDate() throws {
        let skills = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("skills")
        let folders = try FileManager.default.contentsOfDirectory(atPath: skills.path).filter { !$0.hasPrefix(".") }.sorted()
        XCTAssertEqual(folders, BundledSkills.all.map(\.name).sorted(), "a skill folder is not bundled, or the other way round. Run scripts/gen_skills.py")
        for folder in folders {
            let text = try String(contentsOf: skills.appendingPathComponent(folder).appendingPathComponent("SKILL.md"), encoding: .utf8)
            XCTAssertEqual(text, BundledSkills.named(folder)?.content, "skills/\(folder)/SKILL.md changed. Run scripts/gen_skills.py")
            XCTAssertTrue(text.hasPrefix("---\nname: \(folder)\ndescription: "))
        }
        XCTAssertNotNil(BundledSkills.named("ironpet-automations"))
    }

    func testSkillSummaryIsTheFirstSentenceOfTheDescription() {
        let skill = BundledSkill(name: "demo", content: "---\nname: demo\ndescription: Does a thing. Then more detail.\n---\nbody\n")
        XCTAssertEqual(skill.description, "Does a thing. Then more detail.")
        XCTAssertEqual(skill.summary, "Does a thing")
    }

    func testInstallWritesTheRealCopyAndLinksEachAgentFoundOnTheMac() throws {
        try mkdir(".claude")
        try mkdir(".cursor")
        let outcomes = try installer.install()
        XCTAssertEqual(skillFile(".agents/skills/ironpet-automations"), BundledSkills.all[0].content)
        XCTAssertEqual(linkDestination(".claude/skills/ironpet-automations"), "../../.agents/skills/ironpet-automations")
        XCTAssertEqual(linkDestination(".cursor/skills/ironpet-automations"), "../../.agents/skills/ironpet-automations")
        XCTAssertEqual(skillFile(".claude/skills/ironpet-automations"), BundledSkills.all[0].content, "the link resolves to the real copy")
        XCTAssertEqual(Set(outcomes.map(\.agent.id)), ["universal", "claude-code", "cursor"])
        XCTAssertEqual(outcomes.filter { $0.result == "linked" }.count, 2)
        XCTAssertNil(linkDestination(".gemini/skills/ironpet-automations"), "an agent that is not on this Mac gets nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini").path))
    }

    func testRelativeLinksAreRightForDeeperFolders() throws {
        try mkdir(".config/opencode")
        try installer.install()
        let link = home.appendingPathComponent(".config/opencode/skills/ironpet-automations")
        XCTAssertEqual(linkDestination(".config/opencode/skills/ironpet-automations"), "../../../.agents/skills/ironpet-automations")
        XCTAssertEqual(try String(contentsOf: link.appendingPathComponent("SKILL.md"), encoding: .utf8), BundledSkills.all[0].content)
    }

    func testInstallingAgainChangesNothingAndStatusIsCurrent() throws {
        try mkdir(".claude")
        try installer.install()
        let again = try installer.install()
        XCTAssertEqual(again.first { $0.agent.id == "claude-code" }?.result, "current")
        let status = installer.status()
        XCTAssertEqual(status.canonical, .current)
        XCTAssertFalse(status.needsInstall)
        XCTAssertTrue(status.isInstalledAnywhere)
        XCTAssertEqual(status.linkedNames, ["Claude Code"])
    }

    func testAnOldCopyIsOutdatedAndUpdatingFixesEveryAgentAtOnce() throws {
        try mkdir(".claude")
        try mkdir(".cursor")
        try installer.install()
        try "---\nname: ironpet-automations\ndescription: old\n---\nold text\n"
            .write(to: home.appendingPathComponent(".agents/skills/ironpet-automations/SKILL.md"), atomically: true, encoding: .utf8)
        var status = installer.status()
        XCTAssertEqual(status.canonical, .outdated)
        XCTAssertTrue(status.hasOutdated)
        XCTAssertTrue(status.needsInstall)
        XCTAssertEqual(status.agents.first { $0.agent.id == "claude-code" }?.state, .outdated, "the link shows the old text")
        try installer.install()
        status = installer.status()
        XCTAssertEqual(status.canonical, .current)
        XCTAssertFalse(status.needsInstall)
        XCTAssertEqual(skillFile(".cursor/skills/ironpet-automations"), BundledSkills.all[0].content)
    }

    func testAnAgentInstalledLaterIsPickedUpByTheNextInstall() throws {
        try mkdir(".claude")
        try installer.install()
        XCTAssertFalse(installer.status().needsInstall)
        try mkdir(".gemini")
        XCTAssertTrue(installer.status().needsInstall, "Gemini is on the Mac now and has no skill")
        try installer.install()
        XCTAssertNotNil(linkDestination(".gemini/skills/ironpet-automations"))
    }

    func testAnotherSkillWithTheSameNameIsLeftAlone() throws {
        try mkdir(".claude/skills/ironpet-automations")
        try "# mine\n".write(to: home.appendingPathComponent(".claude/skills/ironpet-automations/SKILL.md"), atomically: true, encoding: .utf8)
        let outcomes = try installer.install()
        XCTAssertEqual(outcomes.first { $0.agent.id == "claude-code" }?.result, "skipped")
        XCTAssertEqual(skillFile(".claude/skills/ironpet-automations"), "# mine\n")
        XCTAssertEqual(installer.status().agents.first { $0.agent.id == "claude-code" }?.state, .foreign)
        XCTAssertTrue(installer.remove().allSatisfy { $0.agent.id == "universal" }, "remove keeps it too")
        XCTAssertEqual(skillFile(".claude/skills/ironpet-automations"), "# mine\n")
    }

    func testCopyModeWritesSeparateCopies() throws {
        try mkdir(".claude")
        let outcomes = try installer.install(copy: true)
        XCTAssertEqual(outcomes.first { $0.agent.id == "claude-code" }?.result, "copied")
        XCTAssertNil(linkDestination(".claude/skills/ironpet-automations"), "a real folder, not a link")
        XCTAssertEqual(skillFile(".claude/skills/ironpet-automations"), BundledSkills.all[0].content)
        // Updating from a copy to a link replaces the old copy.
        try installer.install()
        XCTAssertNotNil(linkDestination(".claude/skills/ironpet-automations"))
    }

    func testChoosingAgentsInstallsOnlyThoseEvenIfNotDetected() throws {
        let cursor = try XCTUnwrap(SkillInstaller.agents.first { $0.id == "cursor" })
        try mkdir(".claude")
        try installer.install(agents: [cursor])
        XCTAssertNotNil(linkDestination(".cursor/skills/ironpet-automations"))
        XCTAssertNil(linkDestination(".claude/skills/ironpet-automations"))
    }

    func testRemoveDeletesLinksCopiesAndTheRealCopy() throws {
        try mkdir(".claude")
        try mkdir(".cursor")
        try installer.install()
        try installer.install(agents: SkillInstaller.agents.filter { $0.id == "cursor" }, copy: true)
        let removed = installer.remove()
        XCTAssertEqual(Set(removed.map(\.agent.id)), ["claude-code", "cursor", "universal"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents/skills/ironpet-automations").path))
        XCTAssertNil(linkDestination(".claude/skills/ironpet-automations"))
        XCTAssertFalse(installer.status().isInstalledAnywhere)
        XCTAssertTrue(installer.remove().isEmpty)
    }

    func testPromptOnlyWhenSomethingIsMissingAndNotAlreadyDeclined() throws {
        let manager = SkillManager(home: home)
        XCTAssertTrue(SkillPrompt.pending(manager.entries(), dismissed: []).isEmpty, "no agent on this Mac, nothing to offer")
        try mkdir(".claude")
        let missing = SkillPrompt.pending(manager.entries(), dismissed: [])
        XCTAssertEqual(missing.map(\.skill.name), ["ironpet-automations"])
        XCTAssertEqual(SkillPrompt.message(missing).title, "Install agent skill")
        XCTAssertEqual(SkillPrompt.message(missing).button, "Install")
        XCTAssertTrue(SkillPrompt.message(missing).body.contains("Claude Code"))
        XCTAssertTrue(SkillPrompt.pending(manager.entries(), dismissed: [BundledSkills.all[0].hash]).isEmpty, "the user said not now to this version")
        XCTAssertEqual(SkillPrompt.pending(manager.entries(), dismissed: ["an older version"]).count, 1, "a new version asks again")
        try manager.install()
        XCTAssertTrue(SkillPrompt.pending(manager.entries(), dismissed: []).isEmpty)
        try "---\nname: ironpet-automations\n---\nold\n".write(to: home.appendingPathComponent(".agents/skills/ironpet-automations/SKILL.md"), atomically: true, encoding: .utf8)
        let outdated = SkillPrompt.pending(manager.entries(), dismissed: [])
        XCTAssertEqual(outdated.count, 1)
        XCTAssertEqual(SkillPrompt.message(outdated).title, "Update agent skill")
        XCTAssertEqual(SkillPrompt.message(outdated).button, "Update")
    }

    // MARK: More than one skill

    private func twoSkills() -> SkillManager {
        SkillManager(home: home, skills: [
            BundledSkills.all[0],
            BundledSkill(name: "ironpet-demo", content: "---\nname: ironpet-demo\ndescription: A second skill. More.\n---\n# demo\n"),
        ])
    }

    func testSeveralSkillsInstallAndLinkSideBySide() throws {
        try mkdir(".claude")
        let manager = twoSkills()
        let results = try manager.install()
        XCTAssertEqual(results.map(\.skill.name), ["ironpet-automations", "ironpet-demo"])
        XCTAssertEqual(linkDestination(".claude/skills/ironpet-demo"), "../../.agents/skills/ironpet-demo")
        XCTAssertEqual(skillFile(".claude/skills/ironpet-demo"), "---\nname: ironpet-demo\ndescription: A second skill. More.\n---\n# demo\n")
        XCTAssertNotNil(linkDestination(".claude/skills/ironpet-automations"))
        XCTAssertTrue(manager.entries().allSatisfy { !$0.status.needsInstall })
    }

    func testInstallingOneNamedSkillLeavesTheOtherAlone() throws {
        try mkdir(".claude")
        let manager = twoSkills()
        try manager.install(names: ["ironpet-demo"])
        XCTAssertNotNil(linkDestination(".claude/skills/ironpet-demo"))
        XCTAssertNil(linkDestination(".claude/skills/ironpet-automations"))
        manager.remove(names: ["ironpet-demo"])
        XCTAssertNil(linkDestination(".claude/skills/ironpet-demo"))
    }

    func testUpdateTouchesOnlyInstalledSkillsThatAreOutOfDate() throws {
        try mkdir(".claude")
        try mkdir(".cursor")
        let manager = twoSkills()
        try manager.install(names: ["ironpet-automations"])
        try "---\nname: ironpet-automations\ndescription: old\n---\nold\n".write(to: home.appendingPathComponent(".agents/skills/ironpet-automations/SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(manager.updateInstalled(), ["ironpet-automations"])
        XCTAssertEqual(skillFile(".cursor/skills/ironpet-automations"), BundledSkills.all[0].content)
        XCTAssertNil(linkDestination(".claude/skills/ironpet-demo"), "a skill that was never installed is not added by an update")
        XCTAssertEqual(manager.updateInstalled(), [], "nothing is out of date now")
    }

    func testUpdateKeepsAnAgentThatChoseCopiesOnCopies() throws {
        try mkdir(".claude")
        let manager = twoSkills()
        try manager.install(names: ["ironpet-demo"], copy: true)
        try "---\nname: ironpet-demo\ndescription: old\n---\nold\n".write(to: home.appendingPathComponent(".claude/skills/ironpet-demo/SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(manager.updateInstalled(), ["ironpet-demo"])
        XCTAssertEqual(skillFile(".claude/skills/ironpet-demo"), manager.skills[1].content)
    }

    func testOneBubbleListsEverySkillThatNeedsAttention() throws {
        try mkdir(".claude")
        let manager = twoSkills()
        let pending = SkillPrompt.pending(manager.entries(), dismissed: [])
        XCTAssertEqual(pending.count, 2)
        let message = SkillPrompt.message(pending)
        XCTAssertEqual(message.title, "Install agent skills")
        XCTAssertTrue(message.body.contains("ironpet-automations, ironpet-demo"))
        // One skill dismissed, one not.
        XCTAssertEqual(SkillPrompt.pending(manager.entries(), dismissed: [manager.skills[0].hash]).map(\.skill.name), ["ironpet-demo"])
        // An installed one that is out of date and a missing one: the button says Install, because something is new.
        try manager.install(names: ["ironpet-automations"])
        try "---\nname: ironpet-automations\ndescription: old\n---\nold\n".write(to: home.appendingPathComponent(".agents/skills/ironpet-automations/SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SkillPrompt.message(SkillPrompt.pending(manager.entries(), dismissed: [])).button, "Install")
    }

    func testDismissalsAreKeptPerVersion() {
        UserDefaults.standard.removeObject(forKey: SkillPrompt.dismissedKey)
        defer { UserDefaults.standard.removeObject(forKey: SkillPrompt.dismissedKey) }
        let manager = twoSkills()
        SkillPrompt.dismiss([manager.entries()[0]])
        XCTAssertEqual(SkillPrompt.dismissed(), [manager.skills[0].hash])
        SkillPrompt.dismiss([manager.entries()[1]])
        XCTAssertEqual(SkillPrompt.dismissed(), Set(manager.skills.map(\.hash)))
    }

    func testAutoUpdateSettingIsOnByDefaultAndCanBeTurnedOff() throws {
        XCTAssertTrue(Config().skills.autoUpdate)
        let file = home.appendingPathComponent("config.json")
        try #"{"skills":{"autoUpdate":false}}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(Config.load(from: file).config.skills.autoUpdate)
    }

    func testCLIInstallStatusUpdateListAgentsAndRemove() throws {
        try mkdir(".claude")
        let manager = twoSkills()
        func cli(_ args: [String]) -> (code: Int32, out: String, err: String) { SkillCLI.execute(args, manager: manager) }
        XCTAssertTrue(cli(["status"]).out.contains("Run `IronPet skills install`"))
        XCTAssertEqual(cli(["list"]).out, "ironpet-automations\t\(BundledSkills.all[0].summary)\nironpet-demo\tA second skill")
        let install = cli(["install"])
        XCTAssertEqual(install.code, 0, install.err)
        XCTAssertTrue(install.out.contains("ironpet-demo\n"), install.out)
        XCTAssertEqual(install.out.components(separatedBy: "Claude Code: linked").count - 1, 2, "once for each skill")
        XCTAssertTrue(cli(["status"]).out.contains("Up to date."))
        XCTAssertTrue(cli(["agents"]).out.contains("claude-code\tClaude Code\t~/.claude/skills"))
        XCTAssertEqual(cli(["update"]).out, "Nothing to update.")
        let bad = cli(["install", "--agent", "nope"])
        XCTAssertEqual(bad.code, 1)
        XCTAssertTrue(bad.err.contains("unknown agent nope"))
        let unknown = cli(["install", "nothing-like-this"])
        XCTAssertEqual(unknown.code, 1)
        XCTAssertTrue(unknown.err.contains("unknown skill nothing-like-this"))
        let copied = cli(["install", "ironpet-demo", "--agent", "cursor", "--copy"])
        XCTAssertEqual(copied.code, 0, copied.out + copied.err)
        XCTAssertNil(linkDestination(".cursor/skills/ironpet-demo"))
        XCTAssertNotNil(skillFile(".cursor/skills/ironpet-demo"))
        XCTAssertNil(skillFile(".cursor/skills/ironpet-automations"), "only the named skill went to Cursor")
        XCTAssertTrue(cli(["remove", "ironpet-demo"]).out.contains("Claude Code: removed"))
        XCTAssertNotNil(linkDestination(".claude/skills/ironpet-automations"))
        XCTAssertEqual(cli(["bogus"]).code, 2)
    }
}
