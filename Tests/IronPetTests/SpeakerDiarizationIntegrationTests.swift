import AVFoundation
import XCTest
@testable import IronPet

/// Runs FluidAudio on speech synthesised with two macOS voices. It downloads the models (about 21 MB) the first time,
/// and skips when it cannot: no network, no `say`, or a Hugging Face outage.
final class SpeakerDiarizationIntegrationTests: XCTestCase {
    private func speak(_ voice: String, _ text: String, to url: URL) throws -> [Int16] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", url.path, "--data-format=LEI16@16000", text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("`say` could not use the voice \(voice)") }
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { return [] }
        return UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)).map { Int16(max(-1, min(1, $0)) * 32767) }
    }

    func testTwoSynthesisedVoicesAreTwoSpeakers() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-diar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = "Good morning everyone. Thanks for joining the call today. I want to start with the plan for the next release, because the schedule has moved and a few things depend on it."
        let b = "Thanks for that. From my side the testing is nearly done, but I still need two more days to finish the migration work, and then the documentation can go out as well."
        let voiceA = try speak("Samantha", a, to: dir.appendingPathComponent("a.wav"))
        let voiceB = try speak("Daniel", b, to: dir.appendingPathComponent("b.wav"))
        let pause = [Int16](repeating: 0, count: WAV.sampleRate)
        let samples = voiceA + pause + voiceB + pause + voiceA + pause + voiceB
        let wav = dir.appendingPathComponent("two-voices.wav")
        try WAV.encode(samples).write(to: wav)

        do {
            try await SpeakerModels.fluidDownload { _ in }
        } catch {
            throw XCTSkip("could not download the diarization models: \(error.localizedDescription)")
        }
        let result = try await FluidDiarizer().diarize(wav: wav)
        XCTAssertEqual(result.speakers.count, 2, "speakers found: \(result.speakers.map { ($0.localId, $0.seconds) })")
        XCTAssertTrue(result.speakers.allSatisfy { $0.embedding.count == 256 })
        if result.speakers.count == 2 {
            // The same voice twice is one speaker, and the two voices differ.
            let score = SpeakerMatcher.cosine(result.speakers[0].embedding, result.speakers[1].embedding)
            XCTAssertLessThan(score, SpeakerThresholds.suggest)
        }
        XCTAssertTrue(SpeakerModels.defaultCachePresent(), "the cache check must see the files FluidAudio wrote")
    }
}
