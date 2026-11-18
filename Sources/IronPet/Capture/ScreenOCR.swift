import AppKit
import ScreenCaptureKit
import Vision

/// Reads the text of a window's screenshot on this Mac with Apple Vision. The image lives in memory only: it is never written to a file,
/// and it is dropped when the function returns.
enum ScreenOCR {
    /// Lines of text in an image, top to bottom and then left to right.
    static func recognize(_ image: CGImage) -> [String]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Names are not dictionary words, and correction would turn a surname into dictionary words.
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
        var lines: [(top: Double, left: Double, text: String)] = []
        for observation in request.results ?? [] {
            guard let best = observation.topCandidates(1).first else { continue }
            let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let box = observation.boundingBox
            lines.append((1 - (box.origin.y + box.size.height), box.origin.x, text))
        }
        lines.sort { abs($0.top - $1.top) < 0.02 ? $0.left < $1.left : $0.top < $1.top }
        return lines.map(\.text)
    }

    /// A screenshot of the window `id`, which must belong to `pid`, taken without writing a file. Blocks the calling thread, so it must not be the main one.
    static func screenshot(ofWindow id: CGWindowID, ownedBy pid: pid_t, timeout: TimeInterval = 3) -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let done = DispatchSemaphore(value: 0)
        let box = ImageBox()
        Task.detached {
            defer { done.signal() }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
                  let window = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID == pid && $0.frame.width > 1 }) else { return }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * 2)
            configuration.height = Int(window.frame.height * 2)
            configuration.showsCursor = false
            box.image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.image
    }

    private final class ImageBox: @unchecked Sendable { var image: CGImage? }

    /// The text of window `id`: screenshot, recognize, drop the image.
    static func recognizeWindow(id: CGWindowID, ownedBy pid: pid_t) -> [String]? {
        guard let image = screenshot(ofWindow: id, ownedBy: pid) else { return nil }
        return recognize(image)
    }
}
