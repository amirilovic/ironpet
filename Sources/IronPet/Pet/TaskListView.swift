import AppKit
import SwiftUI

/// The Tasks section of the ironpet window. The agent owns the list; here the user can only mark a task done, delete it,
/// and add or skip suggestions from meetings and watchers. Clicking a row shows everything stored about it.
/// Anything else goes to the chat through "Tell Ghost…".
struct TaskListView: View {
    @ObservedObject var tasks: TaskStore
    let onTellGhost: (String) -> Void
    let onOpenThread: (String) -> Void
    let onOpenSession: (String) -> Void
    /// A task to scroll to and highlight, set by the Today page. Cleared once shown.
    var focus: Binding<String?> = .constant(nil)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDone = false
    @State private var message = ""
    @State private var highlighted: String?
    /// The label the list is filtered by, as `key=value`. Nil shows every task.
    @State private var labelFilter: String?

    enum Content: Equatable { case unavailable, empty, list }

    /// Tasks held in memory stay visible. With none, the unavailable state replaces "No tasks yet", which would be wrong while the real list is out of reach.
    static func content(unavailable: Bool, isEmpty: Bool) -> Content { !isEmpty ? .list : unavailable ? .unavailable : .empty }

    var body: some View {
        VStack(spacing: 0) {
            if let reason = tasks.unavailable {
                DatabaseBanner(reason: reason)
            }
            let content = Self.content(unavailable: tasks.unavailable != nil, isEmpty: tasks.suggestions.isEmpty && open.isEmpty && done.isEmpty)
            if content == .unavailable {
                Spacer()
            } else if content == .empty {
                EmptyState(symbol: "checklist", title: "No tasks yet",
                           detail: "Ask \(petName) to keep track of something, or finish a meeting.")
            } else {
                labelFilterBar
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        suggestions
                        ForEach([TaskStatus.needsYou, .inProgress, .backlog], id: \.self) { status in
                            let items = open.filter { $0.waitingOn == nil && $0.status == status }
                            if !items.isEmpty {
                                SectionTitle(status.title)
                                ForEach(items) { row($0) }
                            }
                        }
                        if !waiting.isEmpty {
                            SectionTitle("Waiting on others")
                            ForEach(waiting) { row($0) }
                        }
                        doneSection
                    }
                    .padding(6)
                }
                .frame(maxHeight: .infinity)
                .onAppear { reveal(focus.wrappedValue, proxy) }
                .onChange(of: focus.wrappedValue) { reveal(focus.wrappedValue, proxy) }
                }
            }
            Divider()
            tellGhost
        }
    }

    private var petName: String { ConfigStore.shared.config.pet.name }

    private var open: [TaskItem] { tasks.ordered.filter { $0.status != .done && matches($0) } }

    private func matches(_ task: TaskItem) -> Bool {
        guard let labelFilter else { return true }
        return task.labels.contains { "\($0.key)=\($0.value)" == labelFilter }
    }

    /// A menu of the labels in use. Picking one shows only tasks with it; the chip clears it.
    @ViewBuilder private var labelFilterBar: some View {
        let labels = tasks.allLabels
        if !labels.isEmpty || labelFilter != nil {
            HStack(spacing: 6) {
                Menu {
                    ForEach(labels.map { "\($0.key)=\($0.value)" }, id: \.self) { label in
                        Button(label) { labelFilter = label }
                    }
                } label: {
                    Label(labelFilter == nil ? "Filter by label" : "Label", systemImage: "tag")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Filter by label")
                if let labelFilter {
                    Button { self.labelFilter = nil } label: {
                        Label(labelFilter, systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    .accessibilityLabel("Clear label filter \(labelFilter)")
                }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    private var waiting: [TaskItem] { open.filter { $0.waitingOn != nil } }

    /// Done tasks stay in the database for `tasks.keepDoneDays`; the list only shows the last week.
    private var done: [TaskItem] {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        return tasks.ordered.filter { $0.status == .done && ($0.closed ?? $0.updated) >= cutoff && matches($0) }
    }

    @ViewBuilder private var suggestions: some View {
        if !tasks.suggestions.isEmpty {
            SectionHeader("Suggestions", action: "Add all", help: "Add every suggested new task. Updates to existing tasks are accepted one by one") { tasks.acceptAll() }
            ForEach(tasks.suggestions) { suggestion in
                SuggestionRow(suggestion: suggestion,
                              onAdd: { _ = try? tasks.accept(suggestion.id) },
                              onSkip: { tasks.skip(suggestion.id) },
                              onOpen: open(_:))
            }
        }
    }

    @ViewBuilder private var doneSection: some View {
        if !done.isEmpty {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { showDone.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("DONE (\(done.count))")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(showDone ? 90 : 0))
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done, \(done.count) \(done.count == 1 ? "task" : "tasks")")
            .accessibilityValue(showDone ? "Expanded" : "Collapsed")
            .help(showDone ? "Hide finished tasks" : "Show tasks finished in the last 7 days")
            if showDone {
                ForEach(done) { row($0) }
            }
        }
    }

    private func row(_ task: TaskItem) -> some View {
        TaskRow(task: task,
                onDone: { _ = try? tasks.close(task.id, by: "user") },
                onDelete: { try? tasks.delete(task.id, by: "user") },
                onOpen: open(_:),
                history: { tasks.history(task.id) },
                onAddLabel: { key, value in
                    do {
                        _ = try tasks.update(task.id, addLabels: try TaskValidator.labels([key: value]), by: "user")
                        return nil
                    } catch { return (error as? TaskError)?.message ?? error.localizedDescription }
                },
                onRemoveLabel: { key in _ = try? tasks.update(task.id, removeLabels: [key], by: "user") })
            .background {
                if highlighted == task.id { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)) }
            }
            .id(task.id)
    }

    /// Scrolls to the task a Today row opened and highlights it for a moment.
    private func reveal(_ id: String?, _ proxy: ScrollViewProxy) {
        guard let id, let task = tasks.task(id) else { return }
        focus.wrappedValue = nil
        if task.status == .done { showDone = true }
        highlighted = id
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if highlighted == id { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { highlighted = nil } }
        }
    }

    private var tellGhost: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Tell \(petName)…", text: $message)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit(send)
                .accessibilityLabel("Tell \(petName) about a task")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .padding(10)
        .help("Tasks are changed through the chat, for example \"move the deploy task to in progress\"")
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        message = ""
        onTellGhost(text)
    }

    private func open(_ link: TaskLink) {
        switch link.kind {
        case .url:
            // Validated on the way in; checked again because the database is a file anyone can edit.
            guard let url = URL(string: link.ref), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        case .file:
            // Reveal rather than open: an agent wrote the path, and opening could launch an app or a script.
            let url = URL(fileURLWithPath: (link.ref as NSString).expandingTildeInPath)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .thread:
            onOpenThread(link.ref)
        case .session:
            onOpenSession(link.ref)
        }
    }
}

// MARK: - Rows

private struct TaskRow: View {
    let task: TaskItem
    let onDone: () -> Void
    let onDelete: () -> Void
    let onOpen: (TaskLink) -> Void
    let history: () -> [TaskEvent]
    let onAddLabel: (String, String) -> String?
    let onRemoveLabel: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var expanded = false
    @State private var events: [TaskEvent] = []
    @FocusState private var focused: Bool

    private static let maxLinkButtons = 3

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CheckButton(done: task.status == .done, title: task.title, action: onDone)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(task.status == .done ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                details
                if expanded {
                    TaskDetailView(detail: TaskDetail(task: task, history: events), onOpen: onOpen,
                                   onAddLabel: onAddLabel, onRemoveLabel: onRemoveLabel)
                        .padding(.top, 4)
                        .onTapGesture {}
                }
            }
            Spacer(minLength: 4)
            if !task.links.isEmpty {
                HStack(spacing: 2) {
                    ForEach(Array(task.links.prefix(Self.maxLinkButtons).enumerated()), id: \.offset) { _, link in
                        IconButton(symbol: link.symbol, help: link.help) { onOpen(link) }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { toggle() }
        .focusable(expanded)
        .focused($focused)
        .focusEffectDisabled()
        .onExitCommand { if expanded { toggle() } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: expanded ? "Hide details" : "Show details", toggle)
        .accessibilityAction(named: "Delete", onDelete)
        .onChange(of: task.updated) { if expanded { events = history() } }
    }

    private func toggle() {
        // Read the history once per open, not on every redraw (hovering redraws the row).
        if !expanded { events = history() }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { expanded.toggle() }
        focused = expanded
    }

    private var details: some View {
        let now = Date()
        let overdue = task.isOverdue(now: now)
        return HStack(spacing: 5) {
            Image(systemName: task.source.symbol)
                .font(.system(size: 10))
                .accessibilityLabel("From \(task.source.rawValue)")
            Text((task.closed ?? task.updated).formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
            if let waiting = task.waitingLabel {
                Text("·").accessibilityHidden(true)
                Label(waiting, systemImage: "person.badge.clock").labelStyle(DueLabelStyle())
            }
            if !task.labels.isEmpty {
                Text("·").accessibilityHidden(true)
                Label(TaskStore.describe(task.labels), systemImage: "tag").labelStyle(DueLabelStyle())
            }
            if let due = task.dueLabel(now: now) {
                Text("·").accessibilityHidden(true)
                Label(due, systemImage: overdue ? "exclamationmark.circle.fill" : "calendar")
                    .labelStyle(DueLabelStyle())
                    .foregroundStyle(overdue ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder private var menu: some View {
        if task.status != .done {
            Button("Mark Done", action: onDone)
        }
        ForEach(Array(task.links.enumerated()), id: \.offset) { _, link in
            Button(link.help) { onOpen(link) }
        }
        Button("Copy Title") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(task.title, forType: .string)
        }
        Divider()
        Button("Delete", role: .destructive, action: onDelete)
    }
}

private struct SuggestionRow: View {
    let suggestion: TaskSuggestion
    let onAdd: () -> Void
    let onSkip: () -> Void
    let onOpen: (TaskLink) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var expanded = false
    @FocusState private var focused: Bool

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { expanded.toggle() }
        focused = expanded
    }

    private var link: TaskLink? {
        suggestion.url.map { TaskLink(kind: .url, ref: $0.absoluteString, label: nil) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Image(systemName: suggestion.source.symbol).font(.system(size: 10)).accessibilityHidden(true)
                    Text("\(suggestion.originLabel), \(suggestion.created.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))")
                    if let waiting = suggestion.waitingLabel {
                        Text("·").accessibilityHidden(true)
                        Label(waiting, systemImage: "person.badge.clock").labelStyle(DueLabelStyle())
                    }
                    if let due = suggestion.due {
                        Text("·").accessibilityHidden(true)
                        Label("Due \(due)", systemImage: "calendar").labelStyle(DueLabelStyle())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                HStack(spacing: 6) {
                    Button("Add", action: onAdd)
                        .help(suggestion.waitingOn == nil ? "Add to the backlog" : "Add to Waiting on others")
                    Button("Skip", action: onSkip)
                        .help("Dismiss this suggestion")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .padding(.top, 3)
                if expanded {
                    TaskDetailView(detail: TaskDetail(suggestion: suggestion), onOpen: onOpen)
                        .padding(.top, 4)
                        .onTapGesture {}
                }
            }
            Spacer(minLength: 4)
            if let link {
                IconButton(symbol: link.symbol, help: link.help) { onOpen(link) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { toggle() }
        .focusable(expanded)
        .focused($focused)
        .focusEffectDisabled()
        .onExitCommand { if expanded { toggle() } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: expanded ? "Hide details" : "Show details", toggle)
    }
}

// MARK: - Pieces

/// The leading circle. Shows a check on hover so it reads as a button before it is clicked.
private struct CheckButton: View {
    let done: Bool
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: done ? "checkmark.circle.fill" : hovering ? "checkmark.circle" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(done ? AnyShapeStyle(AgentStatus.done.tint) : AnyShapeStyle(.secondary))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done)
        .onHover { hovering = $0 }
        .padding(.top, 1)
        .help(done ? "Done" : "Mark done")
        .accessibilityLabel(done ? "Done: \(title)" : "Mark \(title) done")
    }
}

/// Icon and text on one baseline with a tight gap, for the metadata line.
private struct DueLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 10))
            configuration.title
        }
    }
}

extension TaskLink {
    var symbol: String {
        switch kind {
        case .url: return "safari"
        case .file: return "folder"
        case .thread: return "bubble.left.and.bubble.right"
        case .session: return "arrow.up.forward.app"
        }
    }

    /// The tooltip, accessibility label and menu title for the link's button.
    var help: String {
        let name = label?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        switch kind {
        case .url: return "Open \(name ?? URL(string: ref)?.host ?? "link")"
        case .file: return "Show \(name ?? (ref as NSString).lastPathComponent) in Finder"
        case .thread: return "Open \(name ?? "chat thread")"
        case .session: return "Open \(name ?? "agent session")"
        }
    }
}

extension TaskItem {
    func isOverdue(now: Date, calendar: Calendar = .current) -> Bool {
        guard let due, status != .done else { return false }
        return TaskDue.isAllDay(due, calendar: calendar) ? due < calendar.startOfDay(for: now) : due < now
    }

    /// "Due tomorrow", "Due Nov 20 at 15:30", "Overdue since yesterday". Nil without a due date.
    func dueLabel(now: Date, calendar: Calendar = .current) -> String? {
        guard let due else { return nil }
        var dayFormat = Date.FormatStyle.dateTime.month(.abbreviated).day()
        if !calendar.isDate(due, equalTo: now, toGranularity: .year) { dayFormat = dayFormat.year() }
        dayFormat.calendar = calendar
        dayFormat.timeZone = calendar.timeZone
        let today = calendar.startOfDay(for: now)
        let day: String
        switch calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: due)).day {
        case 0: day = "today"
        case 1: day = "tomorrow"
        case -1: day = "yesterday"
        default: day = due.formatted(dayFormat)
        }
        var timeFormat = Date.FormatStyle.dateTime.hour().minute()
        timeFormat.calendar = calendar
        timeFormat.timeZone = calendar.timeZone
        let time = TaskDue.isAllDay(due, calendar: calendar) ? nil : due.formatted(timeFormat)
        if isOverdue(now: now, calendar: calendar) {
            if day == "today", let time { return "Overdue since \(time)" }
            return "Overdue since \(day)" + (time.map { " \($0)" } ?? "")
        }
        return "Due \(day)" + (time.map { " at \($0)" } ?? "")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
