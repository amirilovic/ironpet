import AppKit
import SwiftUI

/// What Settings → Memory shows and does: the recent changes with Undo, the files with an editor, and search. The rules (writing,
/// undo, history) live in `FileMemoryStore`; this only calls them and keeps the page's state.
@MainActor
final class MemorySettingsModel: ObservableObject {
    let store: FileMemoryStore
    let index: MemoryIndex?
    private weak var reflector: MemoryReflector?
    @Published private(set) var changes: [MemoryChange] = []
    /// Why the last reflection pass failed, until one succeeds.
    @Published private(set) var lastError: String?
    @Published private(set) var files: [MemoryFile] = []
    /// The file open in the editor, by its path inside the memory folder.
    @Published private(set) var selected: String?
    @Published var draft = ""
    @Published private(set) var saved = ""
    @Published private(set) var message: String?
    /// Why the last Undo did nothing.
    @Published private(set) var undoMessage: String?

    init(store: FileMemoryStore, index: MemoryIndex?, reflector: MemoryReflector? = nil) {
        self.store = store
        self.index = index
        self.reflector = reflector
        reload()
    }

    var hasUnsavedEdit: Bool { draft != saved }

    /// "About me", "People" or the project's name, for a path inside the memory folder.
    func title(of path: String) -> String {
        files.first { $0.path == path }?.title ?? store.title(store.directory.appendingPathComponent(path))
    }

    func reload() {
        if let outcome = reflector?.lastOutcome, !outcome.skipped { lastError = outcome.error }
        changes = store.recentChanges(limit: 20)
        files = store.files()
        if selected == nil || !files.contains(where: { $0.path == selected }) { select(files.first?.path) }
        else if !hasUnsavedEdit, let selected { load(selected) }
    }

    func select(_ path: String?) {
        selected = path
        message = nil
        if let path { load(path) } else { draft = ""; saved = "" }
    }

    private func load(_ path: String) {
        saved = store.text(store.directory.appendingPathComponent(path))
        draft = saved
    }

    func save() {
        guard let selected else { return }
        // A reflection pass may have written the file since it was opened. Saving the draft would drop what it learned.
        guard store.text(store.directory.appendingPathComponent(selected)) == saved else {
            message = "This file changed while you were editing. Revert to see the new version, then make your edit again."
            return
        }
        switch store.rewrite(store.directory.appendingPathComponent(selected), with: draft, action: .edited, source: MemoryNote.userSource,
                             summary: "Edited \(selected) in Settings") {
        case .success: message = nil
        case .failure(let failure): message = failure.message
        }
        reload()
        load(selected)
    }

    /// Goes back to the file as it is on disk now, which also picks up what a reflection pass wrote meanwhile.
    func revert() {
        message = nil
        if let selected { load(selected) }
    }

    func undo(_ change: MemoryChange) {
        if case .failure(let failure) = store.undo(change) { undoMessage = failure.message } else { undoMessage = nil }
        reload()
        guard let selected, selected == change.file else { return }
        if hasUnsavedEdit { message = "Undo changed this file while you were editing. Revert to see the new version, then make your edit again." } else { load(selected) }
    }

    func search(_ query: String) -> [MemoryIndex.Hit] {
        index?.search(query, limit: 20) ?? []
    }

    func forgetEverything() {
        reflector?.cancelAll()
        store.forgetEverything()
        selected = nil
        reload()
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.directory)
    }
}

/// Settings → Memory.
struct MemorySettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let memory = model.memory {
            MemorySettingsBody(memory: memory)
        } else {
            Form { Text("Memory is not available yet.").foregroundStyle(.secondary) }.formStyle(.grouped)
        }
    }
}

struct MemorySettingsBody: View {
    @ObservedObject var memory: MemorySettingsModel
    @ObservedObject private var store = ConfigStore.shared
    @State private var installedAgents: [ACPAgent] = []
    @State private var query = ""
    @State private var hits: [MemoryIndex.Hit] = []
    @State private var confirmForget = false
    /// Agents are not listed in previews, where no process may start.
    private let listsAgents: Bool

    init(memory: MemorySettingsModel, listsAgents: Bool = true) {
        self.memory = memory
        self.listsAgents = listsAgents
    }

    private var config: Config.Memory { store.config.memory }
    private var petName: String { store.config.pet.name }

    var body: some View {
        ScrollViewReader { scroll in
            Form {
                learningSection
                recentSection(scroll)
                notesSection.id("notes")
                searchSection
                dataSection
            }
            .formStyle(.grouped)
        }
        .task { if listsAgents { installedAgents = await ACPProbe.installed() } }
        .onAppear { memory.reload() }
    }

    // MARK: Learning

    /// The installed agents, plus the saved one so the picker never shows a blank.
    private var agents: [ACPAgent] {
        var list = installedAgents
        if let id = config.reflectAgent, !list.contains(where: { $0.id == id }), let saved = AgentCatalog.agent(id: id) { list.append(saved) }
        return list
    }

    /// The models the agent reported in the chat, plus the saved id, so a model that is not listed still shows.
    private var modelChoices: [ChatModel] {
        var list = config.reflectAgent.flatMap { AgentCatalog.agent(id: $0) }.map(ChatSession.cachedModels(for:)) ?? []
        if let saved = config.reflectModel, !list.contains(where: { $0.id == saved }) { list.append(ChatModel(id: saved, name: saved)) }
        return list
    }

    private var learningSection: some View {
        Section {
            Toggle("Learn from chats", isOn: Binding(get: { config.reflect }, set: { on in store.update { $0.memory.reflect = on } }))
                .help("A chat goes to its own agent, a meeting summary to the summary agent and an automation's answer to the agent that ran it. The agent only answers: no tools, a scratch folder, every permission refused. Summaries and automation answers can teach about people and projects, never about you. Notes with keys or passwords are never saved.")
            Picker("Agent", selection: Binding(get: { config.reflectAgent ?? "" }, set: setAgent)) {
                Text("Same as the chat (recommended)").tag("")
                ForEach(agents) { agent in Text(agent.name).tag(agent.id) }
            }
            .disabled(!config.reflect)
            if let agent = config.reflectAgent {
                Picker("Model", selection: Binding(get: { config.reflectModel ?? "" },
                                                   set: { id in store.update { $0.memory.reflectModel = id.isEmpty ? nil : id } })) {
                    Text(Config.Memory.cheapModels[agent].map { "Cheapest (\($0))" } ?? "Default").tag("")
                    ForEach(modelChoices, id: \.id) { Text($0.name).tag($0.id) }
                }
                .disabled(!config.reflect)
            } else {
                LabeledContent("Model") { Text("Haiku for Claude Code, each agent's default for the others").foregroundStyle(.secondary) }
            }
            Stepper {
                Text("Learn after \(config.quietMinutes) min of quiet")
            } onIncrement: {
                let q = config.quietMinutes
                store.update { $0.memory.quietMinutes = min(Config.Memory.quietRange.upperBound, q < 10 ? q + 1 : q + 5) }
            } onDecrement: {
                let q = config.quietMinutes
                store.update { $0.memory.quietMinutes = max(Config.Memory.quietRange.lowerBound, q > 10 ? max(10, q - 5) : q - 1) }
            }
            .disabled(!config.reflect)
            Toggle("Tidy files that grow too big", isOn: Binding(get: { config.tidy }, set: { on in store.update { $0.memory.tidy = on } }))
                .disabled(!config.reflect)
                .help("Sends the whole file, including notes from chats with other agents and lines you wrote, to this agent to merge and shorten.")
            if config.reflect, let error = memory.lastError {
                Label("The last pass failed: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        } header: {
            Text("Learning")
        } footer: {
Text("When a chat goes quiet, \(petName) sends its new messages to the agent that already had them, which names the facts worth keeping. Each pass uses that agent's quota and shows as Memory in the Usage tab.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "" is Same as the chat. A model id from one agent means nothing to another, so a change clears it.
    private func setAgent(_ agent: String) {
        let picked = agent.isEmpty ? nil : agent
        store.update {
            if $0.memory.reflectAgent != picked { $0.memory.reflectModel = nil }
            $0.memory.reflectAgent = picked
        }
    }

    // MARK: Recently learned

    private func recentSection(_ scroll: ScrollViewProxy) -> some View {
        Section {
            if let message = memory.undoMessage {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if memory.changes.isEmpty {
                Text("Nothing learned yet. Notes show up here as \(petName) saves them, with Undo.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(memory.changes) { change in
                ChangeRow(change: change, file: memory.title(of: change.file), undo: { memory.undo(change) }, edit: {
                    memory.select(change.file)
                    withAnimation { scroll.scrollTo("notes", anchor: .top) }
                })
            }
        } header: {
            Text("Recently learned")
        }
    }

    // MARK: Notes

    private var notesSection: some View {
        Section {
            if memory.files.isEmpty {
                Text("No notes yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("File", selection: Binding(get: { memory.selected ?? "" }, set: { memory.select($0) })) {
                    ForEach(memory.files) { file in
                        Text("\(file.title) (\(file.notes) note\(file.notes == 1 ? "" : "s"))").tag(file.path)
                    }
                }
                TextEditor(text: $memory.draft)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 180, maxHeight: 260)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Notes in \(memory.selected ?? "")")
                HStack {
                    if let message = memory.message {
                        Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Revert", action: memory.revert).disabled(!memory.hasUnsavedEdit)
                    Button("Save", action: memory.save).keyboardShortcut("s", modifiers: .command).disabled(!memory.hasUnsavedEdit)
                }
            }
        } header: {
            Text("Notes")
        } footer: {
            Text("Plain Markdown, one note per line starting with \"- \". The comment at the end of a line holds the day and where the note came from. Saving keeps the previous version in .history.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Search

    private var searchSection: some View {
        Section {
            TextField("Search", text: $query, prompt: Text("Search chats, meetings and notes"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            if !query.trimmingCharacters(in: .whitespaces).isEmpty, hits.isEmpty {
                Text("Nothing found.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                VStack(alignment: .leading, spacing: 2) {
                    Label(hit.title, systemImage: Self.symbol(hit.kind))
                        .font(.callout)
                    Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(hit.at.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Search")
        } footer: {
            Text("The same search \(petName) uses with memory_search, without the screen captures.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            hits = query.trimmingCharacters(in: .whitespaces).isEmpty ? [] : memory.search(query)
        }
    }

    static func symbol(_ kind: MemoryIndex.Kind) -> String {
        switch kind {
        case .chat: return "bubble.left.and.bubble.right"
        case .meeting: return "person.2.wave.2"
        case .note: return "note.text"
        case .history: return "clock.arrow.circlepath"
        }
    }

    // MARK: Data

    private var dataSection: some View {
        Section {
            HStack {
                let notes = memory.files.reduce(0) { $0 + $1.notes }
                Text("\(notes) note\(notes == 1 ? "" : "s") in \(memory.files.count) file\(memory.files.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Folder", action: memory.openFolder)
                Button("Forget Everything…", role: .destructive) { confirmForget = true }
                    .disabled(memory.files.isEmpty && memory.changes.isEmpty)
            }
            .confirmationDialog("Forget everything \(petName) has learned?", isPresented: $confirmForget) {
                Button("Forget Everything", role: .destructive, action: memory.forgetEverything)
            } message: {
                Text("Deletes every note and every earlier version in ~/.ironpet/memory, and their search index. This cannot be undone. Your chats and meetings stay.")
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Everything stays on this Mac, in ~/.ironpet/memory and ironpet.db.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One change in Recently learned: what changed, in which file, from where, and Undo.
private struct ChangeRow: View {
    let change: MemoryChange
    let file: String
    let undo: () -> Void
    let edit: () -> Void

    private var text: String { MemoryNote.parse(change.note)?.text ?? change.note }

    private var symbol: String {
        switch change.action {
        case .added: return "plus.circle"
        case .forgot: return "minus.circle"
        case .replaced: return "arrow.triangle.2.circlepath"
        case .tidied: return "wand.and.stars"
        case .edited: return "pencil"
        }
    }

    private var verb: String {
        switch change.action {
        case .added: return "Learned"
        case .forgot: return "Forgot"
        case .replaced: return "Updated"
        case .tidied: return "Tidied"
        case .edited: return "Edited"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).strikethrough(change.undone).lineLimit(3)
                Text("\(verb) · \(change.section.map { "\(file) · \($0)" } ?? file) · \(Self.origin(change.source)) · "
                     + change.at.formatted(.relative(presentation: .named)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit", action: edit).controlSize(.small)
            Button(change.undone ? "Undone" : "Undo", action: undo).controlSize(.small).disabled(change.undone)
        }
        .accessibilityElement(children: .contain)
    }

    static func origin(_ source: String) -> String {
        if source.hasPrefix("chat:") { return "from a chat" }
        if source.hasPrefix(MemoryMCP.jobCaller) { return "from a background job" }
        if source.hasPrefix("meeting:") { return "from meeting \(source.dropFirst("meeting:".count))" }
        if source.hasPrefix("automation:") { return "from automation \(source.dropFirst("automation:".count))" }
        switch source {
        case MemoryNote.userSource: return "by you"
        case "tidy": return "tidy pass"
        default: return "by an agent"
        }
    }
}
