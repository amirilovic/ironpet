import XCTest
@testable import IronPet

final class ConfigTests: XCTestCase {
    private var file: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private func write(_ json: String) throws {
        try json.write(to: file, atomically: true, encoding: .utf8)
    }

    func testMissingFileGivesDefaults() {
        let (config, error) = Config.load(from: file)
        XCTAssertEqual(config, Config())
        XCTAssertNil(error)
    }

    func testDefaultsAreConservative() {
        let config = Config()
        XCTAssertFalse(config.integrations.githubAlerts)
        XCTAssertFalse(config.integrations.shareMCPSignIns)
        XCTAssertFalse(config.integrations.cursorHooks)
        XCTAssertFalse(config.integrations.claudeHooks)
    }

    func testPartialFileIsLaidOverDefaults() throws {
        try write(#"{"pet":{"name":"Mochi"},"reminders":{"water":{"minutes":30}}}"#)
        let (config, error) = Config.load(from: file)
        XCTAssertNil(error)
        XCTAssertEqual(config.pet.name, "Mochi")
        XCTAssertEqual(config.reminders.water.minutes, 30)
        XCTAssertTrue(config.reminders.water.enabled, "missing nested keys keep their defaults")
        XCTAssertEqual(config.reminders.eyes.minutes, 20)
        XCTAssertEqual(config.hotkeys, Config.Hotkeys())
    }

    func testBadValuesAreClamped() throws {
        try write(#"{"pet":{"name":"   "},"reminders":{"eyes":{"minutes":0},"snoozeMinutes":-3}}"#)
        let config = Config.load(from: file).config
        XCTAssertEqual(config.pet.name, "Ghost")
        XCTAssertEqual(config.reminders.eyes.minutes, 1)
        XCTAssertEqual(config.reminders.snoozeMinutes, 1)
    }

    func testWrongTypeFallsBackToDefaultsWithError() throws {
        try write(#"{"reminders":{"paused":"yes"}}"#)
        let (config, error) = Config.load(from: file)
        XCTAssertEqual(config, Config())
        XCTAssertTrue(error?.contains("reminders.paused") == true, error ?? "no error")
    }

    func testInvalidJSONFallsBackToDefaultsWithError() throws {
        try write("not json")
        let (config, error) = Config.load(from: file)
        XCTAssertEqual(config, Config())
        XCTAssertNotNil(error)
    }

    func testNullAndUnknownKeysAreAccepted() throws {
        try write(#"{"pet":{"sprite":null},"somethingNew":1}"#)
        let (config, error) = Config.load(from: file)
        XCTAssertNil(error)
        XCTAssertNil(config.pet.sprite)
    }

    func testSaveRoundTrips() throws {
        var config = Config()
        config.pet.sprite = "~/pets/sheet.png"
        config.hotkeys.captureRegion = ""
        config.integrations.cursorHooks = true
        try config.save(to: file)
        XCTAssertEqual(Config.load(from: file).config, config)
    }

    func testOldConfigWithoutVoiceKeysKeepsVoiceOff() throws {
        try write(#"{"pet":{"name":"Mochi"},"hotkeys":{"chat":"cmd+opt+h"}}"#)
        let (config, error) = Config.load(from: file)
        XCTAssertNil(error)
        XCTAssertEqual(config.voice, Config.Voice())
        XCTAssertFalse(config.voice.enabled)
        XCTAssertEqual(config.voice.baseUrl, "http://localhost:8000/v1")
        XCTAssertEqual(config.hotkeys.voice, "cmd+opt+v")
    }

    func testVoiceKeysRoundTrip() throws {
        var config = Config()
        config.voice = Config.Voice(enabled: true, baseUrl: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo")
        try config.save(to: file)
        XCTAssertEqual(Config.load(from: file).config, config)
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(saved.lowercased().contains("apikey"))
    }
}

final class ShortcutTests: XCTestCase {
    func testParsesAndDisplays() {
        XCTAssertEqual(Shortcut.display("cmd+opt+g"), "⌥⌘G")
        XCTAssertEqual(Shortcut.display("ctrl+shift+space"), "⌃⇧Space")
        XCTAssertEqual(Shortcut.display("Command + Option + G"), "⌥⌘G", "case and spaces don't matter")
        XCTAssertEqual(Shortcut.display("f5"), "F5")
        XCTAssertEqual(Shortcut.display("shift+f5"), "⇧F5")
    }

    func testRejectsShortcutsThatWouldHijackTyping() {
        XCTAssertNil(Shortcut("g"))
        XCTAssertNil(Shortcut("shift+a"), "Shift alone would swallow capital letters")
    }

    func testRejectsUnknownKeysAndModifiers() {
        XCTAssertNil(Shortcut(""))
        XCTAssertNil(Shortcut("cmd+foo"))
        XCTAssertNil(Shortcut("hyper+g"))
    }

    func testTextRoundTrips() {
        for text in ["cmd+opt+shift+g", "ctrl+opt+cmd+j", "cmd+f12", "opt+/"] {
            let shortcut = Shortcut(text)
            XCTAssertNotNil(shortcut, text)
            XCTAssertEqual(shortcut.flatMap { Shortcut($0.text) }, shortcut, text)
        }
    }
}
