import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// One audio track of a meeting: starts asynchronously (ScreenCaptureKit has to look up what it can capture first)
/// and delivers 16 kHz mono samples to `samples`, with a 0...1 loudness to `level`.
protocol TrackSource: AnyObject {
    func start(level: @escaping @Sendable (Float) -> Void, samples: @escaping @Sendable ([Int16]) -> Void) async throws
    func stop()
}

enum MeetingError: LocalizedError {
    case appNotRunning(String)
    case noDisplay
    case captureDenied

    var errorDescription: String? {
        switch self {
        case .appNotRunning(let name): return "\(name) is not running, or macOS does not list it for audio capture."
        case .noDisplay: return "No display is available for system audio capture."
        case .captureDenied:
            return "ironpet can't record system audio. Allow it under System Settings → Privacy & Security → Screen & System Audio Recording, then start again."
        }
    }
}

/// The microphone or a WAV file (in `--test-mode`) as a track.
final class LocalTrack: TrackSource {
    private let source: StreamingSource

    init(_ source: StreamingSource) {
        self.source = source
    }

    func start(level: @escaping @Sendable (Float) -> Void, samples: @escaping @Sendable ([Int16]) -> Void) async throws {
        source.sink = samples
        try source.start(level: level)
    }

    func stop() {
        source.cancel()
    }
}

/// One app's audio, or all system audio, through ScreenCaptureKit. ironpet's own audio is always left out.
final class SystemAudioSource: NSObject, TrackSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let choice: AudioChoice
    private let queue = DispatchQueue(label: "ironpet.system-audio")
    private var stream: SCStream?
    private var converter: PCMConverter?
    private var converterFormat: AVAudioFormat?
    private var level: (@Sendable (Float) -> Void)?
    private var samples: (@Sendable ([Int16]) -> Void)?
    /// Called when macOS stops the capture, for example when the app quits or permission is revoked.
    var onStop: (@Sendable (Error) -> Void)?

    init(choice: AudioChoice) {
        self.choice = choice
    }

    func start(level: @escaping @Sendable (Float) -> Void, samples: @escaping @Sendable ([Int16]) -> Void) async throws {
        self.level = level
        self.samples = samples
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw MeetingError.noDisplay }
        let filter: SCContentFilter
        switch choice {
        case .allSystemAudio:
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case .app(let app):
            guard let running = content.applications.first(where: { $0.bundleIdentifier == app.bundleID }) else {
                throw MeetingError.appNotRunning(app.name)
            }
            filter = SCContentFilter(display: display, including: [running], exceptingWindows: [])
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Only the audio is used, so keep the video side as cheap as it can be.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = Self.pcm(from: sampleBuffer) else { return }
        if converter == nil || converterFormat != buffer.format {
            converter = PCMConverter(from: buffer.format)
            converterFormat = buffer.format
        }
        guard let floats = converter?.convert(buffer), !floats.isEmpty else { return }
        level?(PCMConverter.level(of: floats[...]))
        samples?(PCMConverter.int16(floats))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }

    private static func pcm(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return nil }
        var asbd = description
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
