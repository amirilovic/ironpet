import CryptoKit
import Foundation

struct PetState: Codable, Equatable {
    /// The mood the pet shows, such as `idle`, `working`, `needsInput`.
    var mood: String
    /// How many sessions and alerts share the mood.
    var badge: Int
}

struct PetInfo: Codable, Equatable, Identifiable {
    /// The sheet's standardized file path. Pass it back to `selectPet`.
    var id: String
    var name: String
    var builtIn: Bool
    var selected: Bool
}

struct SelectPetRequest: Codable, Equatable {
    var id: String
}

struct PerformTrickRequest: Codable, Equatable {
    /// One of the names `tricks()` lists, such as "Wave".
    var name: String
}

struct BackgroundInfo: Codable, Equatable, Identifiable {
    /// `default`, a built-in id such as `dusk`, or `custom`.
    var id: String
    var name: String
    var selected: Bool
}

struct SelectBackgroundRequest: Codable, Equatable {
    var id: String
}

enum AssetKind: String, Codable {
    case sprite, background
}

/// One file a client can download and cache. Compare `sha256` with the copy it holds to know whether it is stale.
struct AssetEntry: Codable, Equatable, Identifiable {
    /// `sprite:<file name>` or `background:<file name>`.
    var id: String
    var kind: AssetKind
    var name: String
    var sha256: String
    var bytes: Int
}

struct AssetManifest: Codable, Equatable {
    var assets: [AssetEntry]
}

/// The pet and how the app looks: the pet's mood and tricks, the gallery of sprite sheets, chat backgrounds, and a manifest of
/// the files behind them with content hashes, so a client can download each one once and keep it.
@MainActor
final class PetAPI {
    private let settings: SettingsAPI
    private let library: URL
    private let bundled: URL?
    private let backgrounds: URL
    private var assetSignature: [String]?
    weak var events: APIEventBus?

    /// The running app's pet API, for the Settings pages. `IronPetAPI` sets it to its own, so there is one instance.
    static var live = PetAPI(settings: .live)

    /// The pet's current mood and badge. The pet window supplies it.
    var stateProvider: () -> PetState = { PetState(mood: "idle", badge: 0) }
    /// Plays a trick by name. The pet window supplies it. Returns false for a name it does not know.
    var trickHandler: (String) -> Bool = { _ in false }
    /// The tricks the pet knows, in menu order.
    var trickNames: () -> [String] = { [] }

    init(settings: SettingsAPI, library: URL = PetLibrary.folder, bundled: URL? = PetLibrary.bundledFolder,
         backgrounds: URL = ChatBackground.folder) {
        self.settings = settings
        self.library = library
        self.bundled = bundled
        self.backgrounds = backgrounds
    }

    // MARK: Mood and tricks

    func state() -> PetState { stateProvider() }

    func tricks() -> [String] { trickNames() }

    func perform(_ request: PerformTrickRequest) throws {
        guard trickHandler(request.name) else { throw APIError.notFound("the pet does not know \"\(request.name)\"") }
    }

    // MARK: Gallery

    /// The pets in the gallery, built-in ones first. Reads the sheets off the main thread, so it can take a moment.
    func pets() async -> [PetInfo] {
        let (library, bundled, current) = (library, bundled, settings.config.pet.sprite)
        let entries = await Task.detached { PetLibrary.entries(bundled: bundled, library: library, current: current) }.value
        let selected = PetLibrary.selectedID(in: entries, sprite: current)
        return entries.map { entry in
            PetInfo(id: entry.id, name: entry.name, builtIn: PetLibrary.builtInNames.contains(entry.url.deletingPathExtension().lastPathComponent.lowercased()),
                    selected: entry.id == selected)
        }
    }

    func selectPet(_ request: SelectPetRequest) async throws {
        let (library, bundled, current) = (library, bundled, settings.config.pet.sprite)
        let entries = await Task.detached { PetLibrary.entries(bundled: bundled, library: library, current: current) }.value
        guard let entry = entries.first(where: { $0.id == request.id }) else { throw APIError.notFound("no pet with id \"\(request.id)\"") }
        select(entry)
    }

    /// Makes a gallery entry the pet.
    func select(_ entry: PetEntry) { settings.update { PetLibrary.select(entry, in: &$0) } }

    /// Copies a sprite sheet into the pet library and makes it the pet.
    @discardableResult
    func importPet(_ source: URL) throws -> PetEntry {
        let copy: URL
        do { copy = try PetLibrary.importSheet(source, into: library) } catch { throw APIError.invalid(error.localizedDescription) }
        guard let atlas = Atlas.load(copy) else { throw APIError.invalid("\(source.lastPathComponent) isn't a sprite sheet in the expected layout.") }
        let name = PetLibrary.displayName(forStem: copy.deletingPathExtension().lastPathComponent)
        let entry = PetEntry(id: PetLibrary.standardized(copy.path), name: name, url: copy, atlas: atlas)
        select(entry)
        checkAssets()
        return entry
    }

    // MARK: Backgrounds

    func backgroundList() -> [BackgroundInfo] {
        let current = settings.config.chat.background
        var list = [BackgroundInfo(id: ChatBackground.defaultID, name: "Default", selected: current == ChatBackground.defaultID)]
        list += ChatBackground.builtIns.map { BackgroundInfo(id: $0.id, name: $0.name, selected: current == $0.id) }
        list.append(BackgroundInfo(id: ChatBackground.customID, name: "Custom image", selected: current == ChatBackground.customID))
        return list
    }

    func selectBackground(_ request: SelectBackgroundRequest) throws {
        if request.id == ChatBackground.customID {
            guard settings.config.chat.customImage != nil else { throw APIError.invalid("no custom image has been added yet") }
        } else if request.id != ChatBackground.defaultID, ChatBackground.builtIn(request.id) == nil {
            throw APIError.notFound("no background with id \"\(request.id)\"")
        }
        settings.update { $0.chat.background = request.id }
    }

    /// Copies an image into the backgrounds folder and makes it the chat background. The previous custom image is removed.
    func importBackground(_ source: URL) throws {
        do {
            let name = try ChatBackground.importImage(from: source, into: backgrounds, replacing: settings.config.chat.customImage)
            settings.update { $0.chat.background = ChatBackground.customID; $0.chat.customImage = name }
            checkAssets()
        } catch {
            throw APIError.invalid(error.localizedDescription)
        }
    }

    // MARK: Assets

    /// Every file a client can download: the pet sheets and the custom background image. The built-in backgrounds are
    /// drawn from their ids, so they have no file.
    func manifest() async -> AssetManifest {
        let (library, bundled, backgrounds, custom) = (library, bundled, backgrounds, settings.config.chat.customImage)
        let assets = await Task.detached { () -> [AssetEntry] in
            var byName: [String: URL] = [:]
            for url in PetLibrary.sheetFiles(in: bundled) { byName[url.lastPathComponent] = url }
            // A sheet in the user's folder replaces a bundled one of the same name.
            for url in PetLibrary.sheetFiles(in: library) { byName[url.lastPathComponent] = url }
            var entries = byName.keys.sorted().compactMap { Self.entry(.sprite, byName[$0]!) }
            if let custom, let image = Self.entry(.background, backgrounds.appendingPathComponent(custom)) { entries.append(image) }
            return entries
        }.value
        return AssetManifest(assets: assets)
    }

    /// The bytes of an asset from `manifest`.
    func assetData(_ id: String) async throws -> Data {
        let manifest = await manifest()
        guard manifest.assets.contains(where: { $0.id == id }) else { throw APIError.notFound("no asset with id \"\(id)\"") }
        let (library, bundled, backgrounds) = (library, bundled, backgrounds)
        guard let url = Self.url(for: id, library: library, bundled: bundled, backgrounds: backgrounds),
              let data = try? Data(contentsOf: url) else { throw APIError.failed("the asset could not be read") }
        return data
    }

    /// Publishes `assets.changed` when a sheet or the custom image was added, removed or rewritten since the last check.
    func checkAssets() {
        let now = signature()
        guard now != assetSignature else { return }
        let first = assetSignature == nil
        assetSignature = now
        if !first { events?.publish(.assetsChanged) }
    }

    private func signature() -> [String] {
        PetFolderSignature(folder: library).items + (bundled.map { PetFolderSignature(folder: $0).items } ?? [])
            + ((try? FileManager.default.contentsOfDirectory(atPath: backgrounds.path)) ?? []).sorted().map { "bg|\($0)" }
    }

    nonisolated private static func entry(_ kind: AssetKind, _ url: URL) -> AssetEntry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return AssetEntry(id: "\(kind.rawValue):\(url.lastPathComponent)", kind: kind, name: url.lastPathComponent, sha256: hash, bytes: data.count)
    }

    nonisolated private static func url(for id: String, library: URL, bundled: URL?, backgrounds: URL) -> URL? {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].contains("/") else { return nil }
        switch parts[0] {
        case "sprite":
            let user = library.appendingPathComponent(parts[1])
            if FileManager.default.fileExists(atPath: user.path) { return user }
            return bundled?.appendingPathComponent(parts[1])
        case "background": return backgrounds.appendingPathComponent(parts[1])
        default: return nil
        }
    }
}
