import AVFoundation
import Foundation

/// A file in a Telegram message, with the name it gets on disk.
struct TelegramMedia: Equatable {
    enum Kind { case file, voice }
    let kind: Kind
    let attachment: TelegramAttachment
    let name: String
}

enum TelegramMediaError: LocalizedError, Equatable {
    case tooLarge(name: String, bytes: Int?)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .tooLarge(let name, let bytes):
            let size = bytes.map { String(format: " (%.1f MB)", Double($0) / 1_048_576) } ?? ""
            return "\(name)\(size) is over Telegram's 20 MB limit for bot downloads, so ironpet cannot get it. Send a smaller file."
        case .unavailable:
            return "Telegram did not give a download link for that file."
        }
    }
}

enum TelegramMediaStore {
    /// Telegram lets bots download files up to 20 MB.
    static let maxBytes = 20 * 1024 * 1024
    static let keepPerChat = 50

    /// The media in a message: photos (largest size), documents and videos as files; voice messages, audio and video
    /// notes as voice.
    static func media(in message: TelegramMessage) -> [TelegramMedia] {
        var found: [TelegramMedia] = []
        if let photo = message.photo?.last { found.append(.init(kind: .file, attachment: photo, name: "photo.jpg")) }
        if let document = message.document {
            found.append(.init(kind: .file, attachment: document, name: document.fileName ?? "document"))
        }
        if let video = message.video { found.append(.init(kind: .file, attachment: video, name: video.fileName ?? "video.mp4")) }
        if let voice = message.voice { found.append(.init(kind: .voice, attachment: voice, name: "voice.ogg")) }
        if let audio = message.audio { found.append(.init(kind: .voice, attachment: audio, name: audio.fileName ?? "audio.mp3")) }
        if let note = message.videoNote { found.append(.init(kind: .voice, attachment: note, name: "video-note.mp4")) }
        return found
    }

    /// A name that cannot leave the folder it is saved in.
    static func safeName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let cleaned = String(String.UnicodeScalarView(last)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "file" : String(cleaned.prefix(120))
    }

    /// Downloads one file. Throws `tooLarge` before downloading when Telegram reports a size over the limit, and when
    /// Telegram itself refuses with "file is too big".
    static func fetch(_ media: TelegramMedia, with client: TelegramClient) async throws -> (data: Data, name: String) {
        if let size = media.attachment.fileSize, size > maxBytes { throw TelegramMediaError.tooLarge(name: media.name, bytes: size) }
        let info: TelegramFilePath
        do {
            info = try await client.getFile(id: media.attachment.fileId)
        } catch TelegramError.api(_, let description) where description.lowercased().contains("too big") {
            throw TelegramMediaError.tooLarge(name: media.name, bytes: nil)
        }
        guard let path = info.filePath else { throw TelegramMediaError.unavailable }
        if let size = info.fileSize, size > maxBytes { throw TelegramMediaError.tooLarge(name: media.name, bytes: size) }
        let data = try await client.download(path: path)
        if data.count > maxBytes { throw TelegramMediaError.tooLarge(name: media.name, bytes: data.count) }
        // A document without an extension takes the one Telegram stored it with.
        var name = media.name
        let stored = (path as NSString).pathExtension
        if (name as NSString).pathExtension.isEmpty, !stored.isEmpty { name += "." + stored }
        return (data, safeName(name))
    }

    /// Saves under `<root>/<chat>/<timestamp>-<id>/<name>`, which keeps the original name for the agent, and drops the
    /// chat's oldest folders past `keepPerChat`.
    static func save(_ data: Data, name: String, chat: Int64, root: URL) throws -> URL {
        let chatFolder = root.appendingPathComponent(String(chat))
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = chatFolder.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(safeName(name))
        try data.write(to: target, options: .atomic)
        let folders = (try? FileManager.default.contentsOfDirectory(at: chatFolder, includingPropertiesForKeys: nil)) ?? []
        for old in folders.sorted(by: { $0.path > $1.path }).dropFirst(keepPerChat) {
            try? FileManager.default.removeItem(at: old)
        }
        return target
    }
}

/// Turns a downloaded voice or audio file into text with the voice server from Settings → Voice.
enum TelegramVoice {
    /// AVFoundation decodes WAV, MP3, M4A and MP4 audio. On macOS it does not read OGG/Opus, which is what Telegram
    /// voice messages are, so those go to the server as they are; OpenAI-compatible servers accept OGG.
    static func wav(from file: URL, maxSeconds: Double = 600) -> Data? {
        guard let input = try? AVAudioFile(forReading: file), input.length > 0 else { return nil }
        let format = input.processingFormat
        guard Double(input.length) / format.sampleRate <= maxSeconds,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(WAV.sampleRate), channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.length)),
              (try? input.read(into: buffer)) != nil else { return nil }
        let capacity = AVAudioFrameCount(Double(input.length) * target.sampleRate / format.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData?[0] else { return nil }
        return WAV.encode(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
    }

    /// Uses the server in Settings → Voice. The Keychain read happens here, off the main thread.
    static let configuredTranscribe: @Sendable (Data, String) async throws -> String = { audio, name in
        let voice = await MainActor.run { ConfigStore.shared.config.voice }
        let transcriber = Transcriber(baseURL: voice.baseUrl, model: voice.model, apiKey: VoiceKey.load(), usageFeature: .voiceTranscription)
        return try await transcribe(audio, name: name, with: transcriber)
    }

    static func mime(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "oga", "ogg", "opus": return "audio/ogg"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "mp4": return "video/mp4"
        case "wav": return "audio/wav"
        default: return "application/octet-stream"
        }
    }

    /// Decodes when AVFoundation can, otherwise sends the file as it is.
    static func transcribe(_ audio: Data, name: String, with transcriber: Transcriber) async throws -> String {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-tg-\(UUID().uuidString)-\(safeExtension(name))")
        defer { try? FileManager.default.removeItem(at: temp) }
        try audio.write(to: temp)
        if let wav = wav(from: temp) {
            return try await transcriber.transcribe(wav: wav)
        }
        return try await transcriber.transcribe(audio: audio, filename: name, mime: mime(for: name))
    }

    private static func safeExtension(_ name: String) -> String {
        "audio." + ((name as NSString).pathExtension.isEmpty ? "bin" : (name as NSString).pathExtension)
    }
}
