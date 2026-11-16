import Foundation

/// Drops segments that Whisper-style models invent on silent or near-silent audio ("Thank you.", "Bye."). Works on
/// the audio that was sent, so it does not depend on which server answered.
enum SegmentFilter {
    /// Segments whose audio RMS (Int16 scale) is below this are dropped, about -50 dBFS.
    static let silentRMS: Double = 80
    /// Short stock phrases are also dropped below this RMS, about -40 dBFS. Real speech sits well above it.
    static let hallucinationRMS: Double = 300
    /// Whisper's own rule: no speech likely and low confidence.
    static let noSpeechProb = 0.6
    static let avgLogprob = -1.0

    static let hallucinations: Set<String> = [
        "thank you", "thanks", "thank you very much", "thanks for watching", "thank you for watching",
        "bye", "goodbye", "you",
        "subscribe", "please subscribe", "see you next time", "i'll see you next time",
    ]

    static func filter(_ segments: [TimedSegment], wav: Data) -> [TimedSegment] {
        let samples = WAV.samples(of: wav)
        return segments.filter { keep($0, samples: samples) }
    }

    static func keep(_ segment: TimedSegment, samples: [Int16]) -> Bool {
        if let noSpeech = segment.noSpeechProb, let logprob = segment.avgLogprob,
           noSpeech > noSpeechProb, logprob < avgLogprob { return false }
        // Text-only servers give one segment with no time range. The chunk-level check already ran.
        guard segment.end > segment.start, !samples.isEmpty else { return true }
        let rate = Double(WAV.sampleRate)
        let from = min(max(Int(segment.start * rate), 0), samples.count)
        let to = min(max(Int(segment.end * rate), from), samples.count)
        guard to > from else { return true }
        let level = rms(samples[from..<to])
        if level < silentRMS { return false }
        if level < hallucinationRMS, isStockPhrase(segment.text) { return false }
        return true
    }

    static func isStockPhrase(_ text: String) -> Bool {
        let cleaned = text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "'" }
            .trimmingCharacters(in: .whitespaces)
        return hallucinations.contains(cleaned)
    }

    static func rms(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Int64(0)) { $0 + Int64($1) * Int64($1) }
        return (Double(sum) / Double(samples.count)).squareRoot()
    }
}

extension WAV {
    /// The 16-bit samples of a PCM WAV, or empty when the header is not 16-bit PCM.
    static func samples(of wav: Data) -> [Int16] {
        guard wav.count > 44, wav.prefix(4) == Data("RIFF".utf8),
              wav[wav.startIndex + 20] == 1, wav[wav.startIndex + 34] == 16 else { return [] }
        let body = wav.dropFirst(44)
        return body.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
    }
}
