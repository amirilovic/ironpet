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

    func testScreenCaptureIsOffByDefaultAndSendsNothingUntilAppsAreAllowed() throws {
        let defaults = Config().screenCapture
        XCTAssertFalse(defaults.enabled)
        XCTAssertTrue(defaults.sendApps.isEmpty)
        XCTAssertEqual(defaults.delayMinutes, 3)
        XCTAssertEqual(defaults.retentionDays, 30)
        XCTAssertEqual(defaults.decision.secretThreshold, 0.6)
        XCTAssertEqual(defaults.decision.calendarThreshold, 0.2)
        XCTAssertEqual(defaults.decision.skipThreshold, 0)
        try write(#"{"screenCapture":{"enabled":true,"delayMinutes":0,"retentionDays":9999,"decision":{"secretThreshold":7}}}"#)
        let (config, error) = Config.load(from: file)
        XCTAssertNil(error)
        XCTAssertTrue(config.screenCapture.enabled)
        XCTAssertEqual(config.screenCapture.delayMinutes, 0.5, "clamped")
        XCTAssertEqual(config.screenCapture.retentionDays, 365)
        XCTAssertEqual(config.screenCapture.decision.secretThreshold, 1)
        XCTAssertEqual(config.screenCapture.decision.api, "systemone", "other keys keep their defaults")
    }

    func testAFreshConfigDefaultsTheSecretThresholdTo0Point6() throws {
        try write("{}")
        let loaded = Config.load(from: file).config.screenCapture.decision
        XCTAssertEqual(loaded.secretThreshold, 0.6)
        XCTAssertEqual(loaded.calendarThreshold, 0.2)
        XCTAssertEqual(loaded.skipThreshold, 0)
        try write(#"{"screenCapture":{"decision":{"secretThreshold":0.2}}}"#)
        XCTAssertEqual(Config.load(from: file).config.screenCapture.decision.secretThreshold, 0.2, "a stored value is kept")
    }

    func testEveryDecisionThresholdIsClampedToZeroToOne() throws {
        try write(#"{"screenCapture":{"decision":{"secretThreshold":-3,"calendarThreshold":1.5,"skipThreshold":9}}}"#)
        let decision = Config.load(from: file).config.screenCapture.decision
        XCTAssertEqual(decision.secretThreshold, 0)
        XCTAssertEqual(decision.calendarThreshold, 1)
        XCTAssertEqual(decision.skipThreshold, 1)
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

    func testPasteLimitsDefaultAndAreClamped() throws {
        XCTAssertEqual(Config().chat.pasteAttachmentChars, 4_000)
        XCTAssertEqual(Config().chat.pasteAttachmentLines, 60)
        try write(#"{"chat":{"pasteAttachmentChars":10,"pasteAttachmentLines":99999}}"#)
        var (config, _) = Config.load(from: file)
        XCTAssertEqual(config.chat.pasteAttachmentChars, 500)
        XCTAssertEqual(config.chat.pasteAttachmentLines, 2_000)
        try write(#"{"chat":{"pasteAttachmentChars":1000000,"pasteAttachmentLines":1}}"#)
        (config, _) = Config.load(from: file)
        XCTAssertEqual(config.chat.pasteAttachmentChars, 100_000)
        XCTAssertEqual(config.chat.pasteAttachmentLines, 10)
        try write(#"{"chat":{"pasteAttachmentChars":1500}}"#)
        (config, _) = Config.load(from: file)
        XCTAssertEqual(config.chat.pasteAttachmentChars, 1_500)
        XCTAssertEqual(config.chat.pasteAttachmentLines, 60)
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

    func testOldConfigWithoutMeetingKeysKeepsMeetingsOff() throws {
        try write(#"{"voice":{"enabled":true},"hotkeys":{"chat":"cmd+opt+x"}}"#)
        let config = Config.load(from: file).config
        XCTAssertEqual(config.meetings, Config.Meetings())
        XCTAssertFalse(config.meetings.enabled)
        XCTAssertEqual(config.meetings.summaryAgent, "claude")
        XCTAssertTrue(config.meetings.autoSummary)
        XCTAssertEqual(config.hotkeys.meeting, "")
    }

    func testMeetingKeysRoundTrip() throws {
        var config = Config()
        config.meetings = Config.Meetings(enabled: true, lastApp: "us.zoom.xos", summaryAgent: "cursor",
                                          summaryModel: "gpt-5", autoSummary: false)
        config.hotkeys.meeting = "cmd+opt+m"
        try config.save(to: file)
        XCTAssertEqual(Config.load(from: file).config, config)
    }

    func testBlankSummaryModelMeansDefault() throws {
        try write(#"{"meetings":{"summaryModel":"  "}}"#)
        XCTAssertNil(Config.load(from: file).config.meetings.summaryModel)
    }

    func testTaskDefaults() {
        let tasks = Config().tasks
        XCTAssertTrue(tasks.meetingSuggestions)
        XCTAssertTrue(tasks.dueReminders)
        XCTAssertEqual(tasks.keepDoneDays, 30)
    }

    func testDueRemindersCanBeTurnedOff() throws {
        try write(#"{"tasks":{"dueReminders":false}}"#)
        let config = Config.load(from: file).config
        XCTAssertFalse(config.tasks.dueReminders)
        XCTAssertTrue(config.tasks.meetingSuggestions)
    }

    func testWelcomeBackIsOnByDefaultAndForOldFiles() throws {
        XCTAssertTrue(Config().welcomeBack.enabled)
        try write(#"{"tasks":{"dueReminders":false}}"#)
        XCTAssertTrue(Config.load(from: file).config.welcomeBack.enabled)
    }

    func testWelcomeBackCanBeTurnedOff() throws {
        try write(#"{"welcomeBack":{"enabled":false}}"#)
        let (config, error) = Config.load(from: file)
        XCTAssertNil(error)
        XCTAssertFalse(config.welcomeBack.enabled)
        XCTAssertEqual(config.reminders, Config.Reminders())
    }

    func testKeepDoneDaysIsClamped() throws {
        try write(#"{"tasks":{"keepDoneDays":0}}"#)
        XCTAssertEqual(Config.load(from: file).config.tasks.keepDoneDays, 1)
        try write(#"{"tasks":{"keepDoneDays":1000}}"#)
        XCTAssertEqual(Config.load(from: file).config.tasks.keepDoneDays, 365)
    }

    func testPartialTasksKeepOtherDefaults() throws {
        try write(#"{"tasks":{"meetingSuggestions":false}}"#)
        let (config, error) = Config.load(from: file)
        XCTAssertNil(error)
        XCTAssertFalse(config.tasks.meetingSuggestions)
        XCTAssertEqual(config.tasks.keepDoneDays, 30)
        XCTAssertEqual(config.meetings, Config.Meetings())
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
