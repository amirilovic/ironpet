import Foundation

/// Why a window was not stored.
enum CaptureSkip: Error, Equatable, CustomStringConvertible {
    case paused
    /// A private browser window.
    case privateWindow
    case locked
    case deniedApp(String)
    case deniedHost(String)
    /// A URL that may not be stored: malformed, without a host, a local or browser-internal scheme, or anything but http(s) in a
    /// browser. Fails closed.
    case unsafeURL
    case noWindow
    /// The window has no readable text, and the screenshot fallback is off or not allowed.
    case noText

    var description: String {
        switch self {
        case .paused: return "paused"
        case .privateWindow: return "a private browser window"
        case .locked: return "the screen is locked"
        case .deniedApp(let app): return "app \(app) is on the deny list"
        case .deniedHost(let host): return "host \(host) is on the deny list"
        case .unsafeURL: return "the url is not an address ironpet may store"
        case .noWindow: return "no window to read"
        case .noText: return "nothing readable in the window"
        }
    }
}

/// The hard floor: Swift checks that run no matter what a setting says. The user's deny list adds to it and cannot remove from it.
enum CaptureFloor {
    /// Exact bundle ids, or a fragment to look for inside the lowercase bundle id.
    static let appFragments = [
        "1password", "onepassword", "bitwarden", "lastpass", "dashlane", "keepersecurity", "keepassxc", "enpass", "me.proton.pass",
        "com.apple.keychainaccess", "com.apple.passwords", "com.apple.loginwindow", "com.apple.securityagent",
        "com.apple.accessibility.universalaccessauthwarn", "com.apple.usernotificationcenter", "com.apple.systempreferences",
        "com.okta.mobile", "authy", "com.proxyman", "com.xk72.charles",
    ]

    /// "example.com" or "*.example.com" (the host and everything below it).
    static let hostPatterns = ["*.1password.com", "*.bitwarden.com", "*.lastpass.com", "*.dashlane.com", "*.keepersecurity.com", "pass.proton.me"]

    /// Never stored from any app: local files, inline documents and browser-internal pages.
    static let blockedSchemes: Set<String> = [
        "file", "data", "javascript", "blob", "about", "view-source", "chrome", "chrome-extension", "chrome-untrusted", "devtools", "edge",
        "brave", "vivaldi", "opera", "arc", "moz-extension", "resource", "safari-web-extension", "webkit-extension",
    ]

    /// Browsers, lowercase. Only http(s) pages are stored from these.
    static let browsers: Set<String> = [
        "com.apple.safari", "com.apple.safaritechnologypreview", "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.dev",
        "com.google.chrome.canary", "org.chromium.chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.beta", "com.microsoft.edgemac.dev",
        "com.brave.browser", "com.brave.browser.beta", "com.brave.browser.nightly", "company.thebrowser.browser", "company.thebrowser.dia",
        "com.vivaldi.vivaldi", "com.operasoftware.opera", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "app.zen-browser.zen", "com.kagi.kagimacos", "com.duckduckgo.macos.browser",
    ]

    static func isBrowser(_ bundleId: String) -> Bool { browsers.contains(bundleId.lowercased()) }

    static func deniesApp(_ bundleId: String) -> Bool {
        let lower = bundleId.lowercased()
        return appFragments.contains { lower.contains($0) }
    }

    static func deniesHost(_ host: String) -> Bool {
        hostPatterns.contains { CaptureURL.hostMatches(host, $0) }
    }

    /// A URL needs a host. In a browser it must be http(s), so local files and settings pages stay out. Other apps that render their UI
    /// in a web view (Electron, Tauri) may use their own scheme, but never a local, inline or browser-internal one.
    static func checkURL(bundleId: String, raw: String) -> CaptureSkip? {
        guard let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased(), !scheme.isEmpty else { return .unsafeURL }
        let web = scheme == "http" || scheme == "https"
        if !web && (isBrowser(bundleId) || blockedSchemes.contains(scheme)) { return .unsafeURL }
        guard let host = components.host, !host.isEmpty else { return .unsafeURL }
        if deniesHost(host) { return .deniedHost(host.lowercased()) }
        return nil
    }
}

/// The user-controlled capture state: pause and the deny list. Shared across threads. The master switch lives in
/// `CaptureService`; this is what the pet menu changes.
final class CapturePrivacy {
    private let lock = NSLock()
    private var pausedUntil: Date?
    private var excludedApps: Set<String> = []
    /// Set by the service from the lock screen and screensaver state.
    private var screenLocked = false

    func pause(for seconds: TimeInterval, now: Date = Date()) {
        lock.lock()
        pausedUntil = now.addingTimeInterval(seconds)
        lock.unlock()
    }

    /// Pauses until 06:00 the next local morning.
    func pauseUntilTomorrow(now: Date = Date(), calendar: Calendar = .current) {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86400)
        lock.lock()
        pausedUntil = tomorrow.addingTimeInterval(6 * 3600)
        lock.unlock()
    }

    func resume() {
        lock.lock()
        pausedUntil = nil
        lock.unlock()
    }

    func setScreenLocked(_ locked: Bool) {
        lock.lock()
        screenLocked = locked
        lock.unlock()
    }

    func setExcluded(_ apps: [String]) {
        lock.lock()
        excludedApps = Set(apps)
        lock.unlock()
    }

    func isPaused(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let until = pausedUntil, until <= now { pausedUntil = nil }
        return pausedUntil != nil
    }

    var pausedUntilDate: Date? {
        lock.lock()
        defer { lock.unlock() }
        return pausedUntil
    }

    /// Pause, lock screen, user exclusions and the hard-coded app denylist. Needs only the app, so a stopped or excluded
    /// app is never touched through the accessibility API.
    func checkApp(_ app: CaptureApp, now: Date = Date()) -> CaptureSkip? {
        if isPaused(now: now) { return .paused }
        lock.lock()
        let isLocked = screenLocked, excluded = excludedApps
        lock.unlock()
        if isLocked { return .locked }
        if CaptureFloor.deniesApp(app.bundleId) { return .deniedApp(app.bundleId) }
        if excluded.contains(app.bundleId) || excluded.contains(where: { $0.caseInsensitiveCompare(app.name) == .orderedSame }) {
            return .deniedApp(app.bundleId)
        }
        return nil
    }

    /// Title words that mark a private browser window. A browser does not say so any other way through accessibility.
    static let privateWindowMarkers = ["private browsing", "incognito", "inprivate", "(private)", "— private", "- private", "private window"]

    func isPrivateWindow(app: CaptureApp, title: String?) -> Bool {
        guard CaptureFloor.isBrowser(app.bundleId) || app.bundleId.lowercased().contains("browser") else { return false }
        let lower = (title ?? "").lowercased()
        return Self.privateWindowMarkers.contains { lower.contains($0) }
    }

    /// The checks that need the window: a private browser window, and the address.
    func check(_ read: WindowRead, now: Date = Date()) -> CaptureSkip? {
        if let skip = checkApp(read.app, now: now) { return skip }
        if isPrivateWindow(app: read.app, title: read.title) { return .privateWindow }
        if let url = read.url { return CaptureFloor.checkURL(bundleId: read.app.bundleId, raw: url) }
        return nil
    }
}
