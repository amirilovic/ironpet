import Combine
import Foundation

/// A JSON merge patch (RFC 7386) over the settings: objects merge, any other value replaces, `null` restores the default.
struct PatchSettingsRequest: Codable, Equatable {
    var patch: String
}

/// The settings in `config.json`: get, patch, and the `settings.changed` event. Every client changes settings through
/// the one validation path (`Config.sanitized`), so no client can store a value another would reject.
///
/// This is an `ObservableObject` so the Settings pages redraw when a setting changes, here or by a hand edit of the file.
@MainActor
final class SettingsAPI: ObservableObject {
    /// The running app's settings, for views deep in the tree that read one value. `IronPetAPI` sets it to its own, so there is
    /// one instance.
    static var live = SettingsAPI(store: .shared)

    private let store: ConfigStore
    private var forwarding: AnyCancellable?

    init(store: ConfigStore) {
        self.store = store
        forwarding = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var config: Config { store.config }
    /// Why `config.json` could not be read or saved, when it could not.
    var error: String? { store.error }

    func get() -> Config { store.config }

    /// Applies a merge patch. The whole patch is checked first: a key that is not a setting, or a value of the wrong type, changes nothing.
    @discardableResult
    func patch(_ request: PatchSettingsRequest) throws -> Config {
        guard let patch = (try? JSONSerialization.jsonObject(with: Data(request.patch.utf8))) as? [String: Any] else {
            throw APIError.invalid("the patch must be a JSON object")
        }
        let current: [String: Any]
        let defaults: [String: Any]
        do {
            current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.config)) as? [String: Any] ?? [:]
            defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any] ?? [:]
        } catch {
            throw APIError.failed(error.localizedDescription)
        }
        if let unknown = Self.unknownKey(patch, in: current) { throw APIError.invalid("\"\(unknown)\" is not a setting") }
        let merged = Self.apply(patch, to: current, defaults: defaults)
        let next: Config
        do {
            next = try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: merged)).sanitized()
        } catch {
            throw APIError.invalid(Config.describe(error))
        }
        store.update { $0 = next }
        if let reason = store.error, store.config != next { throw APIError.failed(reason) }
        return store.config
    }

    /// The same change as `patch`, written as Swift for the Settings pages. It takes the same validation and event.
    func update(_ change: (inout Config) -> Void) { store.update(change) }

    /// Picks up a hand edit of `config.json` now instead of at the next check.
    func reloadIfChanged() { store.reloadIfChanged() }

    // MARK: Merge patch

    /// The first path in `patch` that names no setting, such as `voice.nope`.
    private static func unknownKey(_ patch: [String: Any], in current: [String: Any], prefix: String = "") -> String? {
        for (key, value) in patch {
            guard let existing = current[key] else {
                // A key the encoder left out: an optional setting that is unset. It is valid only if it is one the config declares.
                if Config.optionalKeys.contains(prefix + key) { continue }
                return prefix + key
            }
            if let nested = value as? [String: Any], let base = existing as? [String: Any],
               let unknown = unknownKey(nested, in: base, prefix: prefix + key + ".") { return unknown }
        }
        return nil
    }

    private static func apply(_ patch: [String: Any], to base: [String: Any], defaults: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in patch {
            if value is NSNull {
                result[key] = defaults[key]
            } else if let nested = value as? [String: Any], let old = base[key] as? [String: Any] {
                result[key] = apply(nested, to: old, defaults: defaults[key] as? [String: Any] ?? [:])
            } else {
                result[key] = value
            }
        }
        return result
    }
}
