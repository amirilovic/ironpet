import SwiftUI

/// What the detail panel of a task or suggestion shows. Only fields that have a value appear, so the view never draws an empty label.
struct TaskDetail: Equatable {
    struct Field: Equatable {
        var label: String
        var value: String
    }

    var fields: [Field] = []
    var notes = ""
    var links: [TaskLink] = []
    var labels: [String: String] = [:]
    var history: [TaskEvent] = []

    /// `{"ref": "...", "reason": "..."}` becomes Ref and Reason fields. Other objects list their keys, and plain text stays as it is.
    static func originFields(_ sourceRef: String?) -> [Field] {
        guard let text = sourceRef?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        func rank(_ key: String) -> Int { key == "ref" ? 0 : key == "reason" ? 1 : 2 }
        guard let object = TaskStore.refValue(text) as? [String: Any] else { return [Field(label: "Origin ref", value: text)] }
        let keys = object.keys.sorted { (rank($0), $0) < (rank($1), $1) }
        return keys.compactMap { key in
            let value = (object[key] as? String) ?? "\(object[key] ?? "")"
            guard !value.isEmpty else { return nil }
            return Field(label: key == "ref" ? "Origin ref" : key == "reason" ? "Origin reason" : "Origin \(key)", value: value)
        }
    }

    init(task: TaskItem, history: [TaskEvent], now: Date = Date(), calendar: Calendar = .current) {
        fields.append(Field(label: "Status", value: task.status.title))
        if let waiting = task.waitingLabel { fields.append(Field(label: "Waiting", value: waiting)) }
        if let due = task.dueLabel(now: now, calendar: calendar) { fields.append(Field(label: "Due", value: due)) }
        fields.append(Field(label: "Origin", value: task.source.rawValue))
        fields += Self.originFields(task.sourceRef)
        fields.append(Field(label: "Created", value: Self.time(task.created)))
        fields.append(Field(label: "Updated", value: Self.time(task.updated)))
        if let closed = task.closed { fields.append(Field(label: "Closed", value: Self.time(closed))) }
        notes = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        links = task.links
        labels = task.labels
        self.history = history
    }

    init(suggestion: TaskSuggestion) {
        if let waiting = suggestion.waitingLabel { fields.append(Field(label: "Waiting", value: waiting)) }
        if let due = suggestion.due, !due.isEmpty { fields.append(Field(label: "Due", value: due)) }
        fields.append(Field(label: "Origin", value: suggestion.source.rawValue))
        fields.append(Field(label: "Origin name", value: suggestion.originLabel))
        fields += Self.originFields(suggestion.sourceRef)
        fields.append(Field(label: "Created", value: Self.time(suggestion.created)))
        notes = suggestion.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = suggestion.url { links = [TaskLink(kind: .url, ref: url.absoluteString, label: nil)] }
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
    }
}

/// Everything stored about a task, shown under its row. Notes render as markdown in selectable text, and links open only on a click.
struct TaskDetailView: View {
    let detail: TaskDetail
    let onOpen: (TaskLink) -> Void
    /// Set for a task, nil for a suggestion: adds `key=value` (overwriting the key) and removes a key. Throws a message for an invalid key.
    var onAddLabel: ((String, String) -> String?)? = nil
    var onRemoveLabel: ((String) -> Void)? = nil
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var labelError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 3) {
                    ForEach(Array(detail.fields.enumerated()), id: \.offset) { _, field in
                        GridRow {
                            Text(field.label).foregroundStyle(.secondary)
                            Text(field.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.caption)
                if onAddLabel != nil || !detail.labels.isEmpty { labelsSection }
                if !detail.notes.isEmpty {
                    MarkdownView(text: detail.notes, size: 12)
                }
                if !detail.links.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(detail.links.enumerated()), id: \.offset) { _, link in
                            Button { onOpen(link) } label: {
                                Label(link.label?.nilIfEmptyTrimmed ?? link.ref, systemImage: link.symbol)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .buttonStyle(.link)
                            .help(link.help)
                        }
                    }
                    .font(.caption)
                }
                if !detail.history.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("History").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(detail.history.enumerated()), id: \.offset) { _, event in
                            Text("\(TaskDetail.time(event.at)), \(event.by): \(event.detail)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 260)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension TaskDetailView {
    @ViewBuilder fileprivate var labelsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Labels").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            FlowLabels(labels: detail.labels, onRemove: onRemoveLabel)
            if let onAddLabel {
                HStack(spacing: 4) {
                    TextField("key", text: $newKey).frame(width: 80)
                        .accessibilityLabel("Label key")
                    Text("=").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("value", text: $newValue).frame(width: 100)
                        .accessibilityLabel("Label value")
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newKey.isEmpty || newValue.isEmpty)
                        .accessibilityLabel("Add label")
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                if let labelError { Text(labelError).font(.caption).foregroundStyle(.red) }
            }
        }
        .font(.caption)
    }

    fileprivate func add() {
        guard let onAddLabel else { return }
        labelError = onAddLabel(newKey, newValue)
        if labelError == nil { newKey = ""; newValue = "" }
    }
}

/// The labels of a task as removable chips, in key order.
struct FlowLabels: View {
    let labels: [String: String]
    var onRemove: ((String) -> Void)?

    var body: some View {
        let sorted = labels.sorted { $0.key < $1.key }
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
            ForEach(sorted, id: \.key) { key, value in
                HStack(spacing: 3) {
                    Text("\(key)=\(value)").textSelection(.enabled)
                    if let onRemove {
                        Button { onRemove(key) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove label \(key)")
                            .help("Remove \(key)")
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
        }
        }
    }
}

private extension String {
    var nilIfEmptyTrimmed: String? {
        let text = trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
