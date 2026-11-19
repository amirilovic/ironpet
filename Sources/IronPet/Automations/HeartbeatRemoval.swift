import CryptoKit
import Foundation

/// Cleans up after the heartbeat feature, which ironpet no longer has. It removes the built-in `heartbeat` automation and the
/// bundled `heartbeat` skill. It never touches `~/.ironpet/HEARTBEAT.md`, which belongs to the user.
enum HeartbeatRemoval {
    static let automationID = "heartbeat"
    static let prompt = "/heartbeat"
    static let skillName = "heartbeat"
    /// SHA-256 of every `skills/heartbeat/SKILL.md` that ironpet shipped.
    static let shippedSkillHashes: Set<String> = ["79c0da2408efde09089ffae74de77a563b9728ab744042cb03391314ddb42345"]
    static let doneKey = "heartbeatRemoved"

    /// Runs the removal and records that it is done only when both steps succeeded. An `automations.json` that cannot be
    /// read, or a write or delete that fails, leaves the flag unset so the next launch tries again.
    @MainActor
    static func runOnce(store: AutomationStore, home: URL = SkillInstaller.standardHome, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        let automationDone = removeAutomation(from: store)
        let skill = removeSkill(home: home)
        if automationDone, skill.failed == 0 { defaults.set(true, forKey: doneKey) }
    }

    /// Deletes the automation with id `heartbeat` when it is the built-in one: a `prompt` action that sends `/heartbeat`.
    /// Any other automation stays, including one of the user's that sends `/heartbeat` under another id.
    /// Returns false when the file could not be read or the write failed, so the caller retries later. Returns true when
    /// the automation is gone, including when it was never there.
    @MainActor
    static func removeAutomation(from store: AutomationStore) -> Bool {
        guard store.error == nil else { return false }
        let list = store.automations
        guard list.contains(where: isBuiltIn) else { return true }
        return (try? store.replace(list.filter { !isBuiltIn($0) })) != nil
    }

    private static func isBuiltIn(_ a: Automation) -> Bool {
        a.id == automationID && a.action.type == "prompt" && a.action.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) == prompt
    }

    /// Removes the skill folders and links that `SkillInstaller` wrote, where the text is one that ironpet shipped.
    /// An edited copy stays. Returns how many entries it removed and how many it failed to remove.
    @discardableResult
    static func removeSkill(home: URL) -> (removed: Int, failed: Int) {
        let fm = FileManager.default
        var removed = 0, failed = 0
        // Agent links and copies first, then the real copy they point at.
        let folders = SkillInstaller.agents.sorted { !$0.universal && $1.universal }
            .map { home.appendingPathComponent($0.dir).appendingPathComponent(skillName) }
        for folder in folders {
            if let destination = try? fm.destinationOfSymbolicLink(atPath: folder.path) {
                let target = URL(fileURLWithPath: destination, relativeTo: folder.deletingLastPathComponent())
                // A link that ironpet wrote points at a copy that is gone or unedited.
                guard !fm.fileExists(atPath: target.path) || isShipped(target) else { continue }
            } else {
                guard fm.fileExists(atPath: folder.path), isShipped(folder) else { continue }
            }
            if (try? fm.removeItem(at: folder)) != nil { removed += 1 } else { failed += 1 }
        }
        return (removed, failed)
    }

    private static func isShipped(_ folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("SKILL.md")) else { return false }
        return shippedSkillHashes.contains(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}
