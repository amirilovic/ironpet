import AppKit

/// An app whose audio can be recorded as the "Them" track.
struct AudioApp: Equatable, Identifiable, Hashable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

enum AudioChoice: Equatable, Hashable {
    case app(AudioApp)
    case allSystemAudio

    /// What `Config.Meetings.lastApp` stores.
    var key: String {
        switch self {
        case .app(let app): return app.bundleID
        case .allSystemAudio: return AudioApps.allKey
        }
    }

    var name: String {
        switch self {
        case .app(let app): return app.name
        case .allSystemAudio: return "All system audio"
        }
    }
}

/// Which apps the source picker lists and which one it starts on.
enum AudioApps {
    static let allKey = "all"

    /// Meeting apps first, then browsers, each in the order they are preselected.
    static let meetingApps = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark", "com.webex.meetingmanager", "com.tinyspeck.slackmacgap", "com.apple.FaceTime",
    ]
    static let browsers = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac",
    ]

    /// Regular apps that are running, without ironpet itself, meeting apps first.
    static func running(ownBundleID: String? = Bundle.main.bundleIdentifier, ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> [AudioApp] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .compactMap { app -> AudioApp? in
                guard let id = app.bundleIdentifier else { return nil }
                return AudioApp(bundleID: id, name: app.localizedName ?? id)
            }
        return candidates(from: apps, ownBundleID: ownBundleID)
    }

    /// Drops ironpet and duplicates, and orders meeting apps, then browsers, then the rest by name.
    static func candidates(from apps: [AudioApp], ownBundleID: String?) -> [AudioApp] {
        var seen = Set<String>()
        let unique = apps.filter { $0.bundleID != ownBundleID && seen.insert($0.bundleID).inserted }
        let order = meetingApps + browsers
        return unique.sorted { a, b in
            let (ia, ib) = (order.firstIndex(of: a.bundleID) ?? order.count, order.firstIndex(of: b.bundleID) ?? order.count)
            if ia != ib { return ia < ib }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// A running meeting app wins, then the choice from last time if it is still available, then a running browser,
    /// then all system audio.
    static func preselect(from apps: [AudioApp], remembered: String) -> AudioChoice {
        if let app = meetingApps.lazy.compactMap({ id in apps.first { $0.bundleID == id } }).first { return .app(app) }
        if remembered == allKey { return .allSystemAudio }
        if let app = apps.first(where: { $0.bundleID == remembered }) { return .app(app) }
        if let app = browsers.lazy.compactMap({ id in apps.first { $0.bundleID == id } }).first { return .app(app) }
        return .allSystemAudio
    }
}
