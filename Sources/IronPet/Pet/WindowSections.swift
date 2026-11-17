import AppKit
import SwiftUI

/// The Actions section: tricks Ghost does on request.
struct ActionsSection: View {
    let onTrick: (PetController.Trick) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Make \(ConfigStore.shared.config.pet.name) do something")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(PetController.Trick.allCases, id: \.self) { trick in
                            TrickTile(trick: trick) { onTrick(trick) }
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: .infinity)
        }
        .pageHeader(IronPetSection.actions.title)
    }
}

/// The Agents section: watched sessions, grouped by what they need.
struct AgentsSection: View {
    @ObservedObject var store: SessionStore
    let onJump: (AgentSession) -> Void
    /// Task runs listed above the watched sessions. Nil lists none.
    var runs: TaskRunner? = nil
    var tasks: TaskStore? = nil
    var onOpenThread: (String) -> Void = { _ in }
    var onOpenTasks: () -> Void = {}

    private var hasRuns: Bool {
        guard let runs, let tasks else { return false }
        return !runs.shown(in: tasks).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            agents
        }
        .pageHeader(IronPetSection.agents.title) {
            HStack(spacing: 4) {
                ForEach([AgentStatus.needsInput, .running, .failed, .done], id: \.self) { status in
                    let count = store.ordered.filter { $0.status == status }.count
                    if count > 0 { CountChip(count: count, color: status.tint) }
                }
            }
        }
    }

    private var sections: [(title: String, sessions: [AgentSession])] {
        let all = store.ordered
        return [
            ("Needs you", all.filter { $0.status == .needsInput }),
            ("Working", all.filter { $0.status == .running }),
            ("Finished", all.filter { $0.status == .done || $0.status == .failed }),
        ].filter { !$0.sessions.isEmpty }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.ordered.isEmpty, !hasRuns {
                EmptyState(symbol: "moon.zzz", title: "No agents running",
                           detail: "Cursor and Claude Code sessions show up here.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if let runs, let tasks {
                            TaskRunAgentRows(runner: runs, tasks: tasks, onOpenThread: onOpenThread, onOpenTasks: onOpenTasks)
                        }
                        ForEach(sections, id: \.title) { section in
                            if section.title == "Finished" {
                                SectionHeader(section.title, action: "Clear finished") { store.acknowledgeAll() }
                            } else {
                                SectionTitle(section.title)
                            }
                            ForEach(section.sessions) { session in
                                SessionRow(session: session,
                                           onJump: { onJump(session) },
                                           onDismiss: { store.acknowledge(session.id) })
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// The Alerts section: what automations reported, newest first.
struct AlertsSection: View {
    @ObservedObject var signals: SignalStore
    let onAsk: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            alerts
        }
        .pageHeader(IronPetSection.alerts.title) {
            if !signals.signals.isEmpty {
                Button("Clear all") { signals.dismissAll() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder private var alerts: some View {
        if signals.signals.isEmpty {
            EmptyState(symbol: "bell.slash", title: "No alerts",
                       detail: "Alerts from your automations show up here, such as CI, reviews and errors.")
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(signals.signals) { signal in
                        SignalRow(signal: signal,
                                  onOpen: {
                                      if let url = signal.url { NSWorkspace.shared.open(url) }
                                      signals.dismiss(signal.id)
                                  },
                                  onAsk: signal.ask.map { prompt in { onAsk(prompt) } },
                                  onDismiss: { signals.dismiss(signal.id) })
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct TrickTile: View {
    let trick: PetController.Trick
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: trick.symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 26)
                Text(trick.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.1 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(hovering ? 0.12 : 0.06), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Rows

private struct SessionRow: View {
    let session: AgentSession
    let onJump: () -> Void
    let onDismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusIcon(status: session.status)
                .frame(width: 18, height: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.workspaceName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    SourceTag(source: session.source)
                    Spacer(minLength: 4)
                    if hovering {
                        actions
                    } else {
                        Elapsed(session: session)
                    }
                }
                if let prompt = session.prompt {
                    Text(prompt)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(2)
                }
                if let summary = session.summary, session.status == .done || session.status == .failed {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let detail = session.detail, session.status == .needsInput || session.status == .running {
                    ActivityLabel(detail: detail, status: session.status)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onJump)
        .help(Editors.label(for: session))
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if session.status == .done || session.status == .failed {
                IconButton(symbol: "xmark", help: "Dismiss", action: onDismiss)
            }
            IconButton(symbol: "arrow.up.forward.app", help: Editors.label(for: session),
                       action: onJump)
        }
    }
}

private struct SignalRow: View {
    let signal: Signal
    let onOpen: () -> Void
    let onAsk: (() -> Void)?
    let onDismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: signal.symbol)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(signal.label).font(.caption.weight(.semibold)).foregroundStyle(color)
                    Spacer(minLength: 4)
                    if hovering {
                        IconButton(symbol: "xmark", help: "Dismiss", action: onDismiss)
                    } else {
                        Text(signal.date, style: .relative)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(signal.title).font(.system(size: 12.5, weight: .medium)).lineLimit(2)
                Text(signal.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if signal.url != nil { Button("Open", action: onOpen) }
                    if let onAsk {
                        Button(action: onAsk) { Label("Ask \(ConfigStore.shared.config.pet.name)", systemImage: "sparkles") }
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var color: Color {
        switch signal.mood {
        case .failed: return .red
        case .needsInput: return .orange
        default: return .green
        }
    }
}

// MARK: - Pieces

private struct StatusIcon: View {
    let status: AgentStatus

    var body: some View {
        switch status {
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.8)
        case .needsInput:
            Image(systemName: "hand.raised.fill").foregroundStyle(status.tint).symbolEffect(.pulse)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(status.tint)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(status.tint)
        case .idle:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}

private struct SourceTag: View {
    let source: AgentSource

    var body: some View {
        Text(source.displayName)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

/// Live time for running turns, "ago" for everything else.
private struct Elapsed: View {
    let session: AgentSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let running = session.status == .running || session.status == .needsInput
            let since = running ? session.turnStartedAt : session.updatedAt
            Text(Self.format(context.date.timeIntervalSince(since)) + (running ? "" : " ago"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(running ? session.status.tint : Color.secondary)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

/// The tool the agent is using right now, or what it is waiting on.
private struct ActivityLabel: View {
    let detail: String
    let status: AgentStatus

    var body: some View {
        Label {
            Text(detail).lineLimit(2)
        } icon: {
            Image(systemName: status == .needsInput ? "questionmark.bubble" : Self.symbol(for: detail))
        }
        .font(.caption)
        .foregroundStyle(status == .needsInput ? AnyShapeStyle(status.tint) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
    }

    static func symbol(for tool: String) -> String {
        let name = tool.lowercased()
        if name.hasPrefix("mcp") { return "puzzlepiece.extension" }
        if ["shell", "bash", "terminal"].contains(where: name.contains) { return "terminal" }
        if ["edit", "write", "replace", "delete", "notebook"].contains(where: name.contains) { return "pencil" }
        if ["read", "view"].contains(where: name.contains) { return "doc.text" }
        if ["grep", "glob", "search", "find", "ls"].contains(where: name.contains) { return "magnifyingglass" }
        if ["web", "fetch"].contains(where: name.contains) { return "globe" }
        if ["task", "agent"].contains(where: name.contains) { return "person.2" }
        if name.contains("todo") { return "checklist" }
        return "gearshape"
    }
}

private struct CountChip: View {
    let count: Int
    let color: Color

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

/// A section title with one action for the whole section, such as Clear finished or Add all.
struct SectionHeader: View {
    let title: String
    let action: String
    let help: String?
    let perform: () -> Void

    init(_ title: String, action: String, help: String? = nil, perform: @escaping () -> Void) {
        self.title = title
        self.action = action
        self.help = help
        self.perform = perform
    }

    var body: some View {
        HStack {
            SectionTitle(title)
            Spacer()
            Button(action, action: perform)
                .buttonStyle(.borderless)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .help(help ?? action)
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 12.5, weight: .medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension AgentStatus {
    var symbol: String {
        switch self {
        case .needsInput: return "hand.raised.fill"
        case .failed: return "xmark.octagon.fill"
        case .done: return "checkmark.circle.fill"
        case .running: return "circle.dotted"
        case .idle: return "circle"
        }
    }

    var tint: Color {
        switch self {
        case .needsInput: return .orange
        case .failed: return .red
        case .done: return .green
        case .running: return .accentColor
        case .idle: return .secondary
        }
    }
}
