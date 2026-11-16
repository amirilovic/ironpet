import SwiftUI

extension ChatFind {
    static let highlightColor = Color.yellow.opacity(0.5)
    static let currentColor = Color.orange

    /// `text` with every match of the query highlighted. The current match gets a stronger color.
    /// Returns plain text when the row has no highlight, so unmatched rows render as before.
    static func text(_ attributed: AttributedString, segment: Int, find: RowHighlight?) -> Text {
        guard let find else { return Text(attributed) }
        let plain = String(attributed.characters)
        let ranges = ranges(of: find.query, in: plain)
        guard !ranges.isEmpty else { return Text(attributed) }
        var result = attributed
        var cursor = result.startIndex
        var cursorOffset = 0
        for (occurrence, range) in ranges.enumerated() {
            let start = result.characters.index(cursor, offsetBy: range.lowerBound - cursorOffset)
            let end = result.characters.index(start, offsetBy: range.count)
            cursor = end
            cursorOffset = range.upperBound
            let isCurrent = find.current?.segment == segment && find.current?.occurrence == occurrence
            result[start..<end].backgroundColor = isCurrent ? currentColor : highlightColor
            result[start..<end].foregroundColor = .black
        }
        return Text(result)
    }
}

/// The bar under the header: query field, "3 of 12", previous and next, close.
struct FindBar: View {
    @Binding var query: String
    let label: String
    let hasMatches: Bool
    let focusTick: Int
    let step: (Int) -> Void
    let close: () -> Void
    @FocusState private var focused: Bool
    static let fieldID = "findField"
    /// SwiftUI does not copy the accessibility identifier onto the AppKit field, so AppKit lookups match this.
    static let placeholder = "Find in chat"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(Self.placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .accessibilityIdentifier(Self.fieldID)
                .focusEffectDisabled()
                .onSubmit { step(1) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    step(-1)
                    return .handled
                }
            Text(label)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("findLabel")
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .pointerCursor()
                .help("Previous match (Shift-Return)")
                .disabled(!hasMatches)
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .pointerCursor()
                .help("Next match (Return)")
                .disabled(!hasMatches)
            Button(action: close) { Image(systemName: "xmark") }
                .pointerCursor()
                .help("Close (Esc)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .chromeGlass(in: Capsule())
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .onAppear { focused = true }
        .onChange(of: focusTick) { focused = true; selectAll() }
    }

    /// Cmd-F again selects the existing query, like other find bars.
    private func selectAll() {
        DispatchQueue.main.async { if focused { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) } }
    }
}
