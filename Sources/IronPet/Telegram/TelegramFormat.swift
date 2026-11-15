import Foundation

/// Turns the agent's Markdown into Telegram's HTML subset and splits it into messages Telegram accepts.
///
/// Telegram rejects a whole message when one tag is unbalanced, and caps a message at 4096 characters after
/// parsing. So conversion works line by line and checks every line's tags, and splitting measures the converted
/// text, not the Markdown. A split inside a code block closes the block and reopens it in the next message.
enum TelegramFormat {
    static let limit = 4096

    struct Part: Equatable {
        /// Telegram HTML, at most `limit` characters.
        let html: String
        /// The Markdown this part came from, for a plain-text retry when Telegram rejects the HTML.
        let source: String
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Splitting

    static func parts(_ markdown: String, limit: Int = TelegramFormat.limit) -> [Part] {
        var lines: [String] = []
        for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(contentsOf: pieces(String(line)))
        }
        var result: [Part] = []
        var current: [String] = []
        var fence: String?
        // Tracks the fence state of `current` so a flush knows whether to close and reopen a code block.
        func closed(_ lines: [String], _ fence: String?) -> [String] { fence == nil ? lines : lines + ["```"] }
        func flush() {
            let source = closed(current, fence).joined(separator: "\n")
            if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(Part(html: html(source), source: source))
            }
            current = fence.map { [$0] } ?? []
        }
        for line in lines {
            var nextFence = fence
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                nextFence = fence == nil ? line.trimmingCharacters(in: .whitespaces) : nil
            }
            let candidate = closed(current + [line], nextFence).joined(separator: "\n")
            if html(candidate).count > limit, !current.isEmpty, current != fence.map({ [$0] }) {
                flush()
            }
            current.append(line)
            fence = nextFence
        }
        flush()
        return result
    }

    /// A single line too long for one message becomes several. 700 characters stay under the limit even if every
    /// one becomes `&amp;`.
    private static func pieces(_ line: String) -> [String] {
        let size = 700
        guard line.count > size else { return [line] }
        // A line that fits in one message stays whole.
        guard max(html(line).count, escape(line).count) > limit - 100 else { return [line] }
        var out: [String] = []
        var rest = Substring(line)
        while !rest.isEmpty {
            var head = rest.prefix(size)
            if rest.count > size, let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > size / 2 {
                head = head[...space]
            }
            out.append(String(head))
            rest = rest.dropFirst(head.count)
        }
        return out
    }

    // MARK: Markdown to HTML

    static func html(_ markdown: String) -> String {
        var out: [String] = []
        var inFence = false
        // The first line of a code block joins its opening tag, and the closing tag joins the last line, so a block
        // does not gain blank lines.
        var glueNext = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    if out.isEmpty { out.append("") }
                    out[out.count - 1] += "</code></pre>"
                    glueNext = false
                } else {
                    let language = String(trimmed.dropFirst(3)).filter { $0.isLetter || $0.isNumber || "_+-#.".contains($0) }
                    out.append(language.isEmpty ? "<pre><code>" : "<pre><code class=\"language-\(language)\">")
                    glueNext = true
                }
                inFence.toggle()
                continue
            }
            let converted = inFence ? escape(line) : block(line)
            if glueNext, !out.isEmpty {
                out[out.count - 1] += converted
                glueNext = false
            } else {
                out.append(converted)
            }
        }
        if inFence { out[out.count - 1] += "</code></pre>" }
        return out.joined(separator: "\n")
    }

    private static func block(_ line: String) -> String {
        var text = line
        var heading = false
        if let match = text.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
            text = String(text[match.upperBound...])
            heading = true
        } else if let match = text.range(of: #"^(\s*)[-*+]\s+"#, options: .regularExpression) {
            let indent = String(text[match]).prefix { $0 == " " || $0 == "\t" }
            text = indent + "• " + text[match.upperBound...]
        }
        let converted = inline(text, allowBold: !heading)
        let result = heading && !converted.isEmpty ? "<b>\(converted)</b>" : converted
        return isBalanced(result) ? result : escape(line)
    }

    private static func inline(_ text: String, allowBold: Bool) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "`") {
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "`"), close > after else {
                break
            }
            out += styled(String(rest[..<open]), allowBold: allowBold)
            out += "<code>\(escape(String(rest[after..<close])))</code>"
            rest = rest[rest.index(after: close)...]
        }
        return out + styled(String(rest), allowBold: allowBold)
    }

    private static func styled(_ text: String, allowBold: Bool) -> String {
        var s = escape(text)
        s = s.replacingOccurrences(of: #"\[([^\]\n]+)\]\((https?://[^)\s"]+)\)"#, with: "<a href=\"$2\">$1</a>",
                                   options: .regularExpression)
        if allowBold {
            s = s.replacingOccurrences(of: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
            s = s.replacingOccurrences(of: #"(?<![\*\w])\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?![\*\w])"#, with: "<i>$1</i>",
                                       options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"~~(?=\S)(.+?)(?<=\S)~~"#, with: "<s>$1</s>", options: .regularExpression)
        return s
    }

    /// Whether every tag we emit is closed in order. Telegram refuses the whole message otherwise.
    static func isBalanced(_ html: String) -> Bool {
        var stack: [String] = []
        let pattern = try! NSRegularExpression(pattern: #"<(/?)([a-z]+)[^>]*>"#)
        let range = NSRange(html.startIndex..., in: html)
        for match in pattern.matches(in: html, range: range) {
            guard let slash = Range(match.range(at: 1), in: html), let name = Range(match.range(at: 2), in: html) else { continue }
            let tag = String(html[name])
            if html[slash].isEmpty {
                stack.append(tag)
            } else {
                guard stack.popLast() == tag else { return false }
            }
        }
        return stack.isEmpty
    }
}
