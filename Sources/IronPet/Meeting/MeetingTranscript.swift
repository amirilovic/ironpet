import Foundation

/// Whose voice a line is: the microphone is "Me", the recorded app is "Them".
enum MeetingTrack: String, CaseIterable, Comparable {
    case me = "Me"
    case them = "Them"

    /// File prefix of a track's chunks: `mic-001.wav`, `them-001.wav`.
    var filePrefix: String { self == .me ? "mic" : "them" }

    static func < (lhs: MeetingTrack, rhs: MeetingTrack) -> Bool { lhs == .me && rhs == .them }
}

/// One line of the transcript, with `start` in seconds from the start of the meeting.
struct MeetingLine: Equatable {
    var track: MeetingTrack
    var start: TimeInterval
    var text: String
}

/// A stretch of audio that could not be transcribed.
struct MissedRange: Equatable {
    var track: MeetingTrack
    var start: TimeInterval
    var end: TimeInterval
    var reason: String
}

/// Turns the segments of both tracks into `transcript.md`.
enum MeetingTranscript {
    /// Moves a chunk's segments to meeting time. `offset` is where the chunk starts in the meeting.
    static func lines(from segments: [TimedSegment], track: MeetingTrack, offset: TimeInterval) -> [MeetingLine] {
        segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !isSilenceOnly(text) else { return nil }
            return MeetingLine(track: track, start: offset + max(0, segment.start), text: text)
        }
    }

    /// Empty text, punctuation only, or the markers some models print for quiet audio, such as `[BLANK_AUDIO]`.
    static func isSilenceOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces).contains($0) }) {
            return true
        }
        let marker = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]()* "))
        return ["blank_audio", "silence", "blank audio", "no speech", "music", "inaudible"].contains(marker)
            && (trimmed.hasPrefix("[") || trimmed.hasPrefix("(") || trimmed.hasPrefix("*"))
    }

    static func render(startedAt: Date, appName: String, lines: [MeetingLine], missed: [MissedRange] = [],
                       timeZone: TimeZone = .current) -> String {
        enum Entry {
            case line(MeetingLine)
            case missed(MissedRange)
            var start: TimeInterval {
                switch self {
                case .line(let line): return line.start
                case .missed(let range): return range.start
                }
            }
            var track: MeetingTrack {
                switch self {
                case .line(let line): return line.track
                case .missed(let range): return range.track
                }
            }
        }
        let entries = (lines.map(Entry.line) + missed.map(Entry.missed)).enumerated()
            .sorted { a, b in
                if a.element.start != b.element.start { return a.element.start < b.element.start }
                if a.element.track != b.element.track { return a.element.track < b.element.track }
                return a.offset < b.offset
            }
            .map(\.element)

        var out = "# Meeting \(stamp(startedAt, timeZone: timeZone)) (\(appName))\n"
        var seenMissed = Set<String>()
        for entry in entries {
            switch entry {
            case .line(let line):
                out += "[\(clock(startedAt, plus: line.start, timeZone: timeZone))] \(line.track.rawValue): \(line.text)\n"
            case .missed(let range):
                let text = "[\(clock(startedAt, plus: range.start, timeZone: timeZone))–"
                    + "\(clock(startedAt, plus: range.end, timeZone: timeZone))] (not transcribed: \(range.reason))"
                if seenMissed.insert(text).inserted { out += text + "\n" }
            }
        }
        return out
    }

    /// `2026-11-14 14:00`
    static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter("yyyy-MM-dd HH:mm", timeZone).string(from: date)
    }

    /// `14:02:10`, the wall-clock time `seconds` into a meeting that started at `start`.
    static func clock(_ start: Date, plus seconds: TimeInterval, timeZone: TimeZone = .current) -> String {
        formatter("HH:mm:ss", timeZone).string(from: start.addingTimeInterval(seconds.rounded(.down)))
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// Folder name for a meeting that started at `date`: `2026-11-14-1400`.
    static func folderName(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter("yyyy-MM-dd-HHmm", timeZone).string(from: date)
    }

    /// `hh:mm:ss` for an elapsed time, used in failure reasons and the panel.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}
