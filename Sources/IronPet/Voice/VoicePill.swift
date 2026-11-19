import AppKit
import SwiftUI

/// What voice mode shows by the pet: the state, the last thing heard, and a button to end. The pet itself shows that it
/// is listening (`VoiceConversation.mood`). With Wispr Flow it holds a text field that keeps ironpet focused, so Wispr's dictation is addressed to ironpet.
struct VoicePillView: View {
    @ObservedObject var conversation: VoiceConversation
    var petName: String
    var onEnd: () -> Void

    @FocusState private var fieldFocused: Bool
    @State private var typed = ""

    private var state: VoiceConversation.State { conversation.state }
    private var wispr: Bool { conversation.mode == .wispr }

    var title: String { state.title(wispr: wispr, petName: petName) }
    private var symbol: String { state.symbol }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state == .listening ? Color.red : Color.accentColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let heard = conversation.heard {
                    Text(heard)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if wispr {
                // Wispr Flow types into the focused app; this field keeps that app ironpet. Its text arrives through
                // Wispr's history instead (`WisprBridge`), so the field is cleared and never sent.
                TextField("", text: $typed)
                    .textFieldStyle(.plain)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .focused($fieldFocused)
                    .onChange(of: typed) { if !typed.isEmpty { typed = "" } }
                    .accessibilityHidden(true)
            }
            Button(action: onEnd) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("End the conversation (Esc)")
            .accessibilityLabel("End voice conversation")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 280)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice mode: \(title)")
        .onAppear { fieldFocused = wispr }
        .onChange(of: conversation.mode) { fieldFocused = wispr }
    }
}

extension VoiceConversation.State {
    /// The state in a few words, for the pill and the Voice page.
    func title(wispr: Bool, petName: String) -> String {
        switch self {
        case .idle: return "Voice mode"
        case .listening: return wispr ? "Dictate with Wispr Flow" : "Listening…"
        case .transcribing: return "Got it…"
        case .thinking: return "Thinking…"
        case .speaking: return "\(petName) is speaking"
        }
    }

    var symbol: String {
        switch self {
        case .idle, .listening: return "mic.fill"
        case .transcribing, .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        }
    }
}

/// Bars that follow the microphone's level, as tall as the frame. With Reduce Motion on they show one steady level.
struct VoiceLevelMeter: View {
    let levels: LevelBuffer
    var count = 5
    var barWidth: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                bars(Array(repeating: 0.5, count: count))
            } else {
                TimelineView(.animation) { timeline in
                    let _ = timeline.date
                    bars(levels.recent(count).bars)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func bars(_ values: [Float]) -> some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: barWidth * 0.75) {
                ForEach(values.indices, id: \.self) { index in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: barWidth, height: max(barWidth, CGFloat(values[index]) * proxy.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The pill's window: borderless, above other windows and next to the pet. It only takes focus in Wispr mode, where the
/// dictation needs a focused ironpet window.
@MainActor
final class VoicePillPanel {
    let panel: NSPanel
    private let host: NSHostingView<VoicePillView>
    private let petName: () -> String

    init(conversation: VoiceConversation, petName: @escaping () -> String, onEnd: @escaping () -> Void) {
        self.petName = petName
        panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        host = NSHostingView(rootView: VoicePillView(conversation: conversation, petName: petName(), onEnd: onEnd))
        panel.contentView = host
    }

    /// Shows the pill above the pet, or below it near the top of the screen. `focus` makes it the key window.
    func present(near pet: CGRect, focus: Bool) {
        host.rootView.petName = petName()
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(pet) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = CGPoint(x: pet.midX - size.width / 2, y: pet.maxY + 6)
        if origin.y + size.height > screen.maxY { origin.y = pet.minY - size.height - 6 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        if focus {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func dismiss() {
        panel.orderOut(nil)
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
