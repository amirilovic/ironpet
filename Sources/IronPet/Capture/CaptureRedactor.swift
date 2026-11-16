import Foundation

/// Rule-based redaction of secrets in captured text, in the style of gitleaks and secretlint. It runs first, for every item, before anything is
/// stored for the model or sent: each secret span becomes `[redacted:<kind>]`. The decision model then scores the redacted text, so a key
/// in an otherwise useful message no longer costs the whole message. This is the one place with secret patterns: provider keys, tokens,
/// private keys, credentials in URLs and secret query parameters, `password=`-style assignments, card and bank numbers and long
/// high-entropy strings.
enum CaptureRedactor {
    /// What was redacted: how many spans, by kind.
    struct Report: Equatable {
        var kinds: [String: Int] = [:]

        var count: Int { kinds.values.reduce(0, +) }
        var isEmpty: Bool { kinds.isEmpty }

        mutating func add(_ kind: String, _ n: Int = 1) { kinds[kind, default: 0] += n }
        mutating func merge(_ other: Report) { for (kind, n) in other.kinds { add(kind, n) } }

        /// `3 spans (aws-key 1, url-param 2)`, or `nothing redacted`.
        var summary: String {
            guard !isEmpty else { return "nothing redacted" }
            let list = kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            return "redacted \(count) span\(count == 1 ? "" : "s") (\(list))"
        }

        var json: String? {
            isEmpty ? nil : (try? JSONEncoder().encode(kinds)).map { String(decoding: $0, as: UTF8.self) }
        }

        init() {}

        init?(json: String?) {
            guard let json, let kinds = try? JSONDecoder().decode([String: Int].self, from: Data(json.utf8)) else { return nil }
            self.kinds = kinds
        }
    }

    // MARK: Detectors

    /// Query and fragment parameter names whose values are secrets, in lowercase. Also used by `CaptureURL` for the URL of an item.
    static let secretURLParams: Set<String> = [
        "code", "token", "access_token", "id_token", "refresh_token", "state", "password", "passwd", "pwd", "sig", "signature", "key",
        "api_key", "apikey", "secret", "client_secret", "auth", "session", "sessionid", "x-amz-signature", "x-amz-credential",
        "x-amz-security-token",
    ]

    /// A pattern whose whole match is replaced.
    private struct Whole {
        let kind: String
        let regex: NSRegularExpression
    }

    private static func whole(_ kind: String, _ pattern: String, options: NSRegularExpression.Options = []) -> Whole {
        Whole(kind: kind, regex: try! NSRegularExpression(pattern: pattern, options: options))
    }

    /// Run in order. Private keys first, so their body is not cut up by the others.
    private static let wholeDetectors: [Whole] = [
        whole("private-key", #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----"#),
        whole("private-key", #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[A-Za-z0-9+/=\s]{20,}"#),
        whole("aws-key", #"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ABIA|ACCA)[A-Z0-9]{16}\b"#),
        whole("github-token", #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#),
        whole("github-token", #"\bgithub_pat_[A-Za-z0-9_]{30,}\b"#),
        whole("gitlab-token", #"\bglpat-[A-Za-z0-9_-]{20,}\b"#),
        whole("anthropic-key", #"\bsk-ant-[A-Za-z0-9_-]{20,}\b"#),
        whole("api-key", #"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}\b"#),
        whole("stripe-key", #"\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{16,}\b"#),
        whole("stripe-key", #"\bwhsec_[A-Za-z0-9]{20,}\b"#),
        whole("slack-token", #"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#),
        whole("slack-webhook", #"https://hooks\.slack\.com/services/[A-Z0-9]+/[A-Z0-9]+/[A-Za-z0-9]+"#),
        whole("google-key", #"\bAIza[0-9A-Za-z_-]{35}\b"#),
        whole("npm-token", #"\bnpm_[A-Za-z0-9]{30,}\b"#),
        whole("sendgrid-key", #"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b"#),
        whole("bearer-token", #"\b(?:Bearer|bearer|BEARER)\s+[A-Za-z0-9._~+/=-]{16,}"#),
        whole("jwt", #"\bey[A-Za-z0-9_-]{10,}\.ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#),
        whole("iban", #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,4})?\b"#),
    ]

    /// `scheme://user:password@host`: the password and user go, the host stays.
    private static let urlCredentials = try! NSRegularExpression(pattern: #"\b([A-Za-z][A-Za-z0-9+.-]{0,30}://)[^\s/:@]{1,200}:[^\s/@]{1,200}@"#)

    /// `?token=abc` and `&code=abc` in a URL inside text.
    private static let urlParam: NSRegularExpression = {
        let names = secretURLParams.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return try! NSRegularExpression(pattern: #"([?&#;])("# + names + #")=([^\s&#"'<>)\]]+)"#, options: [.caseInsensitive])
    }()

    /// `password = hunter2`, `API_KEY=...`, `"token": "..."`, `secret is ...`, `Authorization: Bearer ...` and .env lines with such a name.
    /// The name ends at the keyword or after a separator (`token_url`, `secret.key`), so `author`, `secretary`, `tokenizer` and `max_tokens`
    /// are not names. Both sides are bounded, so a long run of name characters cannot make the match slow.
    private static let assignment = try! NSRegularExpression(
        pattern: #"(?i)\b([A-Za-z0-9_.-]{0,40}(?:password|passwd|pwd|passcode|secret|token|api[_-]?key|apikey|access[_-]?key|private[_-]?key|client[_-]?secret|credentials?|auth(?:orization)?)(?:[_.-][A-Za-z0-9_.-]{0,40})?)(["']?\s*(?:=|:|\bis\b)\s*["']?)((?:bearer|basic)\s+)?([^\s"',;]{4,})"#)

    private static let card = try! NSRegularExpression(pattern: #"\b(?:\d[ -]?){13,19}\b"#)

    /// Candidates for the entropy check: long runs of key-like characters.
    private static let longToken = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/=_-]{32,}(?![A-Za-z0-9+/=_-])"#)

    // MARK: Helpers

    private static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            var value = digit
            if index % 2 == 1 { value *= 2; if value > 9 { value -= 9 } }
            sum += value
        }
        return sum % 10 == 0
    }

    /// Bits per character.
    private static func entropy(_ text: String) -> Double {
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        let total = Double(text.count)
        return -counts.values.reduce(0.0) { $0 + (Double($1) / total) * log2(Double($1) / total) }
    }

    /// Whether the value of an assignment looks like a secret and not a word ("token: expired") or a placeholder ("password=<your password>").
    /// `strong` is an `=` assignment, where any value that is not a placeholder counts.
    private static func looksSecret(_ value: String, strong: Bool) -> Bool {
        let lower = value.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return false }
        if lower.hasPrefix("[redacted") || ["$", "<", "{", "%", "*", "(", "["].contains(where: { value.hasPrefix($0) }) { return false }
        if ["xxx", "your", "changeme", "example", "placeholder", "null", "none", "true", "false", "undefined"].contains(where: { lower.hasPrefix($0) }) { return false }
        // `password=hunter` is an assignment whatever the value looks like. A short number is not (`token: 5`, `tokens=4096`).
        if value.allSatisfy(\.isNumber), value.count < 6 { return false }
        if strong { return true }
        let hasDigit = value.contains { $0.isNumber }
        let hasSymbol = value.contains { "-_/+=.@!#$%^&*".contains($0) }
        let mixedCase = value.contains { $0.isUppercase } && value.contains { $0.isLowercase }
        return hasDigit || hasSymbol || mixedCase || value.count >= 12
    }

    // MARK: Redaction

    /// `text` with every secret span replaced by `[redacted:<kind>]`, and what was found.
    static func redact(_ text: String) -> (text: String, report: Report) {
        var report = Report()
        var out = text

        // NSString ranges, so a match that ends inside a grapheme cluster (a key followed by a combining mark) is still replaced.
        func apply(_ regex: NSRegularExpression, kind: String, replacement: (NSTextCheckingResult, NSString) -> String?) {
            let source = out as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: out, range: NSRange(location: 0, length: source.length)) {
                guard let new = replacement(match, source) else { continue }
                result += source.substring(with: NSRange(location: last, length: match.range.location - last))
                result += new
                last = match.range.location + match.range.length
                report.add(kind)
            }
            result += source.substring(from: last)
            out = result
        }
        func group(_ match: NSTextCheckingResult, _ n: Int, in text: NSString) -> String {
            match.range(at: n).location == NSNotFound ? "" : text.substring(with: match.range(at: n))
        }

        for detector in wholeDetectors {
            apply(detector.regex, kind: detector.kind) { _, _ in "[redacted:\(detector.kind)]" }
        }
        apply(urlCredentials, kind: "url-credentials") { match, text in
            // Redacted text goes through here again at send time, and must come out the same and uncounted.
            guard !text.substring(with: match.range).contains("[redacted:") else { return nil }
            return "\(group(match, 1, in: text))[redacted:url-credentials]@"
        }
        apply(urlParam, kind: "url-param") { match, text in
            guard !group(match, 3, in: text).hasPrefix("[redacted") else { return nil }
            return "\(group(match, 1, in: text))\(group(match, 2, in: text))=[redacted:url-param]"
        }
        apply(assignment, kind: "secret-assignment") { match, text in
            let value = group(match, 4, in: text)
            let separator = group(match, 2, in: text)
            guard looksSecret(value, strong: separator.contains("=")) else { return nil }
            return "\(group(match, 1, in: text))\(separator)\(group(match, 3, in: text))[redacted:secret-assignment]"
        }
        apply(card, kind: "card-number") { match, text in
            let matched = group(match, 0, in: text)
            let digits = matched.compactMap { $0.wholeNumberValue }
            // Card numbers start with 2 to 6 (Visa, Mastercard, Amex, Discover, UnionPay). A run of years or a timestamp passes Luhn one time in ten.
            guard (13...19).contains(digits.count), (2...6).contains(digits[0]), luhn(digits) else { return nil }
            // The pattern may take the space after the last digit with it, which belongs to the sentence.
            return "[redacted:card-number]" + (matched.last.map { " -".contains($0) ? String($0) : "" } ?? "")
        }
        apply(longToken, kind: "high-entropy") { match, text in
            let token = group(match, 0, in: text)
            // Hashes, UUIDs and words are long too. A secret mixes letters and digits and is close to random.
            guard token.contains(where: \.isLetter), token.contains(where: \.isNumber), !token.contains("--"), entropy(token) >= 4.2 else { return nil }
            return "[redacted:high-entropy]"
        }
        return (out, report)
    }

    static func redact(_ text: String?) -> (text: String?, report: Report) {
        guard let text else { return (nil, Report()) }
        let result = redact(text)
        return (result.text, result.report)
    }
}
