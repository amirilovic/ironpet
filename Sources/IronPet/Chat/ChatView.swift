import AppKit
import SwiftUI

struct ChatView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject private var config = ConfigStore.shared
    let close: () -> Void
    @FocusState private var inputFocused: Bool
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if session.items.isEmpty && session.approvals.isEmpty {
                welcome
            } else {
                transcript
            }
            composer
        }
        .frame(minWidth: ChatPanel.minimumSize.width, maxWidth: .infinity,
               minHeight: ChatPanel.minimumSize.height, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // The panel has a hidden, transparent title bar; without this its 28pt safe area sits empty above the header.
        .ignoresSafeArea(.container, edges: .top)
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
            PetAvatar(size: 30)
            Text(ConfigStore.shared.config.pet.name).font(.system(size: 13, weight: .semibold))
            Spacer()
            autoToggle
            HStack(spacing: 2) {
                settingsButton
                iconButton("xmark", help: "Close (Esc)", action: close)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Project, agent, model and dictation live behind one button, so the header and composer stay clear.
    private var settingsButton: some View {
        Button { showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 13)) }
            .buttonStyle(HoverIconStyle())
            .help("Chat settings")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) { settingsPopover }
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                settingsRow("Project") { projectMenu }
                settingsRow("Agent") { backendMenu }
                settingsRow("Model") { modelMenu }
                settingsRow("Dictation") {
                    Toggle("Send when I stop talking", isOn: $session.sendAfterDictation)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 12))
                }
            }
            .padding(14)
            Hairline()
            HStack(spacing: 8) {
                Button {
                    session.newChat()
                    showSettings = false
                } label: { Label("New chat", systemImage: "square.and.pencil") }
                historyMenu
                Spacer()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        GridRow {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            content()
        }
    }

    private var projectMenu: some View {
        Menu {
            ForEach(session.recents, id: \.self) { url in
                Button(url.lastPathComponent) { session.use(url) }
            }
            Divider()
            Button("No project (general question)", action: session.useNoProject)
            Button("Choose folder…", action: chooseFolder)
        } label: {
            Label(session.needsWorkspace ? "Choose a project" : session.workspaceLabel, systemImage: "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 12))
        .disabled(session.isRunning)
        .help("Folder the agent works in. Switching starts a new chat.")
    }

    /// A pill instead of a switch: reads as a mode, and turns orange so it is obvious the agent runs unattended.
    private var autoToggle: some View {
        Button { session.autoMode.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: session.autoMode ? "bolt.fill" : "bolt")
                Text("Auto")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(session.autoMode ? Color.orange : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(session.autoMode ? Color.orange.opacity(0.16) : Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(session.autoMode ? Color.orange.opacity(0.45) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Auto")
        .accessibilityValue(session.autoMode ? "on" : "off")
        .help("Let the agent edit and run commands without asking (destructive commands still ask)")
        .animation(.easeInOut(duration: 0.15), value: session.autoMode)
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
            Label("Previous chats", systemImage: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Previous chats")
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13)) }
            .buttonStyle(HoverIconStyle())
            .help(help)
    }

    // MARK: Transcript

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            VStack(spacing: 14) {
                PetAvatar(size: 64)
                    .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1.5).padding(-4))
                    .shadow(color: Color.accentColor.opacity(0.25), radius: 14)
                if session.needsWorkspace {
                    projectPicker
                } else {
                    VStack(spacing: 4) {
                        Text("What can I help with?").font(.system(size: 17, weight: .semibold))
                        Text("Working in **\(session.workspaceLabel)** with \(session.backend.displayName)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 12)
            hints.padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    /// Shown when the chat was opened from an app that is not a coding app.
    private var projectPicker: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Which project is this about?").font(.system(size: 17, weight: .semibold))
                Text("Ghost runs the agent in that folder").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                let recents = Array(session.recents.prefix(5))
                ForEach(recents, id: \.self) { url in
                    PickerRow(symbol: "folder.fill", tint: .accentColor, title: url.lastPathComponent,
                              subtitle: url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        session.use(url)
                    }
                    Hairline().padding(.leading, 44)
                }
                PickerRow(symbol: "bubble.left.fill", tint: .purple, title: "No project", subtitle: "General question", action: session.useNoProject)
                Hairline().padding(.leading, 44)
                PickerRow(symbol: "folder.badge.plus", tint: .gray, title: "Choose folder…", subtitle: nil, action: chooseFolder)
            }
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
            .frame(maxWidth: 300)
        }
    }

    private var hints: some View {
        HStack(spacing: 14) {
            hint("mic.fill", keys: ["fn"], "talk")
            hint("macwindow", keys: ["⇧⌥⌘G"], "window")
            hint("crop", keys: ["⌃⌥⌘G"], "region")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    private func hint(_ symbol: String, keys: [String], _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9))
            ForEach(keys, id: \.self) { Keycap(text: $0) }
            Text(text)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(groupedItems, id: \.id) { group in
                        groupView(group).id(group.id)
                    }
                    if session.isRunning, session.approvals.isEmpty {
                        TypingIndicator(started: session.runStartedAt).id("typing")
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
        VStack(alignment: .leading, spacing: 6) {
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
                .padding(.horizontal, 4)
                .padding(.top, 4)
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField(session.isRunning ? "\(ConfigStore.shared.config.pet.name) is working…" : "Ask \(ConfigStore.shared.config.pet.name)…", text: $session.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(1...8)
                    .focused($inputFocused)
                    .onSubmit(session.send)
                    .onChange(of: session.input) { old, new in session.inputChanged(from: old, to: new) }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 5)
                if session.isRunning {
                    sendButton("stop.fill", color: .red, help: "Stop", action: session.stop)
                } else {
                    sendButton("arrow.up", color: .accentColor, help: "Send (Enter)", action: session.send)
                        .disabled(session.input.trimmingCharacters(in: .whitespaces).isEmpty && session.attachments.isEmpty)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(inputFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.1), lineWidth: inputFocused ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { inputFocused = true }
        .animation(.easeOut(duration: 0.12), value: inputFocused)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func sendButton(_ symbol: String, color: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
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
        .font(.system(size: 12))
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
        .font(.system(size: 12))
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
                .background(Color.accentColor, in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 5, topTrailingRadius: 16))
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
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.top, 3)
                if let date {
                    Text(timeFormatter.string(from: date)).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 30)
        }
    }
}

/// A run of consecutive tool steps, folded into one line ("Ran 3 commands, read 2 files ›") that expands on click.
/// While a step is still running, the line shows it with a spinner so you can see progress without expanding.
private struct ToolSteps: View {
    let items: [ChatSession.Item]
    @State private var expanded = false
    @State private var hovering = false

    private var steps: [(id: UUID, summary: String, ok: Bool?)] {
        items.compactMap { item in
            if case .tool(let summary, let ok) = item.kind { return (item.id, summary, ok) }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    headerIcon
                    Text(LocalizedStringKey(headerText)).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(hovering || expanded ? 1 : 0.6)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(hovering ? .primary : .secondary)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(expanded ? "Hide steps" : "Show steps")

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        if index > 0 { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1) }
                        HStack(spacing: 6) {
                            icon(step.ok)
                            Text(LocalizedStringKey(step.summary)).lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 32)
    }

    @ViewBuilder
    private var headerIcon: some View {
        if steps.contains(where: { $0.ok == nil }) {
            icon(nil)
        } else if steps.contains(where: { $0.ok == false }) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        } else {
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        }
    }

    /// The running step while one is in flight, otherwise a count per kind of step.
    private var headerText: String {
        if !expanded, let running = steps.last(where: { $0.ok == nil }) { return running.summary }
        var counts: [(verb: String, noun: String, count: Int)] = []
        for step in steps {
            let (verb, noun) = Self.kind(of: step.summary)
            if let i = counts.firstIndex(where: { $0.verb == verb }) { counts[i].count += 1 } else { counts.append((verb, noun, 1)) }
        }
        let parts = counts.map { "\($0.verb) \($0.count) \($0.noun)\($0.count == 1 ? "" : "s")" }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func kind(of summary: String) -> (String, String) {
        let first = summary.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        switch first {
        case "ran": return ("ran", "command")
        case "read": return ("read", "file")
        case "edited", "wrote", "created": return ("edited", "file")
        case "deleted": return ("deleted", "file")
        case "searched", "grepped", "listed", "found": return ("searched", "time")
        default: return ("used", "tool")
        }
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

/// Shown while the agent works: the pet, animated dots and how long this turn has been running.
private struct TypingIndicator: View {
    let started: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PetAvatar(size: 24)
            TimelineView(.animation(minimumInterval: 0.15)) { context in
                let phase = Int(context.date.timeIntervalSinceReferenceDate * 3) % 3
                // Same layout as a finished reply: the bubble, then the elapsed time where its timestamp goes.
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        ForEach(0..<3) { i in
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 6, height: 6)
                                .opacity(i == phase ? 1 : 0.35)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    if let started {
                        Text(Self.format(context.date.timeIntervalSince(started)))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
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

private struct Hairline: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
}

private struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium, design: .rounded))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
    }
}

private struct HoverIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverIcon(configuration: configuration)
    }

    private struct HoverIcon: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// One row of the project picker: tinted icon tile, title, optional path, chevron, hover highlight.
private struct PickerRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0.5)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
