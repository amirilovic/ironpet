import SwiftUI

/// The card for a form the agent is waiting on. It looks like the approval card.
struct ElicitationCard: View {
    @ObservedObject var session: ChatAPI
    let pending: ChatPendingForm
    @State private var pager: ElicitationPager?

    private var current: ElicitationPager { pager ?? ElicitationPager(pageCount: pending.form.pages.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(pending.form.message.isEmpty ? "The agent has a question" : pending.form.message, systemImage: "questionmark.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            let pages = pending.form.pages
            let page = current
            ForEach(page.isPaged ? pages[min(page.index, pages.count - 1)] : pending.form.fields) { field in
                fieldView(field)
            }
            HStack {
                if page.isPaged {
                    Button { move { $0.back() } } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.bordered)
                        .disabled(!page.canGoBack)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .help("Previous question")
                        .pointerCursor()
                    Text(page.label)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !page.isLast {
                        Button { move { $0.forward() } } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.bordered)
                            .keyboardShortcut(.rightArrow, modifiers: [])
                            .help("Next question")
                            .pointerCursor()
                    }
                }
                if !page.isPaged || page.isLast {
                    Button { submit() } label: {
                        Label("Submit", systemImage: "checkmark").frame(minWidth: 70)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!page.isPaged && !pending.form.canSubmit(pending.answers))
                    .keyboardShortcut(.defaultAction)
                    .pointerCursor()
                }
                Button { session.skipForm(pending.id) } label: {
                    Label("Skip", systemImage: "forward").frame(minWidth: 70)
                }
                .buttonStyle(.bordered)
                .pointerCursor()
                Spacer()
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.5)))
    }

    private func move(_ change: (inout ElicitationPager) -> Void) {
        var next = current
        change(&next)
        pager = next
    }

    /// Sends the answers, or jumps to the first question that still needs one.
    private func submit() {
        if let page = pending.form.firstIncompletePage(pending.answers) {
            move { $0.show(page) }
        } else {
            session.submitForm(pending.id)
        }
    }

    @ViewBuilder
    private func fieldView(_ field: ElicitationField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !field.title.isEmpty || !field.detail.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    if !field.title.isEmpty {
                        Text(field.title + (field.required ? " *" : "")).font(.system(size: 12, weight: .semibold))
                    }
                    if !field.detail.isEmpty {
                        Text(field.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            switch field.kind {
            case .single(let options):
                ForEach(options, id: \.value) { option in
                    optionRow(option, selected: single(field) == option.value, symbol: "largecircle.fill.circle", empty: "circle") {
                        session.setAnswer(form: pending.id, field: field.id, single(field) == option.value ? nil : .one(option.value))
                    }
                }
            case .multi(let options):
                ForEach(options, id: \.value) { option in
                    optionRow(option, selected: many(field).contains(option.value), symbol: "checkmark.square.fill", empty: "square") {
                        var picked = many(field)
                        if let index = picked.firstIndex(of: option.value) { picked.remove(at: index) } else { picked.append(option.value) }
                        session.setAnswer(form: pending.id, field: field.id, picked.isEmpty ? nil : .many(picked))
                    }
                }
            case .text:
                TextField("", text: text(field), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
            case .number:
                TextField("", text: text(field))
                    .textFieldStyle(.roundedBorder)
            case .boolean:
                Toggle("", isOn: Binding(
                    get: { if case .flag(let on)? = pending.answers[field.id] { return on } else { return false } },
                    set: { session.setAnswer(form: pending.id, field: field.id, .flag($0)) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }

    private func optionRow(_ option: ElicitationOption, selected: Bool, symbol: String, empty: String, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? symbol : empty)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title).font(.system(size: 12.5))
                    if !option.detail.isEmpty {
                        Text(option.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func single(_ field: ElicitationField) -> String? {
        if case .one(let value)? = pending.answers[field.id] { return value }
        return nil
    }

    private func many(_ field: ElicitationField) -> [String] {
        if case .many(let values)? = pending.answers[field.id] { return values }
        return []
    }

    private func text(_ field: ElicitationField) -> Binding<String> {
        Binding(
            get: { if case .text(let value)? = pending.answers[field.id] { return value } else { return "" } },
            set: { session.setAnswer(form: pending.id, field: field.id, .text($0)) })
    }
}

/// A form that was answered or skipped, read-only.
struct ElicitationRecordCard: View {
    let record: ElicitationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(record.message.isEmpty ? "Question" : record.message, systemImage: record.skipped ? "forward.circle" : "checkmark.circle.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if record.skipped {
                Text("Skipped").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(Array(record.lines.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.question).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(line.answer).font(.system(size: 12.5)).textSelection(.enabled)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}
