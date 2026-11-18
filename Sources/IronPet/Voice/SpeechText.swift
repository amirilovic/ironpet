import Foundation
import NaturalLanguage

/// Turns a markdown reply into the text Ghost reads aloud: prose only, in short chunks so the first one can play
/// while the next is synthesized.
enum SpeechText {
    /// About a minute of speech. Reading stops at the end of the sentence that reaches it.
    static let maxCharacters = 900
    /// Chunks after the first are grouped up to about this length; the first is one sentence so speech starts soon.
    static let chunkCharacters = 220

    static func chunks(of markdown: String, limit: Int = maxCharacters) -> [String] {
        var sentences: [String] = []
        var total = 0
        blocks: for text in spokenBlocks(of: markdown) {
            for sentence in self.sentences(in: text) {
                guard total < limit else { break blocks }
                // A single run-on sentence must not blow through the limit on its own.
                let kept = sentence.count > limit ? truncated(sentence, to: limit) : sentence
                sentences.append(kept)
                total += kept.count + 1
            }
        }
        guard let first = sentences.first else { return [] }
        var chunks = [first]
        var current = ""
        for sentence in sentences.dropFirst() {
            if !current.isEmpty, current.count + sentence.count + 1 > chunkCharacters {
                chunks.append(current)
                current = ""
            }
            current = current.isEmpty ? sentence : current + " " + sentence
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Headings, paragraphs, quotes and list items, with inline markup removed. Code, tables and rules are skipped:
    /// read aloud they are noise.
    static func spokenBlocks(of markdown: String) -> [String] {
        Markdown.parse(markdown).flatMap { block -> [String] in
            switch block {
            case .paragraph, .quote:
                return Markdown.segments(of: block).map { clean($0) }
            case .heading, .list:
                // A heading or item without closing punctuation still gets a pause before the next one.
                return Markdown.segments(of: block).map { ending(clean($0)) }
            case .code, .table, .rule:
                return []
            }
        }.filter { !$0.isEmpty }
    }

    private static let bareURL = try! NSRegularExpression(pattern: #"https?://\S+"#)

    static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let withoutURLs = bareURL.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return withoutURLs.filter { !isEmoji($0) }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Emoji are read out by name ("ghost", "party popper"), so they are dropped. Digits, `#` and `*` also carry the
    /// emoji property, so a lone scalar counts only when it shows as emoji by default.
    private static func isEmoji(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && character.unicodeScalars.count > 1)
    }

    private static func ending(_ text: String) -> String {
        guard let last = text.last, !".!?:;".contains(last) else { return text }
        return text + "."
    }

    private static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            return true
        }
        return result
    }

    private static func truncated(_ sentence: String, to limit: Int) -> String {
        let prefix = sentence.prefix(limit)
        guard let space = prefix.lastIndex(of: " ") else { return String(prefix) }
        return String(prefix[..<space]) + "…"
    }
}
