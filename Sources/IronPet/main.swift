import AppKit
import SwiftUI

// `IronPet automations …`, `IronPet tasks …` and `IronPet mcp` talk to the running app and never open a window.
if CommandLine.arguments.dropFirst().first == "automations" {
    exit(AutomationCLI.run(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.dropFirst().first == "tasks" {
    exit(TaskCLI.run(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.dropFirst().first == "skills" {
    exit(SkillCLI.run(Array(CommandLine.arguments.dropFirst(2))))
}
if ["mcp", "mcp-stdio"].contains(CommandLine.arguments.dropFirst().first ?? "") {
    exit(AutomationCLI.stdioBridge())
}

if CommandLine.arguments.contains("--uninstall") {
    // Used by scripts/uninstall.sh: removes only ironpet's hooks and its login item, then exits.
    do {
        let changed = try HookInstaller().uninstall()
        print(changed.isEmpty ? "No ironpet hooks found" : changed.map { "Removed ironpet hooks from \($0.path)" }.joined(separator: "\n"))
    } catch {
        FileHandle.standardError.write(Data("Could not remove hooks: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    if LoginItem.isEnabled {
        LoginItem.set(false)
        print("Removed the login item")
    }
    exit(0)
}

if CommandLine.arguments.contains("--render-previews") {
    MainActor.assumeIsolated { PreviewRenderer.run(arguments: CommandLine.arguments) }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
