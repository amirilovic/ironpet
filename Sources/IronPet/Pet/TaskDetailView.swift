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
    var history: [TaskEvent] = []

    /// `{"ref": "...", "reason": "..."}` becomes Ref and Reason fields. Other objects list their keys, and plain text stays as it is.
    static func originFields(_ sourceRef: String?) -> [Field] {
        guard let text = sourceRef?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        func rank(_ key: String) -> Int { key == "ref" ? 0 : key == "reason" ? 1 : 2 }
        guard let object = TaskJSON.refValue(text) as? [String: Any] else { return [Field(label: "Origin ref", value: text)] }
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

private extension String {
    var nilIfEmptyTrimmed: String? {
        let text = trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
