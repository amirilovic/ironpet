import Foundation

/// One capture, from the app in front to a row in the store. In order: the privacy gate for the app (pause, lock screen, deny lists),
/// the read of the focused window, the gate for the window (private browser window, address), the generic text walk, the screenshot
/// fallback when the walk finds no text and the user allowed it, and the store, which redacts and keeps only what is new.
final class CapturePipeline {
    enum Outcome: Equatable {
        case stored(id: Int64)
        /// Nothing in the window was new since its last capture.
        case unchanged
        case skipped(CaptureSkip)
    }

    let privacy: CapturePrivacy
    let store: CaptureStore
    var budget = CaptureReadBudget()

    init(privacy: CapturePrivacy, store: CaptureStore) {
        self.privacy = privacy
        self.store = store
    }

    func capture(app: CaptureApp, trigger: CaptureTrigger, source: CaptureSource, ocr: Bool, now: Date = Date()) -> Outcome {
        if let skip = privacy.checkApp(app, now: now) { return .skipped(skip) }
        guard var read = source.readFocusedWindow(of: app, budget: budget) else { return .skipped(.noWindow) }
        read.url = read.url ?? CaptureText.pageURL(in: read.root)
        if let skip = privacy.check(read, now: now) { return .skipped(skip) }
        var (lines, inputs) = CaptureText.read(in: read.root)
        if lines.isEmpty {
            // The tree has no text: a canvas, a game, a remote desktop or an app that does not expose its views. The screenshot is
            // read in memory and dropped, and only if the user turned this on.
            guard ocr, let recognized = source.recognizeFocusedWindow(of: app, windowID: read.windowID), !recognized.isEmpty else { return .skipped(.noText) }
            lines = recognized
            inputs = []
        }
        do {
            switch try store.ingest(app: read.app, title: read.title, url: read.url, trigger: trigger, lines: lines, inputLines: inputs, now: now) {
            case .stored(let id): return .stored(id: id)
            case .unchanged: return .unchanged
            case .empty: return .skipped(.noText)
            }
        } catch {
            NSLog("ironpet: could not store a capture: \(error.localizedDescription)")
            return .skipped(.noText)
        }
    }
}
