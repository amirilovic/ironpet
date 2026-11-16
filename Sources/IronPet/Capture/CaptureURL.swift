import Foundation

/// URL handling shared by thread keys and storage. Secrets never survive it. This is part of the hard floor: no rule can switch it off.
enum CaptureURL {
    /// Query and fragment parameter names whose values are removed (compared case-insensitively). The list lives with the other secret
    /// patterns in `CaptureRedactor`, which uses it for URLs inside text.
    static var secretParams: Set<String> { CaptureRedactor.secretURLParams }

    private static let specialSchemes: Set<String> = ["http", "https", "ws", "wss", "ftp", "file"]
    private static let defaultPorts = ["http": 80, "https": 443, "ws": 80, "wss": 443, "ftp": 21]

    private static func isSecretName(_ raw: String) -> Bool {
        let decoded = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
        return secretParams.contains(decoded.lowercased())
    }

    private static func filterPairs(_ raw: String) -> String {
        raw.split(separator: "&", omittingEmptySubsequences: true).filter { pair in
            let name = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return !isSecretName(name)
        }.joined(separator: "&")
    }

    /// A parsed absolute URL, or nil for text that is not one.
    private static func parse(_ input: String) -> URLComponents? {
        guard let components = URLComponents(string: input), let scheme = components.scheme, !scheme.isEmpty else { return nil }
        return components
    }

    /// Removes secret query and fragment parameters, userinfo, and an empty `?` or `#`. Fragments that look like query strings
    /// (`#a=1&code=x`, `#/route?code=x`) are filtered too. Text that is not an absolute URL comes back unchanged.
    static func redact(_ input: String) -> String {
        guard var url = parse(input) else { return input }
        url.scheme = url.scheme?.lowercased()
        url.host = url.host?.lowercased()
        url.user = nil
        url.password = nil
        if let scheme = url.scheme, let port = url.port, defaultPorts[scheme] == port { url.port = nil }
        if let scheme = url.scheme, specialSchemes.contains(scheme), url.host != nil, url.percentEncodedPath.isEmpty { url.percentEncodedPath = "/" }
        if let query = url.percentEncodedQuery {
            let kept = filterPairs(query)
            url.percentEncodedQuery = kept.isEmpty ? nil : kept
        }
        if let fragment = url.percentEncodedFragment {
            let kept: String
            if let mark = fragment.firstIndex(of: "?") {
                let route = String(fragment[..<mark])
                let query = filterPairs(String(fragment[fragment.index(after: mark)...]))
                kept = query.isEmpty ? route : "\(route)?\(query)"
            } else if fragment.contains("=") {
                kept = filterPairs(fragment)
            } else {
                kept = fragment
            }
            url.percentEncodedFragment = kept.isEmpty ? nil : kept
        }
        return url.string ?? input
    }

    /// The lowercase host of a URL string, if any.
    static func host(_ input: String) -> String? {
        guard let host = parse(input)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// True when `host` equals `pattern` or, for a `.example.com` pattern, is a host below it. A `*.example.com` pattern also matches
    /// the bare `example.com`.
    static func hostMatches(_ host: String, _ pattern: String) -> Bool {
        let host = host.lowercased()
        let pattern = pattern.lowercased()
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return host == suffix || host.hasSuffix("." + suffix)
        }
        if pattern.hasPrefix(".") { return host.hasSuffix(pattern) }
        return host == pattern
    }

    /// A stable key for a page URL: lowercase scheme and host, no default port, no trailing slash on the path, secrets removed.
    static func normalize(_ input: String) -> String {
        let redacted = redact(input)
        guard let url = parse(redacted) else { return redacted }
        var out = "\(url.scheme ?? "")://\(url.host ?? "")"
        if let port = url.port { out += ":\(port)" }
        var path = url.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        out += path
        if let query = url.percentEncodedQuery { out += "?\(query)" }
        if let fragment = url.percentEncodedFragment { out += "#\(fragment)" }
        return out
    }

    /// Replaces every URL with a scheme inside free text by its redacted form.
    static func redactURLs(in text: String) -> String {
        guard text.contains("://") else { return text }
        var out = ""
        var rest = Substring(text)
        while let range = rest.range(of: "://") {
            var start = range.lowerBound
            while start > rest.startIndex {
                let before = rest.index(before: start)
                guard rest[before].isASCII, rest[before].isLetter else { break }
                start = before
            }
            let end = rest[range.lowerBound...].firstIndex(where: { $0.isWhitespace || "\"'<>".contains($0) }) ?? rest.endIndex
            out += rest[..<start]
            out += redact(String(rest[start..<end]))
            rest = rest[end...]
        }
        out += rest
        return out
    }
}
