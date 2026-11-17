import AppKit
import SwiftUI

/// The Today section: the morning brief or the day's recap, one row per thing to look at. A row opens its task, session,
/// alert or meeting.
struct TodayView: View {
    @ObservedObject var model: BriefModel
    @Binding var kind: Brief.Kind
    let onOpen: (Brief.Target) -> Void

    var body: some View {
        content
            .pageHeader(IronPetSection.today.title) {
                Picker("Show", selection: Binding(get: { kind }, set: { kind = $0; model.picked() })) {
                    ForEach(Brief.Kind.allCases) { Text($0.pickerTitle).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Brief or recap")
            }
            .onAppear { model.setVisible(true) }
            .onDisappear { model.setVisible(false) }
    }

    @ViewBuilder private var content: some View {
        if let brief = model.briefs[kind], !brief.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.dateLine(kind, kind == .recap ? brief.window.start : brief.window.end))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                    ForEach(brief.sections.filter { !$0.items.isEmpty }) { section in
                        SectionTitle(section.title)
                        ForEach(section.items) { item in
                            BriefRow(item: item, onOpen: onOpen)
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: .infinity)
        } else {
            EmptyState(symbol: kind.symbol, title: kind.emptyText, detail: Self.emptyDetail(kind))
        }
    }

    /// "Morning brief · Tuesday 17 November".
    static func dateLine(_ kind: Brief.Kind, _ date: Date) -> String {
        "\(kind.title) · \(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))"
    }

    static func emptyDetail(_ kind: Brief.Kind) -> String {
        kind == .brief
            ? "Due tasks, alerts, open action items from meetings and agents waiting on you show up here."
            : "Finished agent turns, closed tasks, resolved alerts and meetings from today show up here."
    }
}

private struct BriefRow: View {
    let item: Brief.Item
    let onOpen: (Brief.Target) -> Void
    @State private var hovering = false

    var body: some View {
        Button { onOpen(item.target) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(tint)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(help)
        .contextMenu {
            if case .alert(let id, let url?) = item.target {
                Button("Open Link") { NSWorkspace.shared.open(url) }
                Button("Show in Alerts") { onOpen(.alert(id: id, url: nil)) }
            }
        }
    }

    private var tint: Color {
        switch item.symbol {
        case "xmark.octagon.fill", "calendar.badge.exclamationmark": return .red
        case "hand.raised.fill", "person.fill.questionmark": return .orange
        case "checkmark.circle.fill", "checkmark.circle", "checkmark.seal.fill": return .green
        default: return .accentColor
        }
    }

    private var help: String {
        switch item.target {
        case .task: return "Show in Tasks"
        case .session: return "Open the session"
        case .alert(_, let url): return url == nil ? "Show in Alerts" : "Open the link"
        case .meeting: return "Open the meeting"
        }
    }
}
