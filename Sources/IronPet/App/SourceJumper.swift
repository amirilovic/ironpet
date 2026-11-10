import AppKit

/// Brings the terminal tab or Cursor window that owns a session to the front.
enum SourceJumper {
    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    static func jump(to session: AgentSession) {
        if let iterm = session.origin.itermSessionID, !iterm.isEmpty, focusItermSession(iterm) {
            // AppleScript `activate` can lose to another app taking focus; ask again through AppKit.
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").first?
                .activate(options: [.activateAllWindows])
            return
        }
        openInCursor(session.origin.workspace)
    }

    /// `ITERM_SESSION_ID` looks like `w0t1p0:<uuid>`; AppleScript exposes the uuid as the session id.
    private static func focusItermSession(_ raw: String) -> Bool {
        let uuid = raw.split(separator: ":").last.map(String.init) ?? raw
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if id of s is "\(uuid)" then
                  select w
                  select t
                  select s
                  activate
                  return true
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return false
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { NSLog("ironpet: iTerm jump failed \(error)") }
        return result?.booleanValue == true
    }

    private static func openInCursor(_ workspace: String?) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cursorBundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let workspace {
            NSWorkspace.shared.open([URL(fileURLWithPath: workspace)], withApplicationAt: app, configuration: config)
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: config)
        }
    }
}
