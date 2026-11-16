import Foundation

/// Every number that decides whether a voice is recognised. They come from one measured meeting (same speaker
/// scored 0.78 or more against a stored centroid, different speakers 0.62 or less), so they are provisional.
enum SpeakerThresholds {
    /// At or above this, and clearly ahead of the runner-up, a voice gets the name without asking.
    static let autoLabel: Float = 0.70
    /// The best score must beat the second best by this much for an automatic label.
    static let margin: Float = 0.10
    /// From here up to `autoLabel`, ironpet suggests a name and asks. Below it the voice is unknown.
    static let suggest: Float = 0.55
    /// A cluster needs this much speech before a name the user gave may update a stored voice.
    static let minEnrollSeconds: Double = 10
    /// Seconds of speech that one side of a centroid update counts for, at most.
    static let maxWeightSeconds: Double = 600
    /// Within one meeting, two chunk-local speakers at or above this are the same person.
    static let sameInMeeting: Float = 0.70
}

/// A voice to compare against: a stored person, or a speaker already seen in this meeting.
struct VoiceCandidate: Equatable {
    var id: String
    var name: String
    var centroid: [Float]
}

enum SpeakerMatch: Equatable {
    case known(id: String, name: String, score: Float)
    case suggestion(id: String, name: String, score: Float)
    case unknown
}

enum SpeakerMatcher {
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            na += a[index] * a[index]
            nb += b[index] * b[index]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Scores `embedding` against every candidate and applies the thresholds.
    static func match(_ embedding: [Float], against candidates: [VoiceCandidate]) -> SpeakerMatch {
        let scored = candidates.map { ($0, cosine(embedding, $0.centroid)) }.sorted { $0.1 > $1.1 }
        guard let (best, score) = scored.first, score >= SpeakerThresholds.suggest else { return .unknown }
        let runnerUp = scored.dropFirst().first?.1 ?? -1
        if score >= SpeakerThresholds.autoLabel, score - runnerUp >= SpeakerThresholds.margin {
            return .known(id: best.id, name: best.name, score: score)
        }
        return .suggestion(id: best.id, name: best.name, score: score)
    }

    /// `normalize(old * oldSeconds + new * newSeconds)`, with each weight capped so a long history cannot freeze a voice.
    static func merge(_ old: [Float], oldSeconds: Double, _ new: [Float], newSeconds: Double) -> [Float] {
        guard old.count == new.count else { return new }
        let wo = Float(min(oldSeconds, SpeakerThresholds.maxWeightSeconds))
        let wn = Float(min(newSeconds, SpeakerThresholds.maxWeightSeconds))
        return normalized(zip(old, new).map { $0 * wo + $1 * wn })
    }
}
