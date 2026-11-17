import AppKit
import SwiftUI

/// The run part of a task row: Start, what the agent is doing, its approval, or how it ended.
struct TaskRunControls: View {
    let task: TaskItem
    @ObservedObject var runner: TaskRunner
    let onOpenThread: (String) -> Void
    @State private var showStart = false
    @State private var error: String?
    @State private var working = false
    @State private var confirmRemove = false

    var body: some View {
        let run = runner.run(for: task.id)
        VStack(alignment: .leading, spacing: 5) {
            switch runner.row(for: task) {
            case .idle(let start):
                if let start { startButton(start) }
            case .running(let activity):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                    Text(activity).lineLimit(1).truncationMode(.middle)
                    AgentTag(run: run)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Agent working: \(activity)")
                actions {
                    Button("Stop") { runner.stop(task: task.id) }.help("Stop the agent. Its copy and branch stay.")
                    openChat(run)
                }
            case .approval(let title, let detail):
                TaskRunApprovalCard(title: title, detail: detail)
                actions {
                    Button("Allow") { decide(run, true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    Button("Deny") { decide(run, false) }
                    openChat(run)
                }
            case .finished(let summary, let canOpenPR, let hint):
                Label(summary ?? "Finished", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AgentStatus.done.tint)
                    .lineLimit(2)
                if let run { BranchLine(run: run) }
                actions {
                    Button("Open PR") { openPR() }
                        .disabled(!canOpenPR || working)
                        .help(hint ?? "Push \(run?.branch ?? "the branch") and open a pull request")
                    openChat(run)
                    removeCopy(run)
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(AgentStatus.failed.tint)
                    .lineLimit(3)
                if let run { BranchLine(run: run) }
                actions {
                    Button("Retry") { retry(run) }.disabled(working).help("Continue in the same copy and session")
                    openChat(run)
                    removeCopy(run)
                }
            case .interrupted:
                Label("ironpet quit while the agent was working", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                actions {
                    Button("Retry") { retry(run) }.disabled(working).help("Continue in the same copy and session")
                    openChat(run)
                    removeCopy(run)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Remove the task's copy?", isPresented: $confirmRemove) {
            Button("Remove Copy", role: .destructive) { remove() }
        } message: {
            Text("The folder \(run?.worktree.path ?? "") and its uncommitted changes are deleted. Committed work stays on \(run?.branch ?? "its branch").")
        }
    }

    private func startButton(_ start: TaskRunRow.StartButton) -> some View {
        Button {
            error = nil
            showStart = true
        } label: {
            Label(runner.run(for: task.id) == nil ? "Start" : "Start Again", systemImage: "play.fill")
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .disabled(!start.enabled)
        .help(start.help)
        .padding(.top, 2)
        .popover(isPresented: $showStart, arrowEdge: .bottom) {
            TaskStartPopover(task: task, runner: runner) { showStart = false }
        }
    }

    private func actions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .padding(.top, 2)
    }

    @ViewBuilder private func openChat(_ run: TaskRun?) -> some View {
        if let session = run?.session {
            Button("Open Chat") { onOpenThread(session) }
                .disabled(run?.state.isLive == true)
                .help(run?.state.isLive == true ? "The chat opens when the agent is done" : "Continue this run's conversation in the chat")
        }
    }

    @ViewBuilder private func removeCopy(_ run: TaskRun?) -> some View {
        if run?.cleanup == .kept {
            Button("Remove Copy…") { confirmRemove = true }
                .help("The task is closed, but its copy has uncommitted changes")
        }
    }

    private func decide(_ run: TaskRun?, _ allow: Bool) {
        guard let id = run?.approval?.id else { return }
        runner.decide(id: id, allow: allow)
    }

    private func retry(_ run: TaskRun?) {
        guard let run, let agent = AgentCatalog.agent(id: run.agent) ?? runner.defaultAgent()?.agent else {
            error = "The agent this task used is not installed."
            return
        }
        perform { await runner.start(task: task.id, project: run.repo, agent: agent, model: run.model, auto: run.auto) }
    }

    private func openPR() { perform { await runner.openPR(task: task.id) } }

    private func remove() { perform { await runner.removeCopy(task: task.id) } }

    private func perform(_ body: @escaping () async -> String?) {
        error = nil
        working = true
        Task {
            error = await body()
            working = false
        }
    }
}

/// The approval a run is waiting on, in the row and the chat strip.
struct TaskRunApprovalCard: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: "hand.raised.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AgentStatus.needsInput.tint)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(AgentStatus.needsInput.tint.opacity(0.1)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Waiting for you: \(title). \(detail)")
    }
}

private struct AgentTag: View {
    let run: TaskRun?

    var body: some View {
        if let run {
            Text(run.auto ? "\(run.agentName) · Auto" : run.agentName)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
    }
}

/// "2 commits on ironpet/fix-login in app", with the uncommitted changes when there are some.
private struct BranchLine: View {
    let run: TaskRun

    var body: some View {
        let commits = run.commits == 1 ? "1 commit" : "\(run.commits) commits"
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).accessibilityHidden(true)
            Text("\(commits) on \(run.branch) in \(run.repo.lastPathComponent)" + (run.dirty ? " · uncommitted changes" : ""))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(run.worktree.path)
    }
}

// MARK: - Start

/// Start: the project, agent and Auto for a new run, and what the agent will be told.
struct TaskStartPopover: View {
    let task: TaskItem
    @ObservedObject var runner: TaskRunner
    let onDone: () -> Void
    @State private var candidates: [URL] = []
    @State private var project: URL?
    @State private var agentID = ""
    @State private var auto = false
    @State private var showPrompt = false
    @State private var starting = false
    @State private var error: String?

    private var continuing: TaskRun? {
        runner.run(for: task.id).flatMap { run in
            run.cleanup != .removed && FileManager.default.fileExists(atPath: run.worktree.path) ? run : nil
        }
    }

    private var agents: [ACPAgent] {
        var list = runner.agents()
        if let fallback = runner.defaultAgent()?.agent, !list.contains(fallback) { list.insert(fallback, at: 0) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hand to an Agent").font(.headline)
                Text(task.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Form {
                if let run = continuing {
                    LabeledContent("Project") {
                        Text("Continues on \(run.branch)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                } else {
                    LabeledContent("Project") {
                        HStack(spacing: 6) {
                            if candidates.isEmpty {
                                Text(project.map(Self.display) ?? "None found").foregroundStyle(.secondary)
                            } else {
                                Picker("Project", selection: $project) {
                                    ForEach(candidates, id: \.self) { Text(Self.display($0)).tag(Optional($0)) }
                                }
                                .labelsHidden()
                            }
                            Button("Choose…", action: choose)
                        }
                    }
                }
                Picker("Agent", selection: $agentID) {
                    ForEach(agents, id: \.id) { Text($0.name).tag($0.id) }
                }
                Toggle(isOn: $auto) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto")
                        Text("Edits and commands in the task's copy run without asking. Destructive commands still ask.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.columns)
            Label(continuing == nil
                  ? "A new branch ironpet/\(task.id) from the current commit, in its own folder. Your working copy is not touched."
                  : "The agent picks up in its copy and session.",
                  systemImage: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("The agent commits on its branch but cannot push. You open the pull request.", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("What the agent is told", isExpanded: $showPrompt) {
                ScrollView {
                    Text(prompt)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
            }
            .font(.caption)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if starting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Start", action: start)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(starting || agentID.isEmpty || (continuing == nil && project == nil))
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear(perform: load)
    }

    private var prompt: String {
        if continuing != nil { return TaskRunPrompt.resume(task: task, lastError: runner.run(for: task.id)?.error) }
        return TaskRunPrompt.start(task: task, repo: project ?? URL(fileURLWithPath: "/your/project"), branch: "ironpet/\(task.id)",
                                   baseBranch: nil)
    }

    /// "web-app — ~/code": the folder first, so a long parent path never hides which project it is.
    private static func display(_ url: URL) -> String {
        "\(url.lastPathComponent) — \((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)"
    }

    private func load() {
        candidates = runner.candidates(for: task)
        project = project ?? candidates.first
        let run = runner.run(for: task.id)
        agentID = run?.agent ?? runner.defaultAgent()?.agent.id ?? agents.first?.id ?? ""
        auto = run?.auto ?? false
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the git project this task is about"
        panel.directoryURL = project
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !candidates.contains(url) { candidates.insert(url, at: 0) }
        project = url
    }

    private func start() {
        guard let agent = agents.first(where: { $0.id == agentID }) else { return }
        let fallback = runner.defaultAgent()
        let model = fallback?.agent.id == agent.id ? fallback?.model : nil
        starting = true
        error = nil
        Task {
            let failure = await runner.start(task: task.id, project: project, agent: agent, model: model, auto: auto)
            starting = false
            if let failure { error = failure } else { onDone() }
        }
    }
}

// MARK: - Agents section and chat

/// Task runs in the Agents section, above the watched sessions.
struct TaskRunAgentRows: View {
    @ObservedObject var runner: TaskRunner
    @ObservedObject var tasks: TaskStore
    let onOpenThread: (String) -> Void
    let onOpenTasks: () -> Void

    var body: some View {
        let shown = runner.shown(in: tasks)
        if !shown.isEmpty {
            SectionTitle("Tasks")
            ForEach(shown, id: \.run.id) { entry in
                TaskRunAgentRow(run: entry.run, task: entry.task, runner: runner, onOpenThread: onOpenThread, onOpenTasks: onOpenTasks)
            }
        }
    }
}

private struct TaskRunAgentRow: View {
    let run: TaskRun
    let task: TaskItem
    let runner: TaskRunner
    let onOpenThread: (String) -> Void
    let onOpenTasks: () -> Void
    @State private var hovering = false

    private var status: AgentStatus {
        switch run.state {
        case .needsApproval: return .needsInput
        case .starting, .running: return .running
        case .finished: return .done
        case .failed, .interrupted: return .failed
        case .stopped: return .idle
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 18, height: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(run.repo.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Tag(text: "Task")
                    Tag(text: run.agentName)
                    Spacer(minLength: 4)
                    if hovering, let session = run.session, !run.state.isLive {
                        IconButton(symbol: "bubble.left.and.bubble.right", help: "Open the run's chat") { onOpenThread(session) }
                    }
                }
                Text(task.title).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85)).lineLimit(2)
                switch run.state {
                case .needsApproval:
                    if let approval = run.approval {
                        TaskRunApprovalCard(title: approval.title, detail: approval.detail)
                        HStack(spacing: 6) {
                            Button("Allow") { runner.decide(id: approval.id, allow: true) }.buttonStyle(.borderedProminent)
                            Button("Deny") { runner.decide(id: approval.id, allow: false) }.buttonStyle(.bordered)
                        }
                        .controlSize(.small)
                    }
                case .starting, .running:
                    Text(run.activity ?? "Working").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                case .finished:
                    Text(run.summary ?? "Finished").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                case .failed, .interrupted:
                    Text(run.error ?? "Stopped").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                case .stopped:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpenTasks)
        .help("Show in Tasks")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task run: \(task.title), \(status.label)")
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .running: ProgressView().controlSize(.small).scaleEffect(0.8)
        case .needsInput: Image(systemName: "hand.raised.fill").foregroundStyle(status.tint).symbolEffect(.pulse)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(status.tint)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(status.tint)
        case .idle: Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

/// On Chat, bubbles are hidden, so a run's approval shows here instead.
struct TaskRunApprovalStrip: View {
    @ObservedObject var runner: TaskRunner
    @ObservedObject var tasks: TaskStore
    let onOpenTasks: () -> Void

    var body: some View {
        let waiting = runner.waiting
        if let run = waiting.first, let approval = run.approval {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Task: \(tasks.task(run.task)?.title ?? run.task)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    TaskRunApprovalCard(title: approval.title, detail: approval.detail)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        Button("Deny") { runner.decide(id: approval.id, allow: false) }
                        Button("Allow") { runner.decide(id: approval.id, allow: true) }.buttonStyle(.borderedProminent)
                    }
                    if waiting.count > 1 {
                        Button("\(waiting.count - 1) more in Tasks", action: onOpenTasks).buttonStyle(.link).font(.caption)
                    }
                }
                .controlSize(.small)
            }
            .padding(10)
            // Opaque: the transcript scrolls under it, and text showing through would be hard to read.
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(AgentStatus.needsInput.tint.opacity(0.4), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .accessibilityElement(children: .contain)
        }
    }
}
