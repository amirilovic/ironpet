import AppKit
import SwiftUI

/// The floating panel that is on screen for the whole time ironpet records a meeting. It does not take focus, so the
/// call app keeps the keyboard, and it has no close button while recording.
final class MeetingPanel: NSPanel {
    private static let width: CGFloat = 340
    private let host: NSHostingController<MeetingView>

    init(controller: MeetingController) {
        host = NSHostingController(rootView: MeetingView(controller: controller, embedded: false))
        super.init(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 260),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        backgroundColor = .windowBackgroundColor
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        host.sizingOptions = [.preferredContentSize]
        contentViewController = host
        setContentSize(CGSize(width: Self.width, height: 260))
    }

    override var canBecomeKey: Bool { true }

    /// Esc must not hide a panel that tells people they are being recorded.
    override func cancelOperation(_ sender: Any?) {}

    /// Shows the panel next to the pet. If it is already up, it only follows its new height, so a panel the user
    /// moved stays where they put it.
    func present(near pet: CGRect) {
        if !isVisible {
            let size = fittingSize
            let screen = NSScreen.screens.first { $0.frame.intersects(pet) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            var origin = CGPoint(x: pet.midX - size.width / 2, y: pet.maxY + 8)
            if origin.y + size.height > screen.maxY { origin.y = pet.minY - size.height - 8 }
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
            setFrame(CGRect(origin: origin, size: size), display: true)
        }
        orderFrontRegardless()
        // SwiftUI reports its new height a moment after the phase changes.
        DispatchQueue.main.async { [weak self] in self?.refit() }
    }

    func dismiss() {
        orderOut(nil)
    }

    private var fittingSize: CGSize {
        CGSize(width: Self.width, height: max(host.preferredContentSize.height, 120))
    }

    /// Resizes to the content, keeping the top edge where it is.
    private func refit() {
        let size = fittingSize
        guard isVisible, abs(frame.height - size.height) > 0.5 else { return }
        setFrame(CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }
}

struct MeetingView: View {
    @ObservedObject var controller: MeetingController
    /// In the pet's bubble, which supplies the padding, width and background.
    var embedded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if embedded { content } else { content.padding(16).frame(width: 340, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor)).ignoresSafeArea(.container, edges: .top)
            .fixedSize(horizontal: false, vertical: true) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch controller.phase {
            case .idle: EmptyView()
            case .choosing: picker
            case .recording: recording
            case .finishing: progress("Transcribing remaining audio…")
            case .summarizing: progress("Summarizing…")
            case .done: done
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meeting transcript").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Record audio from").font(.caption).foregroundStyle(.secondary)
                Picker("Record audio from", selection: $controller.choice) {
                    ForEach(controller.apps) { app in Text(app.name).tag(AudioChoice.app(app)) }
                    if !controller.apps.isEmpty { Divider() }
                    Text("All system audio").tag(AudioChoice.allSystemAudio)
                }
                .labelsHidden()
                .accessibilityLabel("App to record")
            }
            Text("Your microphone is recorded as Me and this audio as Them. Both go to the server from Settings → Voice. ironpet's own sound is left out.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Tell everyone on the call. Recording people without consent is illegal in many places.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let notice = controller.notice {
                Text(notice).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { controller.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start recording") { controller.start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Recording

    private var recording: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RecordingDot(reduceMotion: reduceMotion)
                Text("Recording").font(.system(size: 13, weight: .semibold))
                Text(controller.appName).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Elapsed(since: controller.startedAt)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording \(controller.appName)")
            VStack(spacing: 6) {
                trackRow("Me", levels: controller.myLevels)
                trackRow("Them", levels: controller.theirLevels)
            }
            chunkStatus
            lines
            if let notice = controller.notice {
                Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { controller.confirmDiscard() }
                Spacer()
                Button { controller.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func trackRow(_ name: String, levels: LevelBuffer) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            LevelBars(levels: levels, reduceMotion: reduceMotion).frame(height: 18)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) audio level")
    }

    @ViewBuilder private var chunkStatus: some View {
        let counts = controller.counts
        if counts.waiting > 0 || counts.failed > 0 {
            Text(statusText(counts)).font(.caption).foregroundStyle(.orange)
        }
    }

    private func statusText(_ counts: (done: Int, waiting: Int, failed: Int)) -> String {
        var parts: [String] = []
        if counts.waiting > 0 { parts.append("\(counts.waiting) chunk\(counts.waiting == 1 ? "" : "s") waiting") }
        if counts.failed > 0 { parts.append("\(counts.failed) failed") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var lines: some View {
        let recent = controller.recentLines
        if recent.isEmpty {
            Text("Transcript lines appear here as each chunk finishes.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(recent.enumerated()), id: \.offset) { _, line in
                    (Text(line.track.rawValue + ": ").fontWeight(.medium).foregroundColor(line.track == .me ? .accentColor : .secondary)
                        + Text(line.text))
                        .font(.system(size: 11))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: After stop

    private func progress(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.system(size: 13, weight: .semibold))
            }
            chunkStatus
            lines
            HStack {
                if controller.phase == .finishing { Button("Cancel") { controller.confirmDiscard() } }
                Spacer()
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Meeting saved").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { controller.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Close")
            }
            Text(controller.appName + " · " + controller.folderLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if controller.counts.failed > 0 {
                HStack {
                    Text("\(controller.counts.failed) chunk\(controller.counts.failed == 1 ? "" : "s") could not be transcribed.")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Retry") { controller.retryFailed() }.controlSize(.small)
                }
            }
            switch controller.summary {
            case .failed(let message):
                Text("Summary failed: \(message)").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
            lines
            HStack(spacing: 8) {
                Button("Open transcript") { controller.openTranscript() }
                if case .ready = controller.summary { Button("Open summary") { controller.openSummary() } }
                Button("Open in chat") { controller.openInChat() }
            }
            .controlSize(.small)
        }
    }
}

private extension MeetingController {
    var folderLabel: String { folder?.lastPathComponent ?? "" }
}

/// `12:34`, or `1:02:03` after an hour.
private struct Elapsed: View {
    let since: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            Text(Self.format(Int(max(0, context.date.timeIntervalSince(since ?? context.date)))))
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    static func format(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A red dot that pulses. With Reduce Motion on it stays solid.
private struct RecordingDot: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : nil)) { context in
            let phase = reduceMotion ? 1 : 0.65 + 0.35 * (0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 3))
            Circle().fill(Color.red).frame(width: 9, height: 9).opacity(phase)
        }
        .accessibilityHidden(true)
    }
}

/// Small scrolling bars for one track, drawn from its level buffer on the display's own timeline.
private struct LevelBars: View {
    let levels: LevelBuffer
    let reduceMotion: Bool

    private static let barWidth: CGFloat = 2.5
    private static let gap: CGFloat = 2

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : nil)) { timeline in
            Canvas { context, size in
                // Reading the timeline's date makes SwiftUI redraw on every tick.
                _ = timeline.date
                let pitch = Self.barWidth + Self.gap
                let count = Int(size.width / pitch) + 2
                let (bars, phase) = levels.recent(count)
                let shift = reduceMotion ? 0 : CGFloat(phase) * pitch
                for (index, level) in bars.enumerated() {
                    let x = size.width - CGFloat(bars.count - index) * pitch - shift + pitch
                    guard x > -pitch, x < size.width else { continue }
                    let height = max(Self.barWidth, CGFloat(level) * size.height)
                    let rect = CGRect(x: x, y: (size.height - height) / 2, width: Self.barWidth, height: height)
                    let fade = min(1, max(0.15, x / (size.width * 0.35)))
                    context.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2),
                                 with: .color(.accentColor.opacity(fade)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
