import AppKit
import Combine
import SwiftUI

/// Something Ghost says next to himself: agent updates, approvals, alerts, reminders.
struct Bubble: Identifiable {
    struct Action: Identifiable {
        enum Style { case primary, normal, destructive }
        let id = UUID()
        let title: String
        var style: Style = .normal
        let run: () -> Void
    }

    /// A clickable line in a summary bubble, each opening its own thing.
    struct Line: Identifiable {
        let id = UUID()
        var symbol: String
        var tint: Color
        var text: String
        let run: () -> Void
    }

    /// Showing a bubble with the same id replaces the old one.
    let id: String
    var symbol: String
    var tint: Color
    var title: String
    var subtitle: String?
    var body: String?
    /// Shown instead of `body` when set.
    var lines: [Line] = []
    var actions: [Action] = []
    var onTap: (() -> Void)?
    /// nil stays until answered or closed.
    var expires: Date?
    /// Replaces the icon, title and text, for a bubble that shows live state (the meeting status).
    var content: AnyView?
}

struct BubbleStackView: View {
    @ObservedObject var api: BubblesAPI
    static let padding: CGFloat = 14
    static let tailFromBottom: CGFloat = padding + 20

    var body: some View {
        VStack(alignment: api.petOnLeft ? .leading : .trailing, spacing: 8) {
            ForEach(api.bubbles) { bubble in
                BubbleView(bubble: bubble,
                           tail: bubble.id == api.bubbles.last?.id ? (api.petOnLeft ? .leading : .trailing) : nil,
                           api: api)
                    .transition(.asymmetric(insertion: .scale(scale: 0.85, anchor: api.petOnLeft ? .bottomLeading : .bottomTrailing)
                                                .combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .padding(Self.padding)
        .animation(.spring(duration: 0.3, bounce: 0.25), value: api.bubbles.map(\.id))
        .onHover { api.setHovering($0) }
    }
}

private struct BubbleView: View {
    let bubble: Bubble
    let tail: HorizontalEdge?
    let api: BubblesAPI
    @State private var hovering = false

    private func dismiss() { try? api.dismiss(bubble.id) }

    var body: some View {
        Group {
            if let content = bubble.content {
                content.overlay(alignment: .topTrailing) { closeButton }
            } else {
                standard
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(BubbleShape(tail: tail).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(BubbleShape(tail: tail).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
        .contentShape(Rectangle())
        .onTapGesture {
            guard bubble.onTap != nil else { return }
            try? api.press(PressBubbleRequest(bubble: bubble.id))
        }
        .onHover { hovering = $0 }
    }

    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .opacity(hovering ? 1 : 0)
        .help("Hide")
    }

    private var standard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: bubble.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(bubble.tint)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(bubble.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button(action: dismiss) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
                    .help("Close")
                }
                if let subtitle = bubble.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !bubble.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(bubble.lines) { line in lineButton(line) }
                    }
                    .padding(.top, 3)
                } else if let text = bubble.body, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !bubble.actions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(bubble.actions) { action in button(action) }
                    }
                    .controlSize(.small)
                    .padding(.top, 5)
                }
            }
        }
    }

    private func lineButton(_ line: Bubble.Line) -> some View {
        Button {
            try? api.press(PressBubbleRequest(bubble: bubble.id, line: line.id.uuidString))
        } label: {
            HStack(spacing: 7) {
                Image(systemName: line.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(line.tint)
                    .frame(width: 14)
                Text(line.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(line.text)
        .help(line.text)
    }

    @ViewBuilder private func button(_ action: Bubble.Action) -> some View {
        let run: () -> Void = { try? api.press(PressBubbleRequest(bubble: bubble.id, action: action.id.uuidString)) }
        switch action.style {
        case .primary: Button(action.title, action: run).buttonStyle(.borderedProminent)
        case .destructive: Button(action.title, role: .destructive, action: run).buttonStyle(.bordered)
        case .normal: Button(action.title, action: run).buttonStyle(.bordered)
        }
    }
}

/// Rounded rectangle with a small tail near the bottom of one side, pointing at the pet.
private struct BubbleShape: Shape {
    let tail: HorizontalEdge?

    func path(in rect: CGRect) -> Path {
        let body = Path(roundedRect: rect, cornerRadius: 14)
        guard let tail else { return body }
        let tipY = rect.maxY - 20
        var t = Path()
        if tail == .leading {
            t.move(to: CGPoint(x: rect.minX + 1, y: tipY - 9))
            t.addLine(to: CGPoint(x: rect.minX - 9, y: tipY))
            t.addLine(to: CGPoint(x: rect.minX + 1, y: tipY + 7))
        } else {
            t.move(to: CGPoint(x: rect.maxX - 1, y: tipY - 9))
            t.addLine(to: CGPoint(x: rect.maxX + 9, y: tipY))
            t.addLine(to: CGPoint(x: rect.maxX - 1, y: tipY + 7))
        }
        t.closeSubpath()
        return body.union(t)
    }
}
