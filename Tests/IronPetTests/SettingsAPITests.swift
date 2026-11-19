import XCTest
@testable import IronPet

/// Drives settings only through `IronPetAPI`, over a config store that lives in memory and never touches `config.json`.
@MainActor
final class SettingsAPITests: XCTestCase {
    private var events: APIEventBus!
    private var seen: [APIEvent] = []
    private var api: IronPetAPI!

    override func setUp() async throws {
        events = APIEventBus()
        seen = []
        events.subscribe { [unowned self] in seen.append($0) }
        api = APITestSupport.makeAPI(events: events)
    }

    func testGetReturnsTheDefaults() {
        XCTAssertEqual(api.settings.get(), Config().sanitized())
    }

    func testPatchChangesNestedValuesAndKeepsTheRest() throws {
        let result = try api.settings.patch(PatchSettingsRequest(patch: #"{"pet": {"name": "Pip"}, "voice": {"enabled": true}}"#))
        XCTAssertEqual(result.pet.name, "Pip")
        XCTAssertTrue(result.voice.enabled)
        XCTAssertEqual(api.settings.config.voice.baseUrl, Config().voice.baseUrl, "keys not in the patch stay")
        XCTAssertEqual(api.settings.config.pet.name, "Pip")
    }

    func testPatchGoesThroughTheSameClampingAsLoading() throws {
        let result = try api.settings.patch(PatchSettingsRequest(patch: #"{"tasks": {"keepDoneDays": 9999}, "pet": {"name": "   "}, "speech": {"speed": 99}}"#))
        XCTAssertEqual(result.tasks.keepDoneDays, 365)
        XCTAssertEqual(result.pet.name, Config.Pet().name, "a blank name falls back to the default")
        XCTAssertEqual(result.speech.speed, Config.Speech.speedRange.upperBound)
    }

    func testSwiftUpdateTakesTheSameValidation() {
        api.settings.update { $0.tasks.keepDoneDays = 0 }
        XCTAssertEqual(api.settings.config.tasks.keepDoneDays, 1)
    }

    func testAnUnknownKeyOrAWrongTypeChangesNothing() throws {
        _ = try api.settings.patch(PatchSettingsRequest(patch: #"{"pet": {"name": "Pip"}}"#))
        XCTAssertThrowsError(try api.settings.patch(PatchSettingsRequest(patch: #"{"pet": {"name": "Zed"}, "voice": {"nope": 1}}"#))) {
            XCTAssertEqual(($0 as? APIError)?.code, .invalid)
            XCTAssertTrue(($0 as? APIError)?.message.contains("voice.nope") == true)
        }
        XCTAssertThrowsError(try api.settings.patch(PatchSettingsRequest(patch: #"{"tasks": {"keepDoneDays": "many"}}"#))) {
            XCTAssertEqual(($0 as? APIError)?.code, .invalid)
        }
        XCTAssertThrowsError(try api.settings.patch(PatchSettingsRequest(patch: "[1]"))) { XCTAssertEqual(($0 as? APIError)?.code, .invalid) }
        XCTAssertEqual(api.settings.config.pet.name, "Pip", "a rejected patch leaves the settings as they were")
    }

    func testNullRestoresTheDefaultAndOptionalSettingsCanBeSet() throws {
        _ = try api.settings.patch(PatchSettingsRequest(patch: #"{"pet": {"name": "Pip"}, "meetings": {"summaryModel": "fast"}}"#))
        XCTAssertEqual(api.settings.config.meetings.summaryModel, "fast")
        _ = try api.settings.patch(PatchSettingsRequest(patch: #"{"pet": {"name": null}}"#))
        XCTAssertEqual(api.settings.config.pet.name, Config.Pet().name)
    }

    func testMemoryReflectAgentAndModelCanBeSetOnADefaultConfig() throws {
        let result = try api.settings.patch(PatchSettingsRequest(patch: #"{"memory": {"reflectAgent": "claude", "reflectModel": "fast"}}"#))
        XCTAssertEqual(result.memory.reflectAgent, "claude")
        XCTAssertEqual(result.memory.reflectModel, "fast")
    }

    func testChangesPublishSettingsChangedOncePerChange() throws {
        _ = try api.settings.patch(PatchSettingsRequest(patch: #"{"pet": {"name": "Pip"}}"#))
        _ = try api.settings.patch(PatchSettingsRequest(patch: #"{"pet": {"name": "Pip"}}"#))
        api.settings.update { $0.reminders.paused = true }
        XCTAssertEqual(seen.map(\.kind), [.settingsChanged, .settingsChanged], "a patch that changes nothing publishes nothing")
    }

    func testRequestRoundTripsAsJSON() throws {
        let request = PatchSettingsRequest(patch: #"{"a": 1}"#)
        XCTAssertEqual(try JSONDecoder().decode(PatchSettingsRequest.self, from: JSONEncoder().encode(request)), request)
        let config = api.settings.get()
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config)), config)
    }
}
