import XCTest
@testable import IronPet

@MainActor
final class VoiceToggleTests: XCTestCase {
    private var clip: URL!
    private var voice: VoiceController!
    private var transcriptions = 0

    override func setUp() async throws {
        clip = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let samples = (0..<(WAV.sampleRate * 3)).map { Int16(sin(Double($0) * 2 * .pi * 440 / Double(WAV.sampleRate)) * 3000) }
        try WAV.encode(samples).write(to: clip)
        voice = VoiceController()
        voice.isEnabled = { true }
        transcriptions = 0
        voice.makeTranscriber = { [unowned self] in
            self.transcriptions += 1
            return Transcriber(baseURL: "http://127.0.0.1:9/v1", model: "none", apiKey: nil, timeout: 1)
        }
    }

    override func tearDown() async throws {
        voice.cancel()
        try? FileManager.default.removeItem(at: clip)
    }

    private func startRecording() async throws {
        voice.start(.file(clip))
        try await waitFor { self.voice.phase == .recording }
        try await Task.sleep(for: .milliseconds(400)) // past the minimum duration
    }

    private func waitFor(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }

    func testConfigDefaultsToHoldAndKeepsShortcut() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try #"{"hotkeys":{"voice":"opt+space"},"voice":{"enabled":true}}"#.write(to: file, atomically: true, encoding: .utf8)
        let config = Config.load(from: file).config
        XCTAssertTrue(config.voice.holdToTalk)
        XCTAssertEqual(config.hotkeys.voice, "opt+space")
        try config.save(to: file)
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(saved.contains("\"holdToTalk\" : true"))
        XCTAssertTrue(saved.contains("\"voice\" : \"opt+space\""))
        try #"{"voice":{"holdToTalk":false}}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(Config.load(from: file).config.voice.holdToTalk)
    }

    func testHoldModePressStartsAndReleaseStops() async throws {
        voice.shortcutPressed(.file(clip))
        try await waitFor { self.voice.phase == .recording }
        try await Task.sleep(for: .milliseconds(400))
        voice.shortcutReleased(holdToTalk: true)
        XCTAssertEqual(voice.phase, .transcribing)
        XCTAssertEqual(transcriptions, 1)
    }

    func testToggleModeIgnoresReleaseAndSecondPressStops() async throws {
        voice.shortcutPressed(.file(clip))
        try await waitFor { self.voice.phase == .recording }
        try await Task.sleep(for: .milliseconds(400))
        voice.shortcutReleased(holdToTalk: false)
        XCTAssertEqual(voice.phase, .recording)
        voice.shortcutPressed(.file(clip))
        XCTAssertEqual(voice.phase, .transcribing)
        XCTAssertEqual(transcriptions, 1)
    }

    func testSwitchingToToggleMidHoldDoesNotStickTheRecording() async throws {
        voice.shortcutPressed(.file(clip))
        try await waitFor { self.voice.phase == .recording }
        voice.shortcutReleased(holdToTalk: false) // the switch was turned off while the key was down
        XCTAssertEqual(voice.phase, .recording)
        voice.shortcutPressed(.file(clip))
        XCTAssertNotEqual(voice.phase, .recording)
    }

    func testEscCancelsWithoutTranscribingAndReleaseAfterwardsDoesNothing() async throws {
        var registered: [Int: () -> Void] = [:]
        let keys = RecordingKeys(voice: voice) { code, _, _, handler in
            registered[code] = handler
            return NSObject()
        }
        try await startRecording()
        XCTAssertTrue(keys.isActive)
        registered[53]?() // Escape
        XCTAssertEqual(voice.phase, .idle)
        XCTAssertEqual(transcriptions, 0)
        XCTAssertFalse(keys.isActive)
        voice.shortcutReleased(holdToTalk: true)
        XCTAssertEqual(voice.phase, .idle)
        XCTAssertEqual(transcriptions, 0)
    }

    func testEnterStopsAndTranscribes() async throws {
        var registered: [Int: () -> Void] = [:]
        let keys = RecordingKeys(voice: voice) { code, _, _, handler in
            registered[code] = handler
            return NSObject()
        }
        try await startRecording()
        registered[36]?() // Return
        XCTAssertEqual(voice.phase, .transcribing)
        XCTAssertEqual(transcriptions, 1)
        XCTAssertFalse(keys.isActive)
    }

    func testKeysAreOnlyRegisteredWhileRecording() async throws {
        var live = 0
        final class Token { let onDeinit: () -> Void; init(_ f: @escaping () -> Void) { onDeinit = f }; deinit { onDeinit() } }
        let keys = RecordingKeys(voice: voice) { _, _, _, _ in
            live += 1
            return Token { live -= 1 }
        }
        XCTAssertEqual(live, 0)
        try await startRecording()
        XCTAssertEqual(live, 2)
        voice.stop()
        XCTAssertEqual(live, 0, "unregistered once the recording stops")
        voice.cancel()
        try await startRecording()
        XCTAssertEqual(live, 2)
        voice.cancel()
        XCTAssertEqual(live, 0, "unregistered on cancel")
        _ = keys
    }
}

@MainActor
final class RecordingKeysModifierTests: XCTestCase {
    func testKeysAreAlsoRegisteredWithTheShortcutModifiersWhileTheyAreHeld() async throws {
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try WAV.encode((0..<WAV.sampleRate).map { Int16($0 % 100) }).write(to: clip)
        defer { try? FileManager.default.removeItem(at: clip) }
        let voice = VoiceController()
        voice.isEnabled = { true }
        var modifiers: [Int] = []
        let keys = RecordingKeys(voice: voice, heldModifiers: { 2048 }) { _, mods, _, _ in
            modifiers.append(mods)
            return NSObject()
        }
        voice.start(.file(clip))
        for _ in 0..<100 where voice.phase != .recording { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(modifiers.sorted(), [0, 0, 2048, 2048])
        voice.cancel()
        XCTAssertFalse(keys.isActive)
    }
}
