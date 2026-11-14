import Foundation

/// Cuts a stream of 16 kHz mono samples into chunks for transcription. A chunk closes at the first stretch of
/// silence once it is at least `minSamples` long, and is cut hard at `maxSamples`, so one upload stays well under
/// OpenAI's 25 MB limit even when nobody pauses.
struct Chunker {
    /// Meeting defaults: about 2 minutes, never more than 5. Tests pass shorter values.
    static let defaultMin = 120 * WAV.sampleRate
    static let defaultMax = 300 * WAV.sampleRate

    let minSamples: Int
    let maxSamples: Int
    /// How long the audio must stay quiet before a chunk may close.
    let silenceSamples: Int
    /// Frames with an RMS below this (on the Int16 scale) count as silence, about -42 dBFS.
    let silenceRMS: Double

    private static let frameSize = WAV.sampleRate / 50 // 20 ms
    private var current: [Int16] = []
    private var pending: [Int16] = []
    private var silentRun = 0

    init(minSamples: Int = Chunker.defaultMin, maxSamples: Int = Chunker.defaultMax,
         silenceSamples: Int = WAV.sampleRate / 2, silenceRMS: Double = 250) {
        self.minSamples = minSamples
        self.maxSamples = max(maxSamples, minSamples)
        self.silenceSamples = silenceSamples
        self.silenceRMS = silenceRMS
    }

    /// Feeds samples and returns the chunks that closed because of them.
    mutating func push(_ samples: [Int16]) -> [[Int16]] {
        let input = pending + samples
        pending = []
        var closed: [[Int16]] = []
        var index = 0
        while index < input.count {
            let room = maxSamples - current.count
            let count = min(Self.frameSize, room, input.count - index)
            // A partial frame at the end waits for the next push, unless it fills the chunk.
            if count < Self.frameSize, count == input.count - index, count < room {
                pending = Array(input[index...])
                break
            }
            let frame = input[index..<index + count]
            index += count
            current.append(contentsOf: frame)
            silentRun = isSilent(frame) ? silentRun + count : 0
            if current.count >= maxSamples || (current.count >= minSamples && silentRun >= silenceSamples) {
                closed.append(current)
                current = []
                silentRun = 0
            }
        }
        return closed
    }

    /// Whatever is left when recording stops, or nil when nothing is.
    mutating func flush() -> [Int16]? {
        let rest = current + pending
        current = []
        pending = []
        silentRun = 0
        return rest.isEmpty ? nil : rest
    }

    private func isSilent(_ frame: ArraySlice<Int16>) -> Bool {
        guard !frame.isEmpty else { return true }
        let sum = frame.reduce(Int64(0)) { $0 + Int64($1) * Int64($1) }
        return (Double(sum) / Double(frame.count)).squareRoot() < silenceRMS
    }

    /// True when a chunk has no sound worth uploading.
    static func isSilent(_ samples: [Int16], rms: Double = 100) -> Bool {
        guard !samples.isEmpty else { return true }
        let sum = samples.reduce(Int64(0)) { $0 + Int64($1) * Int64($1) }
        return (Double(sum) / Double(samples.count)).squareRoot() < rms
    }
}
