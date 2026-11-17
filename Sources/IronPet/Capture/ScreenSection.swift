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
    static func rows(_ log: [CaptureSendRecord]) -> [ScreenSendRow] {
        log.sorted { ($0.at, $0.id) > ($1.at, $1.id) }.map { record in
            ScreenSendRow(id: record.id,
                          title: "\(record.at.formatted(date: .abbreviated, time: .shortened)): \(record.harness) / \(record.model)",
                          detail: "\(record.items.count) items, \(record.bytes) bytes, \(record.outcome)")
        }
    }
}

/// The Screen section: what screen capture has stored and what it sent to the agent.
struct ScreenSection: View {
    @ObservedObject var model: CaptureStatusModel
    @ObservedObject private var config = ConfigStore.shared
    var onShowCaptures: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onAppear: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                captured
                sent
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .pageHeader(IronPetSection.screen.title)
        .onAppear(perform: onAppear)
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
            Button("Show captures…", action: onShowCaptures)
        }
    }

    private var sent: some View {
        let rows = ScreenSectionText.rows(model.sendLog)
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Sent to the agent")
            if rows.isEmpty {
                Text("Nothing has been sent.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                VStack(alignment: .leading) {
                    Text(row.title)
                    Text(row.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Every send is listed here with the time, the agent and model, the capture ids and the size. The text itself is not logged.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
