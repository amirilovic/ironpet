import Foundation

/// Minimal RIFF/WAVE reading and writing for 16-bit mono PCM, the only format voice notes use.
enum WAV {
    static let sampleRate = 16_000

    /// A complete .wav file around 16-bit mono samples.
    static func encode(_ samples: [Int16], sampleRate: Int = WAV.sampleRate) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))
        samples.withUnsafeBufferPointer { buffer in
            for sample in buffer { append(sample) }
        }
        return data
    }

    /// Seconds of audio in a WAV produced by `encode`, or nil when the header is not one of ours.
    static func duration(of wav: Data) -> TimeInterval? {
        guard wav.count >= 44, wav.prefix(4) == Data("RIFF".utf8) else { return nil }
        let rate = wav.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        guard rate > 0 else { return nil }
        return Double(wav.count - 44) / 2 / Double(rate)
    }
}
