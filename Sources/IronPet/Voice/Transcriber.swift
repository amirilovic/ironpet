import Foundation

/// Why a transcription request failed. The messages are shown in the chat, so each names the status or the cause.
enum TranscriptionError: LocalizedError, Equatable {
    case invalidURL(String)
    case unreachable(String)
    case timedOut
    case http(status: Int, detail: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "The transcription base URL \"\(url)\" is not a valid http(s) URL."
        case .unreachable(let reason):
            return "Could not reach the transcription server: \(reason)"
        case .timedOut:
            return "The transcription server did not answer in time (timed out)."
        case .http(let status, let detail):
            var message = "The transcription server returned HTTP \(status)"
            if status == 401 || status == 403 { message += " (check the API key)" }
            return detail.isEmpty ? message + "." : message + ": " + detail
        case .malformedResponse:
            return "The transcription server's reply was not the expected JSON with a \"text\" field."
        }
    }
}

/// A stretch of speech with times in seconds from the start of the audio that was sent.
struct TimedSegment: Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

/// Client for the OpenAI transcription API: a multipart `POST {baseUrl}/audio/transcriptions`. Works with OpenAI,
/// Groq and local servers such as mlx-audio, which is why `response_format` is always sent: mlx-audio defaults to
/// `ndjson`.
struct Transcriber {
    var baseURL: String
    var model: String
    /// Sent as `Authorization: Bearer` only when non-empty. Servers without auth ignore it.
    var apiKey: String?
    var session: URLSession = .shared
    var timeout: TimeInterval = 120

    func transcribe(wav: Data) async throws -> String {
        let data = try await send(wav: wav, format: "json", filename: "voice-note.wav")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { throw TranscriptionError.malformedResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Meeting chunks: asks for `verbose_json` to get timed segments. A server that rejects it (OpenAI's
    /// `gpt-4o-*-transcribe` models answer 400) gets one retry with plain `json`. A server that answers with only
    /// `text` (mlx-audio does for Parakeet) yields one segment at the start of the chunk.
    func transcribeSegments(wav: Data) async throws -> [TimedSegment] {
        let data: Data
        do {
            data = try await send(wav: wav, format: "verbose_json", filename: "meeting.wav")
        } catch TranscriptionError.http(let status, _) where status == 400 || status == 422 {
            data = try await send(wav: wav, format: "json", filename: "meeting.wav")
        }
        return try Self.parseSegments(data)
    }

    /// Reads Whisper-style `segments` and Parakeet-style `sentences` (each with `start`, `end`, `text`), from one JSON
    /// object or from newline-delimited JSON. With neither, the whole `text` becomes one segment at 0.
    static func parseSegments(_ data: Data) throws -> [TimedSegment] {
        var objects: [[String: Any]] = []
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            objects = [object]
        } else {
            objects = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }
        guard !objects.isEmpty else { throw TranscriptionError.malformedResponse }
        var timed: [TimedSegment] = []
        var text: String?
        for object in objects {
            if let value = object["text"] as? String { text = (text ?? "") + value }
            let list = (object["segments"] as? [[String: Any]]) ?? (object["sentences"] as? [[String: Any]]) ?? []
            for item in list {
                guard let words = item["text"] as? String,
                      let start = (item["start"] as? NSNumber)?.doubleValue else { continue }
                let end = (item["end"] as? NSNumber)?.doubleValue ?? start
                timed.append(TimedSegment(start: start, end: max(start, end),
                                          text: words.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        if !timed.isEmpty { return timed }
        guard let text else { throw TranscriptionError.malformedResponse }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [TimedSegment(start: 0, end: 0, text: trimmed)]
    }

    /// One multipart POST. Returns the body of a 2xx answer.
    private func send(wav: Data, format: String, filename: String) async throws -> Data {
        var request = try makeRequest()
        let boundary = "ironpet-" + UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let body = Self.multipartBody(boundary: boundary, wav: wav, model: model, format: format, filename: filename)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, from: body)
        } catch let error as URLError where error.code == .timedOut {
            throw TranscriptionError.timedOut
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw TranscriptionError.unreachable(Self.describe(error, host: request.url?.host(), port: request.url?.port))
        }
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw TranscriptionError.http(status: http.statusCode, detail: Self.snippet(of: data))
        }
        return data
    }

    func makeRequest() throws -> URLRequest {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/audio/transcriptions"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil
        else { throw TranscriptionError.invalidURL(baseURL) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func multipartBody(boundary: String, wav: Data, model: String, format: String = "json",
                              filename: String = "voice-note.wav") -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", format)
        body.append(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
            + "Content-Type: audio/wav\r\n\r\n").utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func describe(_ error: URLError, host: String?, port: Int?) -> String {
        let place = [host, port.map(String.init)].compactMap { $0 }.joined(separator: ":")
        switch error.code {
        case .cannotConnectToHost:
            return "connection refused at \(place). Is the server running?"
        case .networkConnectionLost:
            return "connection to \(place) was lost."
        case .cannotFindHost, .dnsLookupFailed:
            return "cannot find host \(host ?? "")."
        case .notConnectedToInternet:
            return "no network connection."
        default:
            return error.localizedDescription
        }
    }

    /// The start of an error body, which servers usually send as JSON or plain text.
    private static func snippet(of data: Data) -> String {
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = object["error"] as? String ?? object["detail"] as? String ?? object["message"] as? String { return message }
        }
        return text
    }
}
