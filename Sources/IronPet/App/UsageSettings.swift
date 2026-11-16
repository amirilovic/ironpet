import Charts
import SwiftUI

/// Text for the Usage tab. A nil number prints as a dash, because "not reported" is different from zero.
enum UsageFormat {
    static let notReported = "–"

    static func count(_ value: Int?) -> String {
        guard let value else { return notReported }
        return value >= 10_000 ? value.formatted(.number.notation(.compactName)) : value.formatted()
    }

    /// The token counts of one row on a line. Unreported counts print as a dash, so a row with none reads "not reported".
    static func tokenLine(_ row: UsageRow) -> String {
        let parts: [(String, Int?)] = [("Input", row.inputTokens), ("Output", row.outputTokens), ("Cache read", row.cacheReadTokens),
                                       ("Cache write", row.cacheWriteTokens)]
        guard parts.contains(where: { $0.1 != nil }) else {
            return row.totalTokens.map { "Total \(count($0)) tokens" } ?? "Tokens not reported"
        }
        return parts.map { "\($0.0) \(count($0.1))" }.joined(separator: "  ")
    }

    static func cost(_ value: Double?, currency: String?) -> String {
        guard let value else { return notReported }
        let symbol = (currency == nil || currency == "USD") ? "$" : (currency ?? "") + " "
        return symbol + value.formatted(.number.precision(.fractionLength(value < 1 ? 4 : 2)))
    }

    static func time(_ seconds: Double?) -> String {
        guard let seconds else { return notReported }
        if seconds < 60 { return seconds.formatted(.number.precision(.fractionLength(seconds < 10 ? 1 : 0))) + " s" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min \(Int(seconds) % 60) s" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// What ironpet itself ran, by feature and model. Agents ironpet only launches or watches are not in here.
struct UsageSettings: View {
    private enum Metric: String, CaseIterable { case requests = "Requests", tokens = "Tokens" }

    @State private var range: Int
    @State private var metric = Metric.requests
    @State private var summary = UsageSummary(rows: [], days: [])

    init(range: Int = 30) { _range = State(initialValue: range) }

    var body: some View {
        Form {
            if let reason = UsageStore.shared?.unavailable {
                Section { DatabaseBanner(reason: reason) }
            }
            Section {
                Picker("Range", selection: $range) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.segmented)
                Picker("Chart", selection: $metric) {
                    ForEach(Metric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                chart
            } footer: {
                Text("Only what ironpet runs itself: chat (Telegram included), automation prompts, meeting summaries and transcription. Band agents and Claude Code or Codex sessions started elsewhere are not counted. Numbers come from the agent or provider, never estimated, and stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("By feature and model") {
                if summary.rows.isEmpty {
                    Text(UsageStore.shared?.unavailable != nil ? "Usage is not being saved." : "Nothing recorded in this range yet.").foregroundStyle(.secondary)
                } else {
                    table
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .onChange(of: range) { reload() }
    }

    private func reload() {
        guard let store = UsageStore.shared else { return }
        let days = range
        // The read waits for queued writes, so it stays off the main thread.
        Task.detached {
            let result = store.summary(days: days)
            await MainActor.run { if days == range { summary = result } }
        }
    }

    private struct Point: Identifiable {
        let day: Date
        let feature: UsageFeature
        let value: Int
        var id: String { "\(day.timeIntervalSince1970)|\(feature.rawValue)" }
    }

    private var points: [Point] {
        summary.days.flatMap { day in
            (metric == .requests ? day.requests : day.tokens).map { Point(day: day.day, feature: $0.key, value: $0.value) }
        }
    }

    private var chart: some View {
        Chart(points) { point in
            BarMark(x: .value("Day", point.day, unit: .day), y: .value(metric.rawValue, point.value))
                .foregroundStyle(by: .value("Feature", point.feature.title))
        }
        // A fixed scale keeps each feature's colour the same in every range.
        .chartForegroundStyleScale(domain: UsageFeature.allCases.map(\.title))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month().day()) } }
        .frame(height: 150)
        .overlay {
            if points.isEmpty { Text("No data").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var table: some View {
        let showCost = summary.hasCost
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(UsageFeature.allCases.filter { feature in summary.rows.contains { $0.feature == feature } }, id: \.self) { feature in
                VStack(alignment: .leading, spacing: 6) {
                    Text(feature.title).fontWeight(.semibold)
                    ForEach(summary.rows.filter { $0.feature == feature }) { row in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 12) {
                                Text(row.model).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text("\(row.requests) \(feature.isTranscription ? "requests" : "turns")")
                                Text(UsageFormat.time(row.duration ?? row.audioSeconds)).frame(minWidth: 60, alignment: .trailing)
                                if showCost { Text(UsageFormat.cost(row.cost, currency: row.currency)).frame(minWidth: 56, alignment: .trailing) }
                            }
                            .monospacedDigit()
                            Text(UsageFormat.tokenLine(row)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.leading, 12)
                    }
                }
            }
            Text("A dash means the agent or provider did not report it. Time is the turn length for agents and the audio length the provider reported for transcription.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
