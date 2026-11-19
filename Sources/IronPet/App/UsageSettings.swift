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

    /// The line above the chart. Today is always there, whatever range is selected.
    static func summaryLine(today: Double, range: Double) -> String {
        "Today \(cost(today, currency: nil)) · This range \(cost(range, currency: nil))"
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
    private enum Metric: String, CaseIterable { case requests = "Requests", tokens = "Tokens", cost = "Cost" }

    @State private var range: Int
    @State private var metric = Metric.requests
    @State private var summary = UsageSummary(rows: [], days: [])

    /// Range tag for today, charted by hour. The other tags are a number of days.
    nonisolated static let todayRange = 1

    /// `sample` fills the view without reading the store, for `--render-previews`.
    private let sample: UsageSummary?

    init(range: Int = 30, sample: UsageSummary? = nil, showCost: Bool = false) {
        _range = State(initialValue: range)
        _metric = State(initialValue: showCost ? .cost : .requests)
        _summary = State(initialValue: sample ?? UsageSummary(rows: [], days: []))
        self.sample = sample
    }

    var body: some View {
        Form {
            if let reason = UsageAPI.live?.unavailable {
                Section { DatabaseBanner(reason: reason) }
            }
            Section {
                Picker("Range", selection: $range) {
                    Text("Today").tag(Self.todayRange)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.segmented)
                Picker("Chart", selection: $metric) {
                    ForEach(Metric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(UsageFormat.summaryLine(today: summary.todayCost, range: summary.rangeCost)).monospacedDigit()
                chart
            } footer: {
                if metric == .cost, summary.uncostedEvents > 0 {
                    Text("\(summary.uncostedEvents) \(summary.uncostedEvents == 1 ? "request" : "requests") in this range reported no cost and count as 0.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Only what ironpet runs itself: chat (Telegram included), automation prompts, meeting summaries and transcription. Band agents and Claude Code or Codex sessions started elsewhere are not counted. Numbers come from the agent or provider, never estimated, and stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("By feature and model") {
                if summary.rows.isEmpty {
                    Text(UsageAPI.live?.unavailable != nil ? "Usage is not being saved." : "Nothing recorded in this range yet.").foregroundStyle(.secondary)
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
        guard sample == nil, let store = UsageAPI.live else { return }
        let days = range
        // The read waits for queued writes, so it stays off the main thread.
        Task { @MainActor in
            let result = (try? store.summary(UsageRequest(days: days, hourly: days == Self.todayRange)))
            await MainActor.run { if days == range, let result { summary = result } }
        }
    }

    private struct Point: Identifiable {
        let day: Date
        let feature: UsageFeature
        let value: Double
        var id: String { "\(day.timeIntervalSince1970)|\(feature.rawValue)" }
    }

    private var points: [Point] {
        summary.days.flatMap { day in
            switch metric {
            case .requests: return day.requests.map { Point(day: day.day, feature: $0.key, value: Double($0.value)) }
            case .tokens: return day.tokens.map { Point(day: day.day, feature: $0.key, value: Double($0.value)) }
            case .cost: return day.cost.map { Point(day: day.day, feature: $0.key, value: $0.value) }
            }
        }
    }

    /// One label per bucket where they fit, else every few days, so no date prints twice.
    private var xAxisStride: (component: Calendar.Component, count: Int) {
        if summary.hourly { return (.hour, 3) }
        switch summary.days.count {
        case ...7: return (.day, 1)
        case ...30: return (.day, 5)
        default: return (.day, 15)
        }
    }

    /// Today spans all 24 hours, so a bar's place on the axis shows the time of day.
    private var xDomain: ClosedRange<Date> {
        guard let first = summary.days.first?.day, let last = summary.days.last?.day else { return Date()...Date().addingTimeInterval(1) }
        return first...Calendar.current.date(byAdding: summary.hourly ? .hour : .day, value: 1, to: last)!
    }

    private var chart: some View {
        let unit: Calendar.Component = summary.hourly ? .hour : .day
        return Chart(points) { point in
            BarMark(x: .value(summary.hourly ? "Hour" : "Day", point.day, unit: unit), y: .value(metric.rawValue, point.value))
                .foregroundStyle(by: .value("Feature", point.feature.title))
        }
        // A fixed scale keeps each feature's colour the same in every range.
        .chartForegroundStyleScale(domain: UsageFeature.allCases.map(\.title))
        .chartXAxis {
            AxisMarks(values: .stride(by: xAxisStride.component, count: xAxisStride.count)) { _ in
                AxisGridLine(); AxisTick()
                if summary.hourly { AxisValueLabel(format: .dateTime.hour(), centered: true) }
                else { AxisValueLabel(format: .dateTime.month().day(), centered: true) }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine(); AxisTick()
                if metric == .cost, let amount = value.as(Double.self) { AxisValueLabel(amount == 0 ? "$0" : UsageFormat.cost(amount, currency: nil)) }
                else { AxisValueLabel() }
            }
        }
        .chartXScale(domain: xDomain)
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
