import SwiftUI

/// Replaces the whole composer while a voice note is recording or being transcribed: cancel, a live waveform across
/// the full width, the elapsed time, and stop. Nothing else from the composer stays visible.
struct VoiceBar: View {
    @ObservedObject var voice: VoiceController

    private var transcribing: Bool { voice.phase == .transcribing }

    var body: some View {
        HStack(spacing: 10) {
            circleButton("xmark", help: transcribing ? "Cancel transcription" : "Discard recording") { voice.cancel() }
            Waveform(voice: voice)
                .frame(height: 34)
                .frame(maxWidth: .infinity)
                .opacity(transcribing ? 0.3 : 1)
                .animation(.easeOut(duration: 0.2), value: transcribing)
            if transcribing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else {
                ElapsedTime(since: voice.startedAt)
                Button { voice.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.red, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Stop and transcribe")
            }
        }
        .frame(minHeight: 34)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(transcribing ? "Transcribing voice note" : "Recording voice note")
    }

    private func circleButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// `0:07 / 5:00`. The limit is shown because a note is cut off there instead of being split.
private struct ElapsedTime: View {
    let since: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let seconds = Int(max(0, context.date.timeIntervalSince(since ?? context.date)))
            HStack(spacing: 3) {
                Text(Self.format(seconds)).foregroundStyle(.primary)
                Text("/ \(Self.format(Int(VoiceController.maxDuration)))").foregroundStyle(.tertiary)
            }
            .font(.system(size: 12, design: .monospaced))
            .monospacedDigit()
            .help("A voice note is cut off at \(Int(VoiceController.maxDuration) / 60) minutes")
        }
    }

    static func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Mirrored bars scrolling right to left, drawn from the level buffer on the display's own timeline. With Reduce
/// Motion on it redraws a few times a second and steps instead of scrolling.
private struct Waveform: View {
    @ObservedObject var voice: VoiceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barWidth: CGFloat = 3
    private static let gap: CGFloat = 2.5

    var body: some View {
        // Reduce Motion stops the `.animation` schedule from ticking, so it gets a plain periodic one.
        Group {
            if reduceMotion {
                TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                    bars(frame: timeline.date)
                }
            } else {
                TimelineView(.animation(paused: voice.phase == .transcribing)) { timeline in
                    bars(frame: timeline.date)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// `voice.levels` is a reference type, so the Canvas only redraws if its closure captures something that
    /// changes every frame. The timeline date does that.
    private func bars(frame: Date) -> some View {
        Canvas { context, size in
            _ = frame
            let pitch = Self.barWidth + Self.gap
            let count = Int(size.width / pitch) + 2
            let (bars, phase) = voice.levels.recent(count)
            let shift = reduceMotion ? 0 : CGFloat(phase) * pitch
            for (index, level) in bars.enumerated() {
                let x = size.width - CGFloat(bars.count - index) * pitch - shift + pitch
                guard x > -pitch, x < size.width else { continue }
                let height = max(Self.barWidth, CGFloat(level) * size.height)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: Self.barWidth, height: height)
                // Older bars fade out toward the left edge.
                let fade = min(1, max(0.15, x / (size.width * 0.35)))
                context.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2),
                             with: .color(.accentColor.opacity(fade)))
            }
        }
    }
}
