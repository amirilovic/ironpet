import AppKit
import XCTest
@testable import IronPet

/// Drives the pet, the gallery, backgrounds and the asset manifest only through `IronPetAPI`, over temporary folders.
@MainActor
final class PetAPITests: XCTestCase {
    private var root: URL!
    private var events: APIEventBus!
    private var seen: [APIEvent] = []
    private var api: IronPetAPI!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-pet-api-\(UUID().uuidString)")
        for name in ["bundled", "pets", "backgrounds"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        events = APIEventBus()
        seen = []
        events.subscribe { [unowned self] in seen.append($0) }
        api = APITestSupport.makeAPI(events: events, petFolders: .init(library: root.appendingPathComponent("pets"), bundled: root.appendingPathComponent("bundled"),
                                                                       backgrounds: root.appendingPathComponent("backgrounds")))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func png(width: Int, height: Int, shade: UInt8 = 0) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        if let data = rep.bitmapData { data[0] = shade; data[3] = 255 }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    @discardableResult
    private func sheet(_ name: String, in folder: String, shade: UInt8 = 0) throws -> URL {
        let url = root.appendingPathComponent(folder).appendingPathComponent(name)
        try png(width: 1536, height: 2704, shade: shade).write(to: url)
        return url
    }

    func testStateAndTricksComeFromThePetWindow() throws {
        XCTAssertEqual(api.pet.state(), PetState(mood: "idle", badge: 0))
        api.pet.stateProvider = { PetState(mood: "needsInput", badge: 2) }
        api.pet.trickNames = { ["Wave", "Jump"] }
        var played: [String] = []
        api.pet.trickHandler = { name in played.append(name); return name == "Wave" }
        XCTAssertEqual(api.pet.state().badge, 2)
        XCTAssertEqual(api.pet.tricks(), ["Wave", "Jump"])
        try api.pet.perform(PerformTrickRequest(name: "Wave"))
        XCTAssertThrowsError(try api.pet.perform(PerformTrickRequest(name: "Moonwalk"))) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
        XCTAssertEqual(played, ["Wave", "Moonwalk"])
    }

    func testGalleryListsPetsAndSelectingOneChangesTheSetting() async throws {
        for name in PetLibrary.builtInNames { try sheet("\(name).png", in: "bundled") }
        try sheet("red-fox.png", in: "pets")
        let pets = await api.pet.pets()
        XCTAssertEqual(pets.map(\.name), ["Ghost", "Mochi", "Hamster", "Panda", "Bunny", "Cat", "Red fox"])
        XCTAssertEqual(pets.first { $0.selected }?.name, "Ghost", "an unset sprite means the bundled Ghost")
        XCTAssertEqual(pets.last?.builtIn, false)
        let fox = try XCTUnwrap(pets.last)
        try await api.pet.selectPet(SelectPetRequest(id: fox.id))
        XCTAssertEqual(api.settings.config.pet.sprite.map(PetLibrary.standardized), fox.id)
        XCTAssertEqual(api.settings.config.pet.name, "Red fox", "the name follows while it is still a default name")
        XCTAssertTrue(seen.contains { $0.kind == .settingsChanged })
        do { try await api.pet.selectPet(SelectPetRequest(id: "/nowhere.png")); XCTFail("selected a missing pet") } catch {
            XCTAssertEqual((error as? APIError)?.code, .notFound)
        }
    }

    func testImportingASheetCopiesItMakesItThePetAndPublishesAssetsChanged() throws {
        api.pet.checkAssets()
        let source = try sheet("mine.png", in: "bundled")
        let entry = try api.pet.importPet(source)
        XCTAssertEqual(entry.name, "Mine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("pets/mine.png").path))
        XCTAssertEqual(api.settings.config.pet.name, "Mine")
        XCTAssertTrue(seen.contains { $0.kind == .assetsChanged })
        let bad = root.appendingPathComponent("bundled/bad.png")
        try png(width: 10, height: 10).write(to: bad)
        XCTAssertThrowsError(try api.pet.importPet(bad)) { XCTAssertEqual(($0 as? APIError)?.code, .invalid) }
    }

    func testBackgroundsListSelectAndImport() throws {
        XCTAssertEqual(api.pet.backgroundList().first { $0.selected }?.id, "default")
        try api.pet.selectBackground(SelectBackgroundRequest(id: "dusk"))
        XCTAssertEqual(api.settings.config.chat.background, "dusk")
        XCTAssertThrowsError(try api.pet.selectBackground(SelectBackgroundRequest(id: "custom"))) { XCTAssertEqual(($0 as? APIError)?.code, .invalid) }
        XCTAssertThrowsError(try api.pet.selectBackground(SelectBackgroundRequest(id: "neon"))) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
        let image = root.appendingPathComponent("photo.png")
        try png(width: 40, height: 30).write(to: image)
        try api.pet.importBackground(image)
        XCTAssertEqual(api.settings.config.chat.background, "custom")
        let name = try XCTUnwrap(api.settings.config.chat.customImage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("backgrounds/\(name)").path))
        XCTAssertEqual(api.pet.backgroundList().first { $0.selected }?.id, "custom")
    }

    func testManifestHasContentHashesThatChangeWithTheFile() async throws {
        try sheet("ghost.png", in: "bundled", shade: 10)
        let fox = try sheet("fox.png", in: "pets", shade: 20)
        var manifest = await api.pet.manifest()
        XCTAssertEqual(manifest.assets.map(\.id), ["sprite:fox.png", "sprite:ghost.png"])
        let first = try XCTUnwrap(manifest.assets.first)
        XCTAssertEqual(first.sha256.count, 64)
        XCTAssertEqual(first.bytes, try Data(contentsOf: fox).count)
        // The same bytes always hash the same; rewriting the sheet changes the hash.
        let again = await api.pet.manifest()
        XCTAssertEqual(again, manifest)
        try png(width: 1536, height: 2704, shade: 99).write(to: fox)
        manifest = await api.pet.manifest()
        XCTAssertNotEqual(manifest.assets.first?.sha256, first.sha256)
    }

    func testAnAssetDownloadsByIdAndRefusesPathTricks() async throws {
        let fox = try sheet("fox.png", in: "pets")
        let data = try await api.pet.assetData("sprite:fox.png")
        XCTAssertEqual(data, try Data(contentsOf: fox))
        do { _ = try await api.pet.assetData("sprite:../secret.txt"); XCTFail("read outside the library") } catch {
            XCTAssertEqual((error as? APIError)?.code, .notFound)
        }
        do { _ = try await api.pet.assetData("sprite:nope.png"); XCTFail("read a missing sheet") } catch {
            XCTAssertEqual((error as? APIError)?.code, .notFound)
        }
    }

    func testAChangedSheetOnDiskPublishesAssetsChanged() throws {
        api.pet.checkAssets()
        XCTAssertFalse(seen.contains { $0.kind == .assetsChanged }, "the first check only records what is there")
        try sheet("new.png", in: "pets")
        api.pet.checkAssets()
        XCTAssertEqual(seen.filter { $0.kind == .assetsChanged }.count, 1)
        api.pet.checkAssets()
        XCTAssertEqual(seen.filter { $0.kind == .assetsChanged }.count, 1, "no change, no event")
    }

    func testManifestRoundTripsAsJSON() throws {
        let manifest = AssetManifest(assets: [AssetEntry(id: "sprite:a.png", kind: .sprite, name: "a.png", sha256: "ab", bytes: 3)])
        XCTAssertEqual(try JSONDecoder().decode(AssetManifest.self, from: JSONEncoder().encode(manifest)), manifest)
    }
}

/// The pet window is where the mood changes, so `pet.mood` is checked through `PetController`.
@MainActor
final class PetMoodEventTests: XCTestCase {
    func testAMoodChangePublishesPetMoodOnceAndFeedsTheState() {
        let bus = APIEventBus()
        var seen: [APIEvent] = []
        bus.subscribe { seen.append($0) }
        let signals = SignalStore()
        let pet = PetController(store: SessionStore(), signals: signals)
        pet.events = bus
        pet.refreshMood()
        let before = seen.count
        signals.add(Signal(id: "ci", title: "CI failed", subtitle: "", url: nil, label: "CI", symbol: "x", mood: .failed, ask: nil), notify: false)
        pet.refreshMood()
        XCTAssertEqual(seen.count, before + 1)
        XCTAssertEqual(seen.last?.kind, .petMood)
        XCTAssertEqual(seen.last?.id, "failed")
        XCTAssertEqual(pet.state, PetState(mood: "failed", badge: 1))
        pet.refreshMood()
        XCTAssertEqual(seen.count, before + 1, "the same mood publishes nothing")
    }
}
