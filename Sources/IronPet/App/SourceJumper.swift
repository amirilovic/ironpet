import AppKit

/// Brings the app that owns a session to the front, opening its folder there when the app can.
enum SourceJumper {
    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    @MainActor static func jump(to session: AgentSession) {
        open(Editors.target(for: session), folder: session.origin.workspace, itermSession: session.origin.itermSessionID)
    }

    static func open(_ target: OpenTarget, folder: String?, itermSession: String? = nil) {
        if target.bundleID == Editors.itermID, let iterm = itermSession, !iterm.isEmpty, focusItermSession(iterm) {
            // AppleScript `activate` can lose to another app taking focus; ask again through AppKit.
            NSRunningApplication.runningApplications(withBundleIdentifier: Editors.itermID).first?
                .activate(options: [.activateAllWindows])
            return
        }
        let folder = folder.flatMap { $0.isEmpty ? nil : $0 }
        if target.bundleID == Editors.finderID {
            if let folder { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }
            else { activate(bundleID: target.bundleID, opening: nil) }
            return
        }
        if let template = target.urlTemplate, let folder,
           let url = URL(string: Editors.expand(template, cwd: folder)),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
            return
        }
        activate(bundleID: target.bundleID, opening: target.folderFallback ? folder : nil)
    }

    private static func activate(bundleID: String, opening folder: String?) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let folder {
            NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: app, configuration: config)
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: config)
        }
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
}
