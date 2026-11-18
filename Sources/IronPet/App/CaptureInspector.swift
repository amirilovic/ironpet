import AppKit
import SwiftUI

/// What screen capture stored, for debugging: when, from which app and thread, the text, what the local filter decided and whether it
/// was sent. It is the Captures tab of the Screen section. It reads the local database only. Nothing here goes to a model, to MCP or to a log.
struct CaptureInspectorView: View {
    let store: CaptureStore
    @State private var rows: [CaptureStore.InspectRow] = []
    @State private var selection: Int64?
    @State private var filter = "all"
    @State private var search = ""
    /// The item whose unredacted original is shown.
    @State private var revealed: Int64?
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var shown: [CaptureStore.InspectRow] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { ($0.body + " " + $0.threadTitle + " " + $0.appName).lowercased().contains(needle) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Picker("State", selection: $filter) {
                        Text("All").tag("all")
                        Text("Waiting for filter").tag("new")
                        Text("Passed").tag("ready")
                        Text("Kept on Mac").tag("local")
                        Text("Sent").tag("sent")
                    }
                    .labelsHidden().frame(width: 150)
                    TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                }
                .padding(8)
                List(shown, selection: $selection) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(row.appName).font(.headline)
                            Spacer()
                            stateTag(row)
                        }
                        Text(row.threadTitle).font(.subheadline).lineLimit(1)
                        Text(row.at.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                        Text(row.body.isEmpty ? "(text dropped)" : String(row.body.prefix(100))).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .tag(row.id)
                }
            }
            .frame(minWidth: 220, idealWidth: 360)
            detail
                .frame(minWidth: 300)
        }
        .onAppear(perform: reload)
        .onReceive(timer) { _ in reload() }
        .onChange(of: filter) { reload() }
    }

    private func reload() {
        rows = store.inspect(state: filter == "all" ? nil : filter)
        if selection == nil { selection = rows.first?.id }
    }

    private func stateTag(_ row: CaptureStore.InspectRow) -> some View {
        let (text, color): (String, Color) = switch row.state {
        case "new": ("waiting", .secondary)
        case "ready": ("passed", .blue)
        case "local": ("kept on Mac", .orange)
        case "sent": ("sent", .green)
        default: (row.state, .secondary)
        }
        return Text(text).font(.caption).foregroundStyle(color)
    }

    @ViewBuilder private var detail: some View {
        if let row = rows.first(where: { $0.id == selection }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.threadTitle).font(.title3)
                    Group {
                        line("App", "\(row.appName) (\(row.app))")
                        line("Thread", row.threadKey)
                        if let url = row.url { line("URL", url) }
                        line("Kind", "\(row.kind), version \(row.version)" + (row.newMessages > 0 ? ", \(row.newMessages) new messages" : ""))
                        line("Captured", row.at.formatted(date: .complete, time: .standard))
                        line("State", row.state + (row.reason.map { ": \($0)" } ?? ""))
                        line("Outcome", store.outcome(of: row))
                        if let sent = row.sentAt { line("Sent", sent.formatted(date: .abbreviated, time: .standard)) }
                        if let label = CaptureDecisionFilter.notCheckedLabel(state: row.state, secret: row.secret) { line("Model", label) }
                        if let secret = row.secret { line("Secret score", secret.formatted(.number.precision(.fractionLength(2)))) }
                        if let calendar = row.calendar { line("Calendar score", calendar.formatted(.number.precision(.fractionLength(2)))) }
                        if let task = row.task { line("New-task score", task.formatted(.number.precision(.fractionLength(2)))) }
                        if let related = row.related, related != "[]" { line("Related tasks", related) }
                    }
                    Divider()
                    if revealed == row.id, let original = store.original(of: row.id) {
                        Label("Unredacted. Kept on this Mac until \(original.expires.formatted(date: .omitted, time: .shortened)), never sent.", systemImage: "eye")
                            .font(.caption).foregroundStyle(.orange)
                        Text(original.text.isEmpty ? "The original is empty." : original.text)
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(row.body.isEmpty ? "The text of this item was dropped." : row.body)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !row.redactions.isEmpty || row.originalUntil != nil {
                        if let until = row.originalUntil {
                            Button(revealed == row.id ? "Hide original" : "Reveal original") { revealed = revealed == row.id ? nil : row.id }
                            Text("The unredacted text is deleted at \(until.formatted(date: .abbreviated, time: .shortened)). After that only the redacted text remains.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("The unredacted original was deleted after 24 hours. Only the redacted text remains.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Copy text") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(row.body, forType: .string)
                        }
                        Button("Show database in Finder") {
                            if let path = store.database.path { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                        }
                    }
                }
                .padding(12)
            }
        } else {
            Text(rows.isEmpty ? "Nothing has been captured yet." : "Select an item.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }
}
