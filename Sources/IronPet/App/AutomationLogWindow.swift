import AppKit
import SwiftUI

/// The execution log of the automations: every poll and script run (quiet ones too), and every reminder, shell command and
/// prompt that ran, with how long it took and what it said. Lines older than the retention in Settings are deleted.
@MainActor
final class AutomationLogWindow {
    private var window: NSWindow?
    private let model = AutomationLogModel()
    private let api: () -> AutomationsAPI?

    init(api: @escaping () -> AutomationsAPI?) {
        self.api = api
    }

    func show(automation: String? = nil) {
        guard let api = api() else { return }
        model.api = api
        model.filter = automation
        model.reload()
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: AutomationLogView(model: model)))
            window.title = "Automation logs"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 860, height: 520))
            window.minSize = NSSize(width: 640, height: 360)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class AutomationLogModel: ObservableObject {
    var api: AutomationsAPI?
    @Published var filter: String? { didSet { reload() } }
    @Published private(set) var logs: [AutomationLogEntry] = []
    @Published var selection: Int64?
    @Published var onlyProblems = false
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    var automations: [Automation] { api?.automations ?? [] }
    var unavailable: String? { api?.logsUnavailable }
    var retentionDays: Int { api?.logRetentionDays ?? 14 }

    func name(_ id: String) -> String { automations.first { $0.id == id }?.name ?? id }

    func reload() {
        guard let api else { return }
        logs = api.logs(AutomationLogRequest(automation: filter, onlyProblems: onlyProblems))
    }

    func clear() {
        api?.clearLogs(automation: filter)
        selection = nil
        reload()
    }
}

private struct AutomationLogView: View {
    @ObservedObject var model: AutomationLogModel

    var body: some View {
        VStack(spacing: 0) {
            if let reason = model.unavailable { DatabaseBanner(reason: reason) }
            HStack {
                Picker("Automation", selection: $model.filter) {
                    Text("All automations").tag(String?.none)
                    ForEach(model.automations) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(maxWidth: 280)
                Toggle("Problems only", isOn: $model.onlyProblems).onChange(of: model.onlyProblems) { model.reload() }
                Spacer()
                Button("Refresh") { model.reload() }
                Button("Clear", role: .destructive) { model.clear() }
            }
            .padding(10)
            Divider()
            HSplitView {
                list.frame(minWidth: 380)
                detail.frame(minWidth: 240)
            }
            Divider()
            Text("Logs older than \(model.retentionDays) day\(model.retentionDays == 1 ? "" : "s") are deleted. Change this under Automations in the ironpet window.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private var list: some View {
        Group {
            if model.logs.isEmpty && model.unavailable != nil {
                Text("History is not being saved.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.logs.isEmpty {
                Text("No runs logged yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.logs, selection: $model.selection) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(color(entry.outcome)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(model.filter == nil ? model.name(entry.automation) : entry.outcome).font(.callout.weight(.medium))
                                Spacer()
                                Text(entry.date, format: .dateTime.month().day().hour().minute().second()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Text(entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .tag(entry.id)
                }
            }
        }
    }

    private var detail: some View {
        Group {
            if let entry = model.logs.first(where: { $0.id == model.selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.name(entry.automation)).font(.headline)
                        Text("\(entry.outcome) · \(entry.date.formatted(date: .abbreviated, time: .standard))" + (entry.duration > 0 ? " · \(String(format: "%.2f", entry.duration)) s" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(entry.summary).font(.callout).textSelection(.enabled)
                        if !entry.detail.isEmpty, entry.detail != entry.summary {
                            Text(entry.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Select a run to see its output.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func color(_ outcome: String) -> Color {
        switch outcome {
        case "failed": return .red
        case "skipped", "waiting": return .orange
        case "baseline": return .blue
        case "fired": return .green
        default: return .secondary
        }
    }
}
