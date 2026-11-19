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

/// Backs the "Never treat as a call" list in Settings.
@MainActor
final class MicIgnoreModel: ObservableObject {
    /// An installed app found for a bundle id.
    struct AppInfo: Equatable {
        var name: String
        var url: URL
    }

    struct Row: Equatable, Identifiable {
        var bundleID: String
        var app: AppInfo?
        var id: String { bundleID }
        /// The app name, or the bundle id when the app is not installed.
        var title: String { app?.name ?? bundleID }
    }

    enum AddFailure: Equatable {
        case noIdentifier
        case rejected(MicIgnoreList.Rejection)

        var message: String {
            switch self {
            case .noIdentifier: return "This app has no identifier, so ironpet cannot ignore it."
            case .rejected(let reason): return reason.message
            }
        }
    }

    private let entries: () -> [String]
    private let save: ([String]) -> Void
    private let resolve: (String) -> AppInfo?
    private let ownBundleID: String?

    init(entries: @escaping () -> [String], save: @escaping ([String]) -> Void,
         resolve: @escaping (String) -> AppInfo? = MicIgnoreModel.installedApp,
         ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.entries = entries
        self.save = save
        self.resolve = resolve
        self.ownBundleID = ownBundleID
    }

    nonisolated static func installedApp(_ bundleID: String) -> AppInfo? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return AppInfo(name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name, url: url)
    }

    var rows: [Row] { entries().map { Row(bundleID: $0, app: resolve($0)) } }

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

    /// Adds the app bundle the user picked, by its CFBundleIdentifier.
    @discardableResult
    func add(appAt url: URL) -> AddFailure? {
        guard let id = Bundle(url: url)?.bundleIdentifier, !id.isEmpty else { return .noIdentifier }
        return add(id).map(AddFailure.rejected)
    }

    func remove(_ bundleID: String) {
        save(entries().filter { $0 != bundleID })
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
