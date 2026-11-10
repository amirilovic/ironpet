import AppKit

/// Guesses the folder the user is working in from the frontmost Cursor window or iTerm session.
enum WorkspaceDetector {
    /// Returns nil when the app is not a coding app (browser, Slack, …).
    static func workspace(of app: NSRunningApplication?) -> URL? {
        guard let app else { return nil }
        switch app.bundleIdentifier {
        case SourceJumper.cursorBundleID: return cursorWorkspace(pid: app.processIdentifier)
        case "com.googlecode.iterm2": return itermPath()
        default: return nil
        }
    }

    /// Matches the front Cursor window title against Cursor's list of open folders.
    /// Window titles need Screen Recording permission; without it, fall back to Cursor's last active window.
    private static func cursorWorkspace(pid: pid_t) -> URL? {
        let storage = Paths.home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/storage.json")
        guard let data = try? Data(contentsOf: storage),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = root["windowsState"] as? [String: Any] else { return nil }
        func folder(_ window: Any?) -> URL? {
            ((window as? [String: Any])?["folder"] as? String).flatMap(URL.init(string:))
        }
        let open = (windows["openedWindows"] as? [Any] ?? []).compactMap(folder)

        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let title = infos.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }?[kCGWindowName as String] as? String
        if let title {
            let parts = Set(title.components(separatedBy: " — ").map { $0.trimmingCharacters(in: .whitespaces) })
            if let match = open.first(where: { parts.contains($0.lastPathComponent) }) { return match }
        }
        return open.count == 1 ? open[0] : folder(windows["lastActiveWindow"])
    }

    private static func itermPath() -> URL? {
        let script = #"tell application "iTerm2" to tell current session of current window to get variable named "session.path""#
        var error: NSDictionary?
        guard let path = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
