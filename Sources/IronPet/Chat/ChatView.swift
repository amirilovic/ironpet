import AppKit
import SwiftUI

struct ChatView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject private var config = ConfigStore.shared
    let close: () -> Void
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if session.items.isEmpty && session.approvals.isEmpty {
                welcome
            } else {
                transcript
            }
            StatusBar(session: session)
            Divider()
            composer
        }
        .frame(minWidth: ChatPanel.minimumSize.width, maxWidth: .infinity,
               minHeight: ChatPanel.minimumSize.height, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { inputFocused = true }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, ImageIntake.isImageFile(url) else { return }
                    let saved = ImageIntake.save([url])
                    DispatchQueue.main.async { saved.forEach(session.attach) }
                }
            }
            return true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            PetAvatar(size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(ConfigStore.shared.config.pet.name).font(.system(size: 13, weight: .semibold))
                Menu {
                    ForEach(session.recents, id: \.self) { url in
                        Button(url.lastPathComponent) { session.use(url) }
                    }
                    Divider()
                    Button("No project (general question)", action: session.useNoProject)
                    Button("Choose folder…", action: chooseFolder)
                } label: {
                    Label(session.needsWorkspace ? "Choose a project" : session.workspaceLabel, systemImage: "folder")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $session.autoMode) {
                Text("Auto").font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Let the agent edit and run commands without asking (destructive commands still ask)")
            historyMenu
            iconButton("square.and.pencil", help: "New chat", action: session.newChat)
            iconButton("xmark", help: "Close (Esc)", action: close)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var historyMenu: some View {
        Menu {
            if session.history.isEmpty { Text("No previous chats") }
            ForEach(session.history) { thread in
                Button("\(thread.title) — \(URL(fileURLWithPath: thread.workspace).lastPathComponent)") {
                    session.open(thread)
                }
            }
            Divider()
            Button("Open memory folder") { NSWorkspace.shared.open(Memory.directory) }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Previous chats")
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13)) }
            .buttonStyle(.borderless)
            .help(help)
    }

    // MARK: Transcript

    private var welcome: some View {
        VStack(spacing: 8) {
            PetAvatar(size: 56)
            if session.needsWorkspace {
                projectPicker
            } else {
                Text("What can I help with?").font(.system(size: 15, weight: .semibold))
                Text("Working in **\(session.workspaceLabel)** with \(session.backend.displayName)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                hint("mic", "Hold fn to talk with Wispr Flow")
                hint("macwindow", "⇧⌥⌘G  ask about the front window")
                hint("crop", "⌃⌥⌘G  ask about a screen region")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 20)
    }

    /// Shown when the chat was opened from an app that is not a coding app.
    private var projectPicker: some View {
        VStack(spacing: 8) {
            Text("Which project is this about?").font(.system(size: 15, weight: .semibold))
            VStack(spacing: 4) {
                ForEach(session.recents.prefix(5), id: \.self) { url in
                    Button { session.use(url) } label: {
                        Label(url.lastPathComponent, systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Button(action: session.useNoProject) {
                    Label("No project (general question)", systemImage: "bubble.left").frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(action: chooseFolder) {
                    Label("Choose folder…", systemImage: "folder.badge.plus").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .frame(width: 260)
        }
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(groupedItems, id: \.id) { group in
                        groupView(group).id(group.id)
                    }
                    if session.isRunning, session.approvals.isEmpty, !lastIsAssistant {
                        TypingIndicator().id("typing")
                    }
                    ForEach(session.approvals) { approval in approvalCard(approval).id(approval.id) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: scrollKey) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var scrollKey: String {
        "\(session.items.count)-\(session.approvals.count)-\(session.isRunning)-\(lastAssistantLength)"
    }

    private var lastIsAssistant: Bool {
        if case .assistant = session.items.last?.kind { return true }
        return false
    }

    private var lastAssistantLength: Int {
        if case .assistant(let text) = session.items.last?.kind { return text.count }
        return 0
    }

    /// Consecutive tool steps are shown together as one activity block.
    private enum Group {
        case item(ChatSession.Item)
        case tools([ChatSession.Item])

        var id: UUID {
            switch self {
            case .item(let item): return item.id
            case .tools(let items): return items[0].id
            }
        }
    }

    private var groupedItems: [Group] {
        var groups: [Group] = []
        for item in session.items {
            if case .tool = item.kind {
                if case .tools(let existing) = groups.last {
                    groups[groups.count - 1] = .tools(existing + [item])
                } else {
                    groups.append(.tools([item]))
                }
            } else {
                groups.append(.item(item))
            }
        }
        return groups
    }

    @ViewBuilder
    private func groupView(_ group: Group) -> some View {
        switch group {
        case .tools(let items):
            ToolSteps(items: items)
        case .item(let item):
            switch item.kind {
            case .user(let text):
                UserBubble(text: text, date: item.date)
            case .screenshot(let path):
                HStack {
                    Spacer(minLength: 60)
                    Thumbnail(path: path, height: 110)
                }
            case .assistant(let text):
                AssistantBubble(text: text, date: item.date)
            case .tool:
                EmptyView()
            case .error(let text):
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func approvalCard(_ approval: ChatSession.Approval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(approval.title, systemImage: "hand.raised.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            if !approval.detail.isEmpty {
                Text(approval.detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(10)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button { session.decide(approval, allow: true) } label: {
                    Label("Allow", systemImage: "checkmark").frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                Button { session.decide(approval, allow: false) } label: {
                    Label("Deny", systemImage: "xmark").frame(minWidth: 70)
                }
                .buttonStyle(.bordered)
                Spacer()
                Text("⌘↩ to allow").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.5)))
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(session.attachments, id: \.self) { url in
                        Thumbnail(path: url.path, height: 48)
                            .overlay(alignment: .topTrailing) {
                                Button { session.attachments.removeAll { $0 == url } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .padding(2)
                            }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(session.isRunning ? "\(ConfigStore.shared.config.pet.name) is working…" : "Ask \(ConfigStore.shared.config.pet.name)…  (hold fn to talk)", text: $session.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit(session.send)
                    .onChange(of: session.input) { old, new in session.inputChanged(from: old, to: new) }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                if session.isRunning {
                    sendButton("stop.fill", color: .red, help: "Stop", action: session.stop)
                } else {
                    sendButton("arrow.up", color: .accentColor, help: "Send (Enter)", action: session.send)
                        .disabled(session.input.trimmingCharacters(in: .whitespaces).isEmpty && session.attachments.isEmpty)
                }
            }
            HStack(spacing: 10) {
                backendMenu
                modelMenu
                Spacer()
                Toggle("Send after dictation", isOn: $session.sendAfterDictation)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func sendButton(_ symbol: String, color: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var backendMenu: some View {
        Menu {
            ForEach(BackendKind.allCases, id: \.self) { kind in
                Button { session.setBackend(kind) } label: {
                    if session.backend == kind { Label(kind.displayName, systemImage: "checkmark") } else { Text(kind.displayName) }
                }
            }
        } label: {
            Label(session.backend.displayName, systemImage: "terminal")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .disabled(session.isRunning)
        .help("Agent that runs your request. Switching starts a new chat.")
    }

    private var modelMenu: some View {
        let families = session.models.reduce(into: [(String, [ChatModel])]()) { groups, model in
            if let index = groups.firstIndex(where: { $0.0 == model.family }) {
                groups[index].1.append(model)
            } else {
                groups.append((model.family, [model]))
            }
        }
        return Menu {
            Button {
                session.model = nil
            } label: {
                if session.model == nil { Label("Default (CLI setting)", systemImage: "checkmark") } else { Text("Default (CLI setting)") }
            }
            Divider()
            ForEach(families, id: \.0) { family, models in
                if models.count == 1, let only = models.first {
                    modelButton(only)
                } else {
                    Menu(family) { ForEach(models) { modelButton($0) } }
                }
            }
        } label: {
            Label(session.modelName, systemImage: "cpu")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .disabled(session.isRunning)
        .help("Model used for the next message")
    }

    @ViewBuilder
    private func modelButton(_ model: ChatModel) -> some View {
        Button {
            session.model = model.id
        } label: {
            if session.model == model.id { Label(model.name, systemImage: "checkmark") } else { Text(model.name) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = session.workspace
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { session.use(url) }
    }
}

// MARK: - Pieces

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    return f
}()

private struct UserBubble: View {
    let text: String
    let date: Date?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            if let date {
                Text(timeFormatter.string(from: date)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 50)
    }
}

private struct AssistantBubble: View {
    let text: String
    let date: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PetAvatar(size: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(text))
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                if let date {
                    Text(timeFormatter.string(from: date)).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 30)
        }
    }
}

private struct ToolSteps: View {
    let items: [ChatSession.Item]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                if case .tool(let summary, let ok) = item.kind {
                    HStack(spacing: 6) {
                        icon(ok)
                        Text(LocalizedStringKey(summary)).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .padding(.leading, 32)
    }

    @ViewBuilder
    private func icon(_ ok: Bool?) -> some View {
        switch ok {
        case nil: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case false?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

private struct TypingIndicator: View {
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            PetAvatar(size: 24)
            TimelineView(.animation(minimumInterval: 0.15)) { context in
                let phase = Int(context.date.timeIntervalSinceReferenceDate * 3) % 3
                HStack(spacing: 4) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 6, height: 6)
                            .opacity(i == phase ? 1 : 0.35)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

/// Always-visible line above the input: what Ghost is doing, waiting on, or how the last turn went.
private struct StatusBar: View {
    @ObservedObject var session: ChatSession

    var body: some View {
        Group {
            if !session.approvals.isEmpty {
                row(color: .orange) {
                    Image(systemName: "hand.raised.fill")
                    Text("Waiting for your approval")
                }
            } else if session.isRunning, let started = session.runStartedAt {
                row(color: .accentColor) {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                    Text(LocalizedStringKey((session.activity ?? "Thinking") + "…")).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Self.format(context.date.timeIntervalSince(started))).monospacedDigit()
                    }
                    if session.autoMode { Text("AUTO").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4)
                        .background(Color.accentColor.opacity(0.2), in: Capsule()) }
                }
            } else if session.state == .done {
                row(color: .green) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Done" + (session.lastRunDuration.map { " in \(Self.format($0))" } ?? ""))
                }
            } else if session.state == .failed {
                row(color: .red) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text("Failed" + (session.lastRunDuration.map { " after \(Self.format($0))" } ?? ""))
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: session.state)
    }

    private func row<Content: View>(color: Color, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1))
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

struct Thumbnail: View {
    let path: String
    let height: CGFloat

    var body: some View {
        if let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
                .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                .help("Open screenshot")
        } else {
            Label("Screenshot", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The pet's first idle frame, cropped to the face, used as the chat avatar.
struct PetAvatar: View {
    let size: CGFloat
    @ObservedObject private var config = ConfigStore.shared
    @MainActor private static var cache: (sprite: String?, image: NSImage?)?

    @MainActor private static func image(sprite: String?) -> NSImage? {
        if let cache, cache.sprite == sprite { return cache.image }
        var image: NSImage?
        if let frame = Atlas.loadDefault(sprite: sprite)?.rows.first?.first,
           let face = frame.cropping(to: CGRect(x: 34, y: 36, width: 124, height: 112)) {
            image = NSImage(cgImage: face, size: NSSize(width: 124, height: 112))
        }
        cache = (sprite, image)
        return image
    }

    var body: some View {
        Group {
            if let image = Self.image(sprite: config.config.pet.sprite) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "pawprint.fill").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color.primary.opacity(0.06), in: Circle())
        .clipShape(Circle())
    }
}
