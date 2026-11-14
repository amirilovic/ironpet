import CoreAudio
import Foundation

/// A process that is capturing microphone input.
struct MicClient: Equatable {
    var pid: pid_t
    var bundleID: String
}

/// Which mic users count as a call, and which app each one belongs to. Kept in one place.
enum CallApps {
    /// Never a call: voice assistants, dictation and system daemons.
    static let ignoredPrefixes = [
        "com.apple.Siri", "com.apple.assistant", "com.apple.speech", "com.apple.SpeechRecognition",
        "com.apple.corespeech", "com.apple.voicememos", "com.apple.VoiceOver", "com.apple.accessibility",
        "com.apple.audio", "com.apple.coreaudio", "com.apple.controlcenter", "com.apple.dictation",
    ]

    /// Other apps' helper processes report their own bundle IDs. Chrome, Electron apps and WhatsApp use a `.helper`
    /// suffix, and Safari's web content runs as `com.apple.WebKit.*`.
    static func parentBundleID(_ id: String) -> String {
        if id.hasPrefix("com.apple.WebKit.") { return "com.apple.Safari" }
        if let range = id.range(of: ".helper", options: .caseInsensitive) { return String(id[..<range.lowerBound]) }
        return id
    }

    /// The app a client belongs to, or nil if it is ironpet, a system service or an assistant.
    static func app(for client: MicClient, ownPID: pid_t, ownBundleID: String?) -> String? {
        guard client.pid != ownPID, !client.bundleID.isEmpty else { return nil }
        let id = parentBundleID(client.bundleID)
        if id == ownBundleID { return nil }
        if ignoredPrefixes.contains(where: { id.hasPrefix($0) }) { return nil }
        // Other system processes (coreaudiod, helpers of the OS) are not calls. FaceTime and Safari are.
        if id.hasPrefix("com.apple."), !AudioApps.meetingApps.contains(id), !AudioApps.browsers.contains(id) { return nil }
        return id
    }
}

/// Reports when a non-ignored app has held the microphone for `debounce` seconds, and when it has let go for as long.
/// The process list and the clock are injected, so tests run without audio hardware.
final class CallDetector {
    var source: () -> [MicClient]
    var now: () -> Date
    var debounce: TimeInterval
    var ownPID: pid_t
    var ownBundleID: String?
    var onStarted: ((String) -> Void)?
    var onEnded: ((String) -> Void)?

    /// When each app was first seen holding the mic in the current run, and whether a call was reported for it.
    private var since: [String: Date] = [:]
    private var lastHeld: [String: Date] = [:]
    private var active: Set<String> = []

    init(source: @escaping () -> [MicClient], now: @escaping () -> Date = Date.init, debounce: TimeInterval = 10,
         ownPID: pid_t = ProcessInfo.processInfo.processIdentifier, ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.source = source
        self.now = now
        self.debounce = debounce
        self.ownPID = ownPID
        self.ownBundleID = ownBundleID
    }

    var activeApps: Set<String> { active }

    func tick() {
        let time = now()
        let holding = Set(source().compactMap { CallApps.app(for: $0, ownPID: ownPID, ownBundleID: ownBundleID) })
        for id in holding {
            lastHeld[id] = time
            if since[id] == nil { since[id] = time }
            if !active.contains(id), time.timeIntervalSince(since[id]!) >= debounce {
                active.insert(id)
                onStarted?(id)
            }
        }
        for id in Array(since.keys) where !holding.contains(id) {
            if active.contains(id) {
                guard time.timeIntervalSince(lastHeld[id] ?? time) >= debounce else { continue }
                active.remove(id)
                onEnded?(id)
            }
            since[id] = nil
            lastHeld[id] = nil
        }
    }
}

/// Reads which processes capture input from Core Audio (macOS 14.2+), and polls it cheaply.
@MainActor
final class CallMonitor {
    let detector: CallDetector
    private var timer: Timer?

    init(detector: CallDetector) { self.detector = detector }

    func start() {
        guard timer == nil else { return }
        detector.tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.detector.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Every process object that currently has input running.
    nonisolated static func micClients() -> [MicClient] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            guard uint32(object, kAudioProcessPropertyIsRunningInput) == 1,
                  let pid = int32(object, kAudioProcessPropertyPID) else { return nil }
            return MicClient(pid: pid, bundleID: string(object, kAudioProcessPropertyBundleID) ?? "")
        }
    }

    private nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private nonisolated static func int32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
        var address = address(selector)
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private nonisolated static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
