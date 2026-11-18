import Foundation

/// Why a speech request failed. Shown in Settings and in the chat, so each names the status or the cause.
enum SpeechError: LocalizedError, Equatable {
    case invalidURL(String)
    case unreachable(String)
    case timedOut
    case http(status: Int, detail: String)
    case noAudio

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "The voice server base URL \"\(url)\" is not a valid http(s) URL."
        case .unreachable(let reason):
            return "Could not reach the voice server: \(reason)"
        case .timedOut:
            return "The voice server did not answer in time (timed out)."
        case .http(let status, let detail):
            var message = "The voice server returned HTTP \(status)"
            if status == 401 || status == 403 { message += " (check the API key)" }
            if status == 404 { message += " (does it support /audio/speech?)" }
            return detail.isEmpty ? message + "." : message + ": " + detail
        case .noAudio:
            return "The voice server returned no audio. For Kokoro, mlx-audio needs the misaki package: start it with "
                + "uvx --from \"mlx-audio[server]\" --with \"misaki[en]\" mlx_audio.server"
        }
    }
}

/// Client for the OpenAI speech API: a JSON `POST {baseUrl}/audio/speech` that answers with audio. Works with OpenAI
/// and local servers such as mlx-audio. Always asks for WAV, which `AVAudioPlayer` plays without decoding a stream.
struct Synthesizer {
    var baseURL: String
    var model: String
    var voice: String
    var speed = 1.0
    /// Sent as `Authorization: Bearer` only when non-empty.
    var apiKey: String?
    var session: URLSession = .shared
    /// The first request after a server start loads the model, which takes a while.
    var timeout: TimeInterval = 60

    func speak(_ text: String) async throws -> Data {
        var request = try makeRequest(path: "/audio/speech")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "input": text, "voice": voice, "speed": speed, "response_format": "wav",
        ])
        let data = try await send(request)
        // mlx-audio answers 200 with an empty body when the model fails to load (Kokoro without misaki).
        guard data.count > 44 else { throw SpeechError.noAudio }
        return data
    }

    /// The model's voice names from mlx-audio's `GET /audio/voices?model=`. Empty when the server has no such
    /// endpoint (OpenAI), so the caller falls back to a text field.
    func voices() async -> [String] {
        guard var request = try? makeRequest(path: "/audio/voices"), let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        request.url = components.url
        guard let data = try? await send(request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }
    }

    private static let accents: [Character: String] = [
        "a": "American", "b": "British", "e": "Spanish", "f": "French", "h": "Hindi",
        "i": "Italian", "j": "Japanese", "p": "Portuguese", "z": "Mandarin",
    ]

    /// Kokoro names its voices `<accent><gender>_<name>`, such as `am_puck`; those read as "Puck (American, male)".
    /// Any other name is shown as it is.
    static func label(for voice: String) -> String {
        let parts = voice.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 2, !parts[1].isEmpty,
              let accent = accents[parts[0].first!],
              let gender = ["f": "female", "m": "male"][String(parts[0].last!)] else { return voice }
        return "\(parts[1].prefix(1).uppercased() + parts[1].dropFirst()) (\(accent), \(gender))"
    }

    func makeRequest(path: String) throws -> URLRequest {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil
        else { throw SpeechError.invalidURL(baseURL) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw SpeechError.timedOut
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw SpeechError.unreachable(Transcriber.describe(error, host: request.url?.host(), port: request.url?.port))
        }
        guard let http = response as? HTTPURLResponse else { throw SpeechError.noAudio }
        guard (200..<300).contains(http.statusCode) else {
            throw SpeechError.http(status: http.statusCode, detail: Transcriber.snippet(of: data))
        }
        return data
    }
}
