import AppKit
import SwiftUI

/// What one send to the larger model shows as in the Screen section.
struct ScreenSendRow: Equatable, Identifiable {
    var id: Int64
    var title: String
    var detail: String
}

/// The text of the capture block, kept apart from the view so tests can check it.
enum ScreenSectionText {
    static func summary(items: Int, pending: Int, localOnly: Int) -> String {
        "\(items) items, \(pending) waiting, \(localOnly) kept on this Mac"
    }

    /// One row per send, newest first.
    /// `suggestions` adds each send's suggestion count, taken from the stored suggestions rather than the log's outcome text.
    static func rows(_ log: [CaptureSendRecord], suggestions: [Int64: Int] = [:]) -> [ScreenSendRow] {
        log.sorted { ($0.at, $0.id) > ($1.at, $1.id) }.map { record in
            ScreenSendRow(id: record.id,
                          title: "\(record.at.formatted(date: .abbreviated, time: .shortened)): \(record.harness) / \(record.model)",
                          detail: "\(record.items.count) items, \(record.bytes) bytes, \(record.outcome)"
                              + (suggestions[record.id].map { ", \($0) stored suggestion\($0 == 1 ? "" : "s")" } ?? ""))
        }
    }
}

/// The two tabs of the Screen section.
enum ScreenTab: String, CaseIterable, Identifiable {
    case captures, sent

    var id: String { rawValue }
    var title: String { self == .captures ? "Captures" : "Sent to the agent" }
}

/// The Screen section: the capture counts above two tabs, what screen capture has stored and what it sent to the agent.
struct ScreenSection: View {
    @ObservedObject var model: CaptureStatusModel
    @ObservedObject private var config = ConfigStore.shared
    @Binding var tab: ScreenTab
    /// The capture database for the Captures tab. Nil before the app has started.
    var store: CaptureStore?
    var onOpenSettings: () -> Void = {}
    var onAppear: () -> Void = {}
    /// Reads one send's items and suggestions. Nil when the app has no task store.
    var loadBatch: (Int64) -> ScreenBatch? = { _ in nil }
    var loadCounts: ([Int64]) -> [Int64: Int] = { _ in [:] }
    var onAccept: (String) -> Void = { _ in }
    var onSkip: (String) -> Void = { _ in }

    @State private var selected: Int64?
    @State private var batch: ScreenBatch?
    @State private var counts: [Int64: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                captured
                Picker("Screen", selection: $tab) {
                    ForEach(ScreenTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            switch tab {
            case .captures:
                if let store {
                    CaptureInspectorView(store: store)
                } else {
                    Text("Nothing has been captured yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .sent:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let batch {
                            ScreenBatchView(batch: batch, onBack: { self.batch = nil; selected = nil; refresh() },
                                            onAccept: { onAccept($0); reload() }, onSkip: { onSkip($0); reload() })
                        } else {
                            sent
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .pageHeader(IronPetSection.screen.title)
        .onAppear { onAppear(); refresh() }
        .onChange(of: model.sendLog) { _ in refresh() }
    }

    private func refresh() { counts = loadCounts(model.sendLog.map(\.id)) }

    private func reload() {
        if let selected { batch = loadBatch(selected) }
        refresh()
    }

    private var captured: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Captured")
            Text(ScreenSectionText.summary(items: model.itemCount, pending: model.pendingCount, localOnly: model.localOnlyCount))
            if !config.config.screenCapture.enabled {
                HStack {
                    Text("Screen capture is off").foregroundStyle(.secondary)
                    Button("Open Settings", action: onOpenSettings)
                }
            }
        }
    }

    private var sent: some View {
        let rows = ScreenSectionText.rows(model.sendLog, suggestions: counts)
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Sent to the agent")
            if rows.isEmpty {
                Text("Nothing has been sent.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                Button {
                    selected = row.id
                    batch = loadBatch(row.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.title)
                            Text(row.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("Every send is listed here with the time, the agent and model, the capture ids and the size. Open one to see its items and the suggestions it produced.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One send: the items it carried, the redaction summary, and every suggestion it produced with what happened to it.
struct ScreenBatchView: View {
    let batch: ScreenBatch
    var onBack: () -> Void = {}
    var onAccept: (String) -> Void = { _ in }
    var onSkip: (String) -> Void = { _ in }

    @State private var open: Set<Int64> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Back to sends", action: onBack)
            let record = batch.record
            SectionTitle("\(record.at.formatted(date: .abbreviated, time: .shortened)): \(record.harness) / \(record.model)")
            Text("\(record.items.count) items, \(record.bytes) bytes, \(record.outcome)").font(.caption).foregroundStyle(.secondary)
            Text(batch.redactions.summary).font(.caption).foregroundStyle(.secondary)
            SectionTitle(ScreenBatchText.suggestionsTitle(batch.suggestions.count))
            if batch.suggestions.isEmpty {
                Text("This send produced no suggestions.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(batch.suggestions) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ScreenBatchLoader.label(s.kind)): \(s.title)")
                    if !s.quote.isEmpty { Text("\u{201C}\(s.quote)\u{201D}").font(.caption).foregroundStyle(.secondary) }
                    Text(ScreenBatchText.outcome(s.outcome)).font(.caption).foregroundStyle(.secondary)
                    if case .pending(let id) = s.outcome {
                        HStack {
                            Button("Accept") { onAccept(id) }
                            Button("Skip") { onSkip(id) }
                        }
                    }
                }
            }
            SectionTitle("Items sent")
            ForEach(batch.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        if open.contains(item.id) { open.remove(item.id) } else { open.insert(item.id) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(ScreenBatchText.itemTitle(item))
                            Text(ScreenBatchText.itemDetail(item)).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if open.contains(item.id) {
                        Text(item.body.isEmpty ? "No text is stored for this item." : item.body)
                            .font(.caption).textSelection(.enabled)
                            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            Text("The text shown is the redacted text stored on this Mac, which is what was sent. It is never logged.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The wording of the batch view, kept apart so tests can check it.
enum ScreenBatchText {
    static func suggestionsTitle(_ n: Int) -> String { n == 0 ? "Suggestions" : "Suggestions (\(n))" }

    static func outcome(_ outcome: ScreenBatch.Suggestion.Outcome) -> String {
        switch outcome {
        case .pending: return "Waiting for review"
        case .accepted(let task, let title): return "Accepted" + (title.map { ": \($0)" } ?? task.map { ": task \($0)" } ?? "")
        case .rejected(let note): return "Rejected" + (note.map { ": \($0)" } ?? "")
        }
    }

    static func itemTitle(_ item: ScreenBatch.Item) -> String {
        guard let app = item.app else { return "Item \(item.id) (no longer stored)" }
        return "\(app): \(item.title ?? "")"
    }

    static func itemDetail(_ item: ScreenBatch.Item) -> String {
        guard let at = item.at else { return "Removed from the capture history" }
        return "\(at.formatted(date: .abbreviated, time: .shortened)), \(item.state ?? "")"
    }
}
