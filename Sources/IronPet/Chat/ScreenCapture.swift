import AppKit

/// Screenshots for screen-aware help, via the system `screencapture` tool.
/// Requires Screen Recording permission; without it macOS returns only the wallpaper.
enum ScreenCapture {
    static let directory = Paths.root.appendingPathComponent("screenshots")
    private static let keep = 30

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt (first time) or opens System Settings.
    static func requestPermission() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// Captures the frontmost window of `app` (call before ironpet activates).
    static func captureWindow(of app: NSRunningApplication?) async -> URL? {
        guard let pid = app?.processIdentifier else { return nil }
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let windowID = infos.first(where: {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        })?[kCGWindowNumber as String] as? Int else { return nil }
        return await run(["-x", "-o", "-l", String(windowID)])
    }

    /// Lets the user drag out a region. Returns nil if they press Escape.
    static func captureRegion() async -> URL? {
        await run(["-x", "-i"])
    }

    private static func run(_ args: [String]) async -> URL? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prune()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = directory.appendingPathComponent("screen-\(stamp).png")
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = args + [file.path]
            process.terminationHandler = { _ in
                continuation.resume(returning: FileManager.default.fileExists(atPath: file.path) ? file : nil)
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }

    private static func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for old in files.filter({ $0.pathExtension == "png" }).sorted(by: { $0.path > $1.path }).dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
