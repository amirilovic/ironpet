import Foundation

/// A chunk that was written to disk.
struct ChunkInfo: Equatable {
    var track: MeetingTrack
    var index: Int
    var url: URL
    /// Seconds from the start of the meeting to the start of this chunk.
    var offset: TimeInterval
    var duration: TimeInterval
    /// No sound above the noise floor, so there is nothing to transcribe.
    var silent: Bool
}

/// Takes one track's samples, cuts them into chunks with `Chunker` and writes each chunk as a WAV file under the
/// meeting folder. Everything runs on its own serial queue, so the audio thread never waits on the disk.
final class TrackRecorder: @unchecked Sendable {
    let track: MeetingTrack
    private let folder: URL
    private let queue: DispatchQueue
    private var chunker: Chunker
    private let startedAt = Date()
    private var written = 0
    private var offsetSamples = 0
    private var nextIndex = 1
    private var timer: DispatchSourceTimer?
    private var finished = false
    /// Called on the recorder's queue for every chunk that closes.
    var onChunk: (@Sendable (ChunkInfo) -> Void)?

    init(track: MeetingTrack, folder: URL, chunker: Chunker) {
        self.track = track
        self.folder = folder
        self.chunker = chunker
        queue = DispatchQueue(label: "ironpet.meeting.\(track.filePrefix)")
    }

    func start() {
        // A source that stops delivering (an app that is not playing anything) would make this track shorter than
        // the other one, and every later timestamp wrong. Pad with silence to keep the two on one clock.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.padIfStalled() }
        timer.resume()
        self.timer = timer
    }

    func ingest(_ samples: [Int16]) {
        queue.async { [self] in
            guard !finished else { return }
            feed(samples)
        }
    }

    /// Stops the timer, writes what is left as a last chunk and calls `done` (on the recorder's queue).
    func finish(_ done: @escaping @Sendable (ChunkInfo?) -> Void) {
        queue.async { [self] in
            finished = true
            timer?.cancel()
            timer = nil
            if let rest = chunker.flush() {
                done(write(rest))
            } else {
                done(nil)
            }
        }
    }

    private func padIfStalled() {
        guard !finished else { return }
        let expected = Int(Date().timeIntervalSince(startedAt) * Double(WAV.sampleRate))
        let behind = expected - written
        if behind > WAV.sampleRate * 3 / 2 {
            feed([Int16](repeating: 0, count: behind - WAV.sampleRate / 2))
        }
    }

    private func feed(_ samples: [Int16]) {
        written += samples.count
        for closed in chunker.push(samples) {
            if let info = write(closed) { onChunk?(info) }
        }
    }

    private func write(_ samples: [Int16]) -> ChunkInfo? {
        let index = nextIndex
        nextIndex += 1
        let url = folder.appendingPathComponent(String(format: "%@-%03d.wav", track.filePrefix, index))
        let offset = Double(offsetSamples) / Double(WAV.sampleRate)
        offsetSamples += samples.count
        do {
            try WAV.encode(samples).write(to: url, options: .atomic)
        } catch {
            NSLog("ironpet: could not write \(url.path): \(error)")
            return nil
        }
        return ChunkInfo(track: track, index: index, url: url, offset: offset,
                         duration: Double(samples.count) / Double(WAV.sampleRate), silent: Chunker.isSilent(samples) || samples.count < WAV.sampleRate / 4)
    }
}
