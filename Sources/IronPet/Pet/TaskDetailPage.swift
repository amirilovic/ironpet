import AppKit
import SwiftUI

/// A task in full: large title, status, due date and waiting-on controls, notes as markdown, links, labels and, collapsed, the origin and history.
struct TaskDetailPage: View {
    @ObservedObject var tasks: TaskStore
    let id: String
    let onBack: () -> Void
    let onOpen: (TaskLink) -> Void

    @State private var title = ""
    @State private var waiting = ""
    @State private var editingNotes = false
    @State private var draft = ""
    @State private var confirmingDone = false
    @State private var closingNote = ""
    @State private var showDetails = false
    @State private var events: [TaskEvent] = []
    @State private var error: String?
    @FocusState private var titleFocused: Bool
    @FocusState private var waitingFocused: Bool

    private static let readingWidth: CGFloat = 680

    var body: some View {
        if let task = tasks.task(id) {
            VStack(spacing: 0) {
                backBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(task)
                        if confirmingDone { doneCard }
                        if let error { Text(error).font(.callout).foregroundStyle(.red) }
                        notes(task)
                        if !task.links.isEmpty { links(task) }
                        labels(task)
                        details(task)
                    }
                    .frame(maxWidth: Self.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            }
            .onAppear { sync(task) }
            .onChange(of: task.title) { if !titleFocused { title = task.title } }
            .onChange(of: task.waitingOn) { if !waitingFocused { waiting = task.waitingOn ?? "" } }
            .onChange(of: task.updated) { if showDetails { events = tasks.history(id) } }
            .onExitCommand(perform: goBack)
        } else {
            // The task was deleted while it was open.
            Color.clear.onAppear(perform: onBack)
        }
    }

    private func sync(_ task: TaskItem) {
        title = task.title
        waiting = task.waitingOn ?? ""
    }

    /// Esc while editing the notes leaves the editor first, so a draft is not lost by accident.
    private func goBack() {
        if editingNotes { editingNotes = false } else { onBack() }
    }

    private var backBar: some View {
        HStack {
            Button(action: goBack) { Label("Tasks", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Back to the task list")
                .help("Back to the list (Esc)")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: Header

    private func header(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .bold))
                .focused($titleFocused)
                .onSubmit { commitTitle(task) }
                .onChange(of: titleFocused) { if !titleFocused { commitTitle(task) } }
                .accessibilityLabel("Task title")
            HStack(spacing: 14) {
                statusPicker(task)
                DuePicker(due: task.due, disabled: task.status == .done) { new in attempt { _ = try TaskEdits.setDue(new, of: id, in: tasks) } }
                HStack(spacing: 4) {
                    Image(systemName: "person.badge.clock").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Waiting on", text: $waiting)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                        .focused($waitingFocused)
                        .onSubmit { commitWaiting(task) }
                        .onChange(of: waitingFocused) { if !waitingFocused { commitWaiting(task) } }
                        .accessibilityLabel("Waiting on")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
        }
    }

    private func statusPicker(_ task: TaskItem) -> some View {
        Picker("Status", selection: Binding(get: { task.status }, set: { changeStatus(to: $0, task) })) {
            ForEach(TaskStatus.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("Status")
    }

    private func changeStatus(to status: TaskStatus, _ task: TaskItem) {
        guard status != task.status else { return }
        if status == .done {
            closingNote = ""
            confirmingDone = true
        } else {
            confirmingDone = false
            attempt { _ = try TaskEdits.setStatus(status, of: id, in: tasks) }
        }
    }

    private var doneCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What shows it is done?").font(.system(size: 13, weight: .semibold))
            TextField("Closing note (optional)", text: $closingNote, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(finishDone)
            HStack {
                Button("Mark done", action: finishDone).keyboardShortcut(.defaultAction)
                Button("Cancel") { confirmingDone = false }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    private func finishDone() {
        confirmingDone = false
        attempt { _ = try TaskEdits.setStatus(.done, of: id, in: tasks, note: closingNote) }
    }

    private func commitTitle(_ task: TaskItem) {
        guard title != task.title else { return }
        attempt({ _ = try TaskEdits.setTitle(title, of: id, in: tasks) }, onFail: { title = task.title })
    }

    private func commitWaiting(_ task: TaskItem) {
        guard waiting.trimmingCharacters(in: .whitespacesAndNewlines) != (task.waitingOn ?? "") else { return }
        attempt({ _ = try TaskEdits.setWaitingOn(waiting, of: id, in: tasks) }, onFail: { waiting = task.waitingOn ?? "" })
    }

    private func attempt(_ work: () throws -> Void, onFail: () -> Void = {}) {
        do { try work(); error = nil } catch {
            self.error = (error as? TaskError)?.message ?? error.localizedDescription
            onFail()
        }
    }

    // MARK: Notes

    @ViewBuilder private func notes(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notes").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if editingNotes {
                    Button("Cancel") { editingNotes = false }
                    Button("Save") { saveNotes() }.keyboardShortcut("s", modifiers: .command).buttonStyle(.borderedProminent)
                } else {
                    Button(task.notes.isEmpty ? "Add notes" : "Edit") { draft = task.notes; editingNotes = true }
                }
            }
            .controlSize(.small)
            if editingNotes {
                TextEditor(text: $draft)
                    .font(.system(size: 14, design: .monospaced))
                    .frame(minHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    .accessibilityLabel("Notes as markdown")
                Text("Markdown. \(draft.utf8.count) of \(TaskValidator.maxNotes) bytes.")
                    .font(.caption).foregroundStyle(draft.utf8.count > TaskValidator.maxNotes ? .red : .secondary)
            } else if task.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No notes.").font(.system(size: 14)).foregroundStyle(.secondary)
            } else {
                MarkdownView(text: task.notes.trimmingCharacters(in: .whitespacesAndNewlines), size: 14)
            }
        }
    }

    private func saveNotes() {
        let before = tasks.task(id)?.notes
        attempt { _ = try TaskEdits.setNotes(draft, of: id, in: tasks) }
        if error == nil || tasks.task(id)?.notes != before { editingNotes = error != nil }
    }

    // MARK: Links

    private func links(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Links").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(task.links.map(TaskLinkRow.init).enumerated()), id: \.offset) { _, row in
                Button { onOpen(row.link) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: row.symbol).frame(width: 18).foregroundStyle(.secondary)
                        Text(row.title).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 14))
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(row.link.help)
                .accessibilityLabel(row.link.help)
            }
        }
    }

    // MARK: Labels

    private func labels(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Labels").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            ChipFlow(spacing: 6) {
                ForEach(task.labels.sorted { $0.key < $1.key }, id: \.key) { key, value in
                    HStack(spacing: 4) {
                        Text("\(key)=\(value)").textSelection(.enabled)
                        Button { attempt { _ = try tasks.update(id, removeLabels: [key], by: "user") } } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove label \(key)")
                            .help("Remove \(key)")
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                AddLabelButton(others: tasks.tasks.filter { $0.id != id }.map(\.labels), own: task.labels) { key, value in
                    TaskLabelEditing.add(key: key, value: value, to: id, in: tasks)
                }
            }
        }
    }

    // MARK: Footer

    private func details(_ task: TaskItem) -> some View {
        DisclosureGroup(isExpanded: $showDetails) {
            let detail = TaskDetail(task: task, history: events)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(detail.fields.filter { !["Status", "Waiting", "Due"].contains($0.label) }.enumerated()), id: \.offset) { _, field in
                    HStack(alignment: .top, spacing: 8) {
                        Text(field.label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        Text(field.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !events.isEmpty {
                    Text("History").fontWeight(.semibold).padding(.top, 6)
                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                        Text("\(TaskDetail.time(event.at)), \(event.by): \(event.detail)")
                            .foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.caption)
            .padding(.top, 6)
        } label: {
            Text("Details").font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: showDetails) { if showDetails { events = tasks.history(id) } }
    }
}

// MARK: - Pieces

/// The due date: a button to set one, then a date picker (with an optional time) and a clear button.
private struct DuePicker: View {
    let due: Date?
    let disabled: Bool
    let onChange: (Date?) -> Void

    private var hasTime: Bool { due.map { !TaskDue.isAllDay($0, calendar: .current) } ?? false }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar").foregroundStyle(.secondary).accessibilityHidden(true)
            if let due {
                DatePicker("Due", selection: Binding(get: { due }, set: { onChange($0) }),
                           displayedComponents: hasTime ? [.date, .hourAndMinute] : .date)
                    .labelsHidden()
                    .accessibilityLabel("Due date")
                Button(hasTime ? "Date only" : "Add time") {
                    onChange(hasTime ? Calendar.current.startOfDay(for: due)
                                     : Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: due))
                }
                .buttonStyle(.borderless)
                Button { onChange(nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear due date")
            } else {
                Button("Set due date") {
                    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
                    onChange(tomorrow)
                }
                .disabled(disabled)
            }
        }
    }
}

/// "+ Label" and its popover: a key field, a value field, suggestions for both, and the validation message.
private struct AddLabelButton: View {
    let others: [[String: String]]
    let own: [String: String]
    /// Returns nil when added, or the message to show.
    let onAdd: (String, String) -> String?
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: { Label("Label", systemImage: "plus").font(.system(size: 12)) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Add label")
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                LabelPopover(others: others, own: own, onAdd: onAdd) { shown = false }
            }
    }
}

struct LabelPopover: View {
    let others: [[String: String]]
    let own: [String: String]
    let onAdd: (String, String) -> String?
    let onDone: () -> Void
    @State private var key = ""
    @State private var value = ""
    @State private var error: String?
    @FocusState private var field: Field?
    private enum Field { case key, value }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add label").font(.headline)
            TextField("key", text: $key)
                .focused($field, equals: .key)
                .onSubmit { field = .value }
                .accessibilityLabel("Label key")
            if field == .key || value.isEmpty {
                suggestions(TaskLabelEditing.keySuggestions(for: key, others: others, own: own)) { key = $0; field = .value }
            }
            TextField("value", text: $value)
                .focused($field, equals: .value)
                .onSubmit(add)
                .accessibilityLabel("Label value")
            if field == .value {
                suggestions(TaskLabelEditing.valueSuggestions(for: value, key: key.trimmingCharacters(in: .whitespaces), others: others)) {
                    value = $0
                    add()
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                Button("Add", action: add).keyboardShortcut(.defaultAction).disabled(key.isEmpty || value.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(12)
        .frame(width: 260)
        .onAppear { field = .key }
        .onChange(of: key) { error = nil }
    }

    @ViewBuilder private func suggestions(_ items: [String], pick: @escaping (String) -> Void) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items.prefix(5), id: \.self) { item in
                    Button { pick(item) } label: {
                        Text(item).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).padding(.horizontal, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
    }

    private func add() {
        error = onAdd(key, value)
        if error == nil { onDone() }
    }
}

/// Lays children left to right and wraps to a new line when the width runs out.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (origins, CGSize(width: maxX, height: y + rowHeight))
    }
}
