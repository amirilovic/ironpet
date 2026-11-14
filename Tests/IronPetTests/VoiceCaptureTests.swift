import AVFoundation
import XCTest
@testable import IronPet

final class VoiceCaptureTests: XCTestCase {
    private func buffer(rate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = sin(Float(i) * 0.05) * 0.5 }
        }
        return buffer
    }

    func testBuffersInAnotherFormatThanTheFirstStillConvert() {
        let converter = AdaptiveConverter()
        XCTAssertFalse(converter.convert(buffer(rate: 48_000, channels: 2, frames: 4800)).isEmpty)
        // The headset switched to its 16 kHz hands-free profile.
        let samples = converter.convert(buffer(rate: 16_000, channels: 1, frames: 1600))
        XCTAssertGreaterThan(samples.count, 1500)
    }

    func test16kMonoInputKeepsEverySample() {
        let samples = AdaptiveConverter().convert(buffer(rate: 16_000, channels: 1, frames: 1600))
        XCTAssertGreaterThan(samples.count, 1500)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.1)
    }

    func testWAVFromCapturedSamplesIsValid() {
        let floats = AdaptiveConverter().convert(buffer(rate: 16_000, channels: 1, frames: 1600))
        let wav = WAV.encode(PCMConverter.int16(floats))
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(wav.count, 44 + floats.count * 2)
        XCTAssertGreaterThan(floats.count, 0)
        XCTAssertEqual(WAV.duration(of: wav) ?? 0, Double(floats.count) / 16_000, accuracy: 0.001)
    }
}
