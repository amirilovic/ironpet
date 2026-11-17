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
    // `--tasks-readonly` talks to the read-only scope, for the screen capture analysis turn.
    let readOnly = CommandLine.arguments.contains("--tasks-readonly")
    exit(AutomationCLI.stdioBridge(path: readOnly ? MCPEndpoint.readOnlyTasksPath : "/mcp"))
}

if CommandLine.arguments.contains("--uninstall") {
    // Used by scripts/uninstall.sh: removes only ironpet's hooks, its login item and the clean worktrees of task runs, then exits.
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
    MainActor.assumeIsolated { TaskRunUninstall.run() }.forEach { print($0) } // top-level code runs on the main thread before NSApplication starts
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
