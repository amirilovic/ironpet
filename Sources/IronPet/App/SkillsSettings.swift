import SwiftUI

/// The Skills section of the General tab: every skill that ships with ironpet, whether agents have it, and a switch to keep
/// the installed ones up to date without asking.
struct SkillsSettings: View {
    @ObservedObject private var store = ConfigStore.shared
    @State private var entries = SkillManager.standard.entries()
    @State private var note: String?

    var body: some View {
        Section("Skills") {
            ForEach(entries, id: \.skill.name) { entry in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.skill.name)
                        Text(statusText(entry.status)).font(.caption).foregroundStyle(entry.status.hasOutdated ? Color.orange : Color.secondary)
                    }
                    Spacer(minLength: 12)
                    Button(entry.status.hasOutdated ? "Update" : entry.status.isInstalledAnywhere ? "Reinstall" : "Install") { install(entry.skill) }
                    if entry.status.isInstalledAnywhere { Button("Remove") { remove(entry.skill) } }
                }
            }
            Toggle("Update skills automatically", isOn: Binding(
                get: { store.config.skills.autoUpdate },
                set: { on in
                    store.update { $0.skills.autoUpdate = on }
                    if on { SkillManager.standard.updateInstalled(); reload() }
                }))
            if let note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear(perform: reload)
    }

    private func reload() { entries = SkillManager.standard.entries() }

    private func statusText(_ status: SkillInstaller.Status) -> String {
        if !status.isInstalledAnywhere { return "Not installed" }
        if status.hasOutdated { return "Update available" }
        let names = status.linkedNames + (status.canonical == .current ? ["Codex and others"] : [])
        return "Installed for " + names.joined(separator: ", ")
    }

    private func install(_ skill: BundledSkill) {
        do {
            let results = try SkillManager.standard.install(names: [skill.name])
            let problems = results.flatMap(\.outcomes).filter { $0.result == "failed" || $0.result == "skipped" }.map { "\($0.agent.name): \($0.note ?? $0.result)" }
            note = problems.isEmpty ? nil : problems.joined(separator: "\n")
        } catch { note = error.localizedDescription }
        reload()
    }

    private func remove(_ skill: BundledSkill) {
        SkillManager.standard.remove(names: [skill.name])
        note = nil
        reload()
    }
}
