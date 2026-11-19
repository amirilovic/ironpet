import AppKit
import Foundation

/// Rules for the user's "Never treat as a call" entries (`meetings.ignoredMicApps`). Entries are bundle id prefixes, like
/// the built-in list in `CallApps`.
enum MicIgnoreList {
    enum Rejection: Equatable, Error {
        case empty, tooShort, hasSpaces, alreadyBuiltIn, duplicate, ironpet

        var message: String {
            switch self {
            case .empty: return "Enter a bundle id."
            case .tooShort: return "Use a bundle id with at least two parts, like com.example.app. A shorter prefix would hide real calls."
            case .hasSpaces: return "A bundle id has no spaces."
            case .alreadyBuiltIn: return "ironpet already ignores this app."
            case .duplicate: return "This app is already in the list."
            case .ironpet: return "ironpet never counts its own microphone use."
            }
        }
    }

    /// The entry trimmed, or the reason it cannot be used.
    static func validate(_ entry: String, existing: [String] = [], ownBundleID: String? = nil) -> Result<String, Rejection> {
        let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .failure(.empty) }
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return .failure(.hasSpaces) }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count < 2 || parts.contains(where: \.isEmpty) { return .failure(.tooShort) }
        if let own = ownBundleID, own.caseInsensitiveCompare(value) == .orderedSame { return .failure(.ironpet) }
        if existing.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { return .failure(.duplicate) }
        if CallApps.isBuiltInIgnored(value) { return .failure(.alreadyBuiltIn) }
        return .success(value)
    }

    /// Keeps the valid entries in order and drops the rest, for a hand-edited config.json.
    static func normalized(_ entries: [String], ownBundleID: String? = nil) -> [String] {
        var kept: [String] = []
        for entry in entries {
            if case .success(let value) = validate(entry, existing: kept, ownBundleID: ownBundleID) { kept.append(value) }
        }
        return kept
    }
}

/// Apps seen holding the microphone since ironpet started, so Settings can offer them. Fed by every `CallMonitor` read.
@MainActor
final class RecentMicApps {
    static let shared = RecentMicApps()
    private var seen: [String: Date] = [:]
    private let limit = 50

    func note(_ clients: [MicClient], at date: Date = Date()) {
        for client in clients where !client.bundleID.isEmpty { seen[CallApps.parentBundleID(client.bundleID)] = date }
        if seen.count > limit {
            for key in seen.sorted(by: { $0.value < $1.value }).prefix(seen.count - limit).map(\.key) { seen[key] = nil }
        }
    }

    /// Most recent first.
    var bundleIDs: [String] { seen.sorted { $0.value > $1.value }.map(\.key) }
}

/// Backs the "Never treat as a call" list in Settings.
@MainActor
final class MicIgnoreModel: ObservableObject {
    struct Row: Equatable, Identifiable {
        var bundleID: String
        var name: String?
        var id: String { bundleID }
        var title: String { name.map { "\($0) (\(bundleID))" } ?? bundleID }
    }

    @Published private(set) var recent: [String]
    private let entries: () -> [String]
    private let save: ([String]) -> Void
    private let reader: @Sendable () -> [MicClient]
    private let nameFor: (String) -> String?
    private let ownBundleID: String?

    init(entries: @escaping () -> [String], save: @escaping ([String]) -> Void,
         recent: [String] = [], reader: @escaping @Sendable () -> [MicClient] = CoreAudioReader().read,
         nameFor: @escaping (String) -> String? = MicIgnoreModel.runningAppName,
         ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.entries = entries
        self.save = save
        self.recent = recent
        self.reader = reader
        self.nameFor = nameFor
        self.ownBundleID = ownBundleID
    }

    nonisolated static func runningAppName(_ bundleID: String) -> String? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame }?.localizedName
    }

    var rows: [Row] { entries().map { Row(bundleID: $0, name: nameFor($0)) } }

    /// Apps that held the microphone recently and would count as a call now, so they are worth ignoring.
    var suggestions: [Row] {
        let current = entries()
        var seen = Set<String>()
        return recent.compactMap { id -> Row? in
            let client = MicClient(pid: -1, bundleID: id)
            guard let app = CallApps.app(for: client, ownPID: 0, ownBundleID: ownBundleID, ignored: current),
                  seen.insert(app.lowercased()).inserted else { return nil }
            return Row(bundleID: app, name: nameFor(app))
        }
    }

    /// Adds an entry. Returns the reason it was refused, or nil.
    @discardableResult
    func add(_ entry: String) -> MicIgnoreList.Rejection? {
        switch MicIgnoreList.validate(entry, existing: entries(), ownBundleID: ownBundleID) {
        case .failure(let reason): return reason
        case .success(let value):
            save(entries() + [value])
            return nil
        }
    }

    func remove(_ bundleID: String) {
        save(entries().filter { $0 != bundleID })
    }

    /// Merges the apps holding the microphone right now and those seen earlier. The read runs off the main thread.
    func loadRecent() async {
        let reader = self.reader
        let live = await Task.detached { reader() }.value
        var ids: [String] = []
        for id in live.map({ CallApps.parentBundleID($0.bundleID) }) + RecentMicApps.shared.bundleIDs where !id.isEmpty && !ids.contains(id) {
            ids.append(id)
        }
        recent = ids
    }
}

/// The buttons on the "record this call?" bubble.
@MainActor
enum CallOffer {
    static func recordActions(bundleID: String, name: String, ignore: MicIgnoreModel, record: @escaping () -> Void,
                              notNow: @escaping () -> Void, close: @escaping () -> Void) -> [Bubble.Action] {
        [.init(title: "Record", style: .primary) {
            close()
            record()
        },
         .init(title: "Not now") {
            notNow()
            close()
        },
         .init(title: "Always ignore \(name)") {
            // The parent id, so the app's helper processes are covered. A refused entry (already ignored) still closes the offer.
            ignore.add(CallApps.parentBundleID(bundleID))
            close()
        }]
    }
}
