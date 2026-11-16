import Foundation

/// A stretch of one speaker's audio inside a chunk file, for the "Who is this?" clip.
struct SpeakerClip: Equatable {
    var url: URL
    var start: TimeInterval
    var end: TimeInterval

    /// At most 5 s from the middle of the stretch, so the clip is the clearest part of the longest turn.
    var playable: (start: TimeInterval, length: TimeInterval) {
        let length = min(5, end - start)
        return (start + (end - start - length) / 2, length)
    }
}

/// One voice found in this meeting, across all chunks.
struct MeetingSpeaker: Identifiable, Equatable {
    var id: Int
    var centroid: [Float]
    var seconds: TimeInterval
    var name: String?
    var personId: String?
    /// A stored person this voice resembles, between the suggest and auto thresholds.
    var suggestion: String?
    /// The user chose "Ignore" or "Two people mixed", so ironpet stops asking and never stores this voice.
    var dismissed = false
    var mixed = false
    var clip: SpeakerClip?
    var clipLength: TimeInterval = 0

    var displayName: String { name ?? "Speaker \(id)" }
    /// Only voices that spoke for a few seconds are worth asking about.
    var needsName: Bool { name == nil && !dismissed && seconds >= 3 }
}

/// Links each chunk's local speakers into the meeting's speakers, by comparing voices.
struct MeetingSpeakerTable: Equatable {
    private(set) var speakers: [MeetingSpeaker] = []

    func speaker(_ id: Int) -> MeetingSpeaker? { speakers.first { $0.id == id } }

    /// Adds one chunk. Returns the meeting speaker id for each of the chunk's local ids.
    /// A voice is first compared to speakers already seen in this meeting, then to the stored voices.
    mutating func link(_ chunk: ChunkDiarization, chunkURL: URL, store: [VoiceCandidate]) -> [String: Int] {
        var assigned: [String: Int] = [:]
        for local in chunk.speakers.sorted(by: { $0.seconds > $1.seconds }) where !local.embedding.isEmpty {
            // Two speakers the diarizer separated inside one chunk are two people, so a taken id is not a candidate.
            let taken = Set(assigned.values)
            let inMeeting = speakers.filter { !taken.contains($0.id) }.map { VoiceCandidate(id: String($0.id), name: $0.displayName, centroid: $0.centroid) }
            let longest = local.longestTurn
            let clip = longest.map { SpeakerClip(url: chunkURL, start: $0.lowerBound, end: $0.upperBound) }
            if case .known(let id, _, _) = SpeakerMatcher.match(local.embedding, against: inMeeting),
               let index = speakers.firstIndex(where: { String($0.id) == id }) {
                var speaker = speakers[index]
                speaker.centroid = SpeakerMatcher.merge(speaker.centroid, oldSeconds: speaker.seconds, local.embedding, newSeconds: local.seconds)
                speaker.seconds += local.seconds
                if let longest, longest.upperBound - longest.lowerBound > speaker.clipLength {
                    speaker.clip = clip
                    speaker.clipLength = longest.upperBound - longest.lowerBound
                }
                speakers[index] = speaker
                assigned[local.localId] = speaker.id
            } else {
                var speaker = MeetingSpeaker(id: (speakers.map(\.id).max() ?? 0) + 1, centroid: local.embedding, seconds: local.seconds,
                                             clip: clip, clipLength: longest.map { $0.upperBound - $0.lowerBound } ?? 0)
                Self.applyStore(store, to: &speaker)
                speakers.append(speaker)
                assigned[local.localId] = speaker.id
            }
        }
        return assigned
    }

    /// The last pass at the end of a meeting. Names unnamed voices from the store, then merges voices that turned
    /// out to be the same person. Returns which speaker id replaced which, for the transcript lines.
    mutating func relink(store: [VoiceCandidate]) -> [Int: Int] {
        for index in speakers.indices where speakers[index].name == nil && !speakers[index].dismissed {
            Self.applyStore(store, to: &speakers[index])
        }
        var remap: [Int: Int] = [:]
        var index = 0
        while index < speakers.count {
            var other = index + 1
            while other < speakers.count {
                if Self.sameVoice(speakers[index], speakers[other]) {
                    var keep = speakers[index]
                    let gone = speakers[other]
                    keep.centroid = SpeakerMatcher.merge(keep.centroid, oldSeconds: keep.seconds, gone.centroid, newSeconds: gone.seconds)
                    keep.seconds += gone.seconds
                    if gone.clipLength > keep.clipLength { keep.clip = gone.clip; keep.clipLength = gone.clipLength }
                    keep.name = keep.name ?? gone.name
                    // A voice the user told ironpet to ignore stays ignored after a merge.
                    keep.dismissed = keep.dismissed || gone.dismissed
                    keep.personId = keep.personId ?? gone.personId
                    keep.suggestion = keep.suggestion ?? gone.suggestion
                    speakers[index] = keep
                    remap[gone.id] = keep.id
                    speakers.remove(at: other)
                } else {
                    other += 1
                }
            }
            index += 1
        }
        return remap
    }

    mutating func setName(_ id: Int, _ name: String?) {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        speakers[index].name = name
        speakers[index].suggestion = nil
        if name != nil { speakers[index].dismissed = false }
    }

    mutating func dismiss(_ id: Int, mixed: Bool) {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        speakers[index].dismissed = true
        speakers[index].mixed = mixed
    }

    private static func sameVoice(_ a: MeetingSpeaker, _ b: MeetingSpeaker) -> Bool {
        if a.mixed || b.mixed { return false }
        // Two named voices are the same person only when the names match, whatever their embeddings say.
        if let x = a.name, let y = b.name { return x.caseInsensitiveCompare(y) == .orderedSame }
        // A named voice and an unnamed one stay apart: the user or the store decided who the named one is.
        if a.name != nil || b.name != nil { return false }
        return SpeakerMatcher.cosine(a.centroid, b.centroid) >= SpeakerThresholds.sameInMeeting
    }

    private static func applyStore(_ store: [VoiceCandidate], to speaker: inout MeetingSpeaker) {
        guard !store.isEmpty else { return }
        switch SpeakerMatcher.match(speaker.centroid, against: store) {
        case .known(let id, let name, _):
            speaker.name = name
            speaker.personId = id
            speaker.suggestion = nil
        case .suggestion(_, let name, _):
            speaker.suggestion = name
        case .unknown:
            speaker.suggestion = nil
        }
    }
}
