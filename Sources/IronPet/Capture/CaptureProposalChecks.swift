import Foundation

/// Checks that run on what the larger model suggests, before anything shows up as a bubble. The model is told the same things in its
/// prompt, but a prompt does not bind it, so these hold the line: a suggestion needs a real quote, UI text and error banners are not
/// commitments, a due date needs a date in the text, and one thing is suggested once.
enum CaptureProposalChecks {
    // MARK: Words

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "have", "once", "are", "was", "were", "will", "you", "your", "can", "could", "should",
        "please", "about", "into", "when", "then", "than", "them", "they", "its", "has", "had", "not", "but", "all", "any", "out", "get", "make",
    ]

    /// Lowercase, without accents, quotes and extra spaces.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "#" || $0 == "-" ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(normalize(text).split(separator: " ").map(String.init).filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    private static let identifierPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"\b[A-Z][A-Z0-9]{1,9}-\d{1,7}\b"#),
        try! NSRegularExpression(pattern: #"(?:#|\bPR\s*#?|\bpull request\s*#?|\bissue\s*#?)(\d{2,})"#, options: [.caseInsensitive]),
    ]

    private static let notTickets: Set<String> = ["utf", "iso", "sha", "md", "covid", "aes", "rsa", "wpa", "gpt", "ipv", "tls", "ssl", "http", "x", "h", "rfc"]

    /// Ticket keys (`SSP-11671`) and PR or issue numbers (`#4641`, `PR 4641`), which name one thing however it is worded.
    static func identifiers(_ text: String) -> Set<String> {
        var found: Set<String> = []
        let range = NSRange(text.startIndex..., in: text)
        for match in identifierPatterns[0].matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            let key = text[r].lowercased()
            // UTF-8, SHA-256 and the like look like ticket keys but name no ticket.
            if let prefix = key.split(separator: "-").first, notTickets.contains(String(prefix)) { continue }
            found.insert(key)
        }
        for match in identifierPatterns[1].matches(in: text, range: range) {
            if let r = Range(match.range(at: 1), in: text) { found.insert("#" + text[r]) }
        }
        return found
    }

    /// The share of the smaller word set that the other one holds, and the overlap of both.
    private static func overlap(_ a: Set<String>, _ b: Set<String>) -> (jaccard: Double, containment: Double, shared: Int) {
        let shared = a.intersection(b).count
        guard shared > 0 else { return (0, 0, 0) }
        return (Double(shared) / Double(a.union(b).count), Double(shared) / Double(min(a.count, b.count)), shared)
    }

    // MARK: The quote

    /// The whole sentence, or the whole message when no single sentence holds it, that the quote comes from, with the author's name
    /// taken off. Nil when the quote is not in the cited text: a suggestion the text does not back is dropped. A quote that is a fragment
    /// of a sentence becomes the sentence.
    static func resolveQuote(_ quote: String, in bodies: [String]) -> String? {
        let wanted = normalize(quote)
        guard !wanted.isEmpty else { return nil }
        let lines = bodies.flatMap { $0.split(whereSeparator: \.isNewline).map { String($0) } }
        func stripAuthor(_ line: String) -> String {
            guard let colon = line.range(of: ": "), line.distance(from: line.startIndex, to: colon.lowerBound) <= 30 else { return line }
            return String(line[colon.upperBound...])
        }
        func sentences(of line: String) -> [String] {
            var out: [String] = []
            var current = ""
            // A full stop ends a sentence only before a space or at the end, so "3.5", "e.g." inside a word and "example.com" stay whole.
            let characters = Array(line)
            for (index, character) in characters.enumerated() {
                current.append(character)
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if "。！？".contains(character) || (".?!".contains(character) && (next == nil || next!.isWhitespace)) { out.append(current); current = "" }
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append(current) }
            return out.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func cap(_ text: String) -> String { text.count > 280 ? String(text.prefix(280)) + "…" : text }
        // Verbatim, up to case, accents and punctuation.
        for line in lines where normalize(line).contains(wanted) {
            let message = stripAuthor(line)
            if let sentence = sentences(of: message).first(where: { normalize($0).contains(wanted) }) { return cap(sentence) }
            return cap(message)
        }
        // A quote that runs over two neighbouring lines of one message.
        for index in lines.indices.dropLast() where normalize(lines[index] + " " + lines[index + 1]).contains(wanted) {
            return cap(quote.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // A slightly reworded quote still counts when almost all of its words are in one line.
        let words = Set(wanted.split(separator: " ").map(String.init))
        guard words.count >= 3 else { return nil }
        for line in lines {
            let lineWords = Set(normalize(line).split(separator: " ").map(String.init))
            if Double(words.intersection(lineWords).count) / Double(words.count) >= 0.8 { return cap(stripAuthor(line)) }
        }
        return nil
    }

    // MARK: Interface text and errors

    /// Labels of buttons and menus. A quote that is only one of these is not something a person wrote.
    private static let chromeLabels: Set<String> = [
        "send", "stop", "retry", "resend", "regenerate", "copy", "cancel", "continue", "edit", "new chat", "try again", "stop generating",
        "retry last message", "regenerate response", "show more", "show less", "open chat", "dismiss", "reload", "refresh",
    ]

    /// Phrases that mark an error banner or a status line, not a message to the user.
    private static let errorStarts = ["error", "failed to", "the agent stopped", "agent stopped", "something went wrong", "request failed", "an error occurred",
                                      "connection lost", "rate limit"]

    /// True when the quote is interface text, such as a button label, or an error banner. Agents in a chat show both next to their replies.
    static func isInterfaceText(quote: String, title: String) -> Bool {
        let q = normalize(quote)
        if chromeLabels.contains(q) { return true }
        // Several labels in a row ("Send Stop") are still only labels. A sentence that merely contains one ("Please try again by Friday") is not.
        var rest = " " + q + " "
        for label in chromeLabels.sorted(by: { $0.count > $1.count }) { rest = rest.replacingOccurrences(of: " \(label) ", with: "  ") }
        if !q.isEmpty, rest.allSatisfy({ $0 == " " }) { return true }
        // Whole words only, so "Errors in the report need a fix" is not a banner.
        if errorStarts.contains(where: { q == $0 || q.hasPrefix($0 + " ") }) && !quote.contains("?") { return true }
        let t = normalize(title)
        return chromeLabels.contains(t)
    }

    // MARK: Due dates

    private static let months: [(names: [String], number: Int)] = [
        (["january", "jan", "januar", "januara"], 1), (["february", "feb", "februar", "februara"], 2), (["march", "mar", "marz", "mart", "marta"], 3),
        (["april", "apr", "aprila"], 4), (["may", "mai", "maj", "maja"], 5), (["june", "jun", "juni", "juna"], 6), (["july", "jul", "juli", "jula"], 7),
        (["august", "aug", "avgust", "avgusta"], 8), (["september", "sep", "sept", "septembar", "septembra"], 9),
        (["october", "oct", "oktober", "oktobar", "oktobra"], 10), (["november", "nov", "novembar", "novembra"], 11),
        (["december", "dec", "dez", "dezember", "decembar", "decembra"], 12),
    ]

    private static let relativeWords: Set<String> = [
        "today", "tonight", "tomorrow", "tmrw", "yesterday", "eod", "eow", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "heute", "morgen", "ubermorgen", "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonntag",
        "danas", "veceras", "sutra", "sjutra", "prekosutra", "ponedeljak", "ponedeljka", "utorak", "utorka", "sreda", "sredu", "sredom", "cetvrtak", "cetvrtka",
        "petak", "petka", "petku", "subota", "subotu", "subote", "nedelja", "nedelju", "nedelje",
        "hoy", "manana", "lunes", "martes", "miercoles", "jueves", "viernes", "demain", "lundi", "mardi", "mercredi", "jeudi", "vendredi",
    ]

    private static let relativePhrases = ["next week", "this week", "next month", "end of day", "end of the day", "end of week", "end of the week",
                                          "end of month", "end of the month", "nachste woche", "diese woche", "sledece nedelje", "ove nedelje", "sledece sedmice"]

    private static let relativeCount = try! NSRegularExpression(pattern: #"\b(in|za|innerhalb von)\s+\d+\s+(minute|minutes|min|hour|hours|day|days|week|weeks|dan|dana|sata|sati|nedelju|tage|tagen|stunden)\b"#)

    /// Whether `text` says when: the due date itself, a day and month that match it, or a clear relative day such as "tomorrow", "Friday" or
    /// "in 3 days". A date the agent worked out with nothing in the text behind it does not count.
    static func dueIsStated(_ due: String, in text: String) -> Bool {
        let folded = normalize(text)
        let raw = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let digits = due.prefix(10).split(separator: "-").compactMap { Int($0) }
        if digits.count == 3 {
            let (year, month, day) = (digits[0], digits[1], digits[2])
            if raw.contains(String(due.prefix(10))) { return true }
            for entry in months where entry.number == month {
                for name in entry.names {
                    if matches(#"\b\#(day)(st|nd|rd|th)?\.?\s*(of\s+)?\#(name)\b"#, in: raw) || matches(#"\b\#(name)\.?\s+\#(day)(st|nd|rd|th)?\b"#, in: raw) { return true }
                }
            }
            let twoDigitYear = year % 100
            let numeric = [#"\b0?\#(day)[./]\s?0?\#(month)\b"#, #"\b0?\#(month)/0?\#(day)\b"#, #"\b0?\#(day)-0?\#(month)-(\#(year)|\#(twoDigitYear))\b"#]
            if numeric.contains(where: { matches($0, in: raw) }) { return true }
        }
        let words = Set(folded.split(separator: " ").map(String.init))
        if !words.isDisjoint(with: relativeWords) { return true }
        if relativePhrases.contains(where: { folded.contains($0) }) { return true }
        return relativeCount.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded)) != nil
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The quoted line and the lines next to it, where a date for the item would be.
    static func surroundingText(of quoted: String, in bodies: [String]) -> String {
        let lines = bodies.flatMap { $0.split(whereSeparator: \.isNewline).map { String($0) } }
        let wanted = normalize(quoted)
        guard let index = lines.firstIndex(where: { normalize($0).contains(wanted) }) else { return quoted }
        return lines[max(0, index - 1)...min(lines.count - 1, index + 1)].joined(separator: "\n")
    }

    // MARK: Duplicates

    /// Whether two suggestions are about the same thing: they name the same ticket or PR, or their titles are close.
    static func sameThing(_ a: CaptureProposal, _ b: CaptureProposal) -> Bool {
        let idsA = identifiers(of: a), idsB = identifiers(of: b)
        if !idsA.isDisjoint(with: idsB) { return true }
        // Two different tickets stay apart however alike the titles are.
        if !idsA.isEmpty, !idsB.isEmpty { return false }
        return titlesClose(a.title, b.title)
    }

    /// The tickets and PRs a suggestion is about. Its title and notes say that; the quote is a whole sentence that may mention others in passing,
    /// so it counts only when the title and notes name none.
    private static func identifiers(of proposal: CaptureProposal) -> Set<String> {
        let own = identifiers([proposal.title, proposal.notes].joined(separator: " "))
        return own.isEmpty ? identifiers(proposal.quote) : own
    }

    /// Titles that share nearly all their words. Two titles that differ in one name or object ("Reply to Dana about the offsite" and
    /// "... about the budget") are two things.
    private static func titlesClose(_ a: String, _ b: String) -> Bool {
        let o = overlap(tokens(a), tokens(b))
        return o.jaccard >= 0.7 || (o.shared >= 4 && o.containment >= 0.8)
    }

    /// Two events on different days are two events, however alike their titles are.
    private static func differentDays(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.prefix(10) != b.prefix(10)
    }

    /// The suggestion with its sources and quote merged into the first of the group that carries the most weight: an update, then a new
    /// task, then a follow-up. A calendar item only merges with another calendar item.
    static func mergeDuplicates(_ proposals: [CaptureProposal]) -> [CaptureProposal] {
        func weight(_ kind: CaptureProposal.Kind) -> Int {
            switch kind {
            case .update: return 0
            case .newTask: return 1
            case .followUp: return 2
            case .calendar: return 3
            }
        }
        var groups: [[CaptureProposal]] = []
        for proposal in proposals {
            if let index = groups.firstIndex(where: { group in
                group.contains { other in
                    (proposal.kind == .calendar) == (other.kind == .calendar)
                        && (proposal.taskId != nil && proposal.taskId == other.taskId || sameThing(proposal, other))
                        && !(proposal.kind == .calendar && differentDays(proposal.due, other.due))
                }
            }) {
                groups[index].append(proposal)
            } else {
                groups.append([proposal])
            }
        }
        return groups.map { group in
            var best = group.min { weight($0.kind) < weight($1.kind) }!
            for other in group where other.id != best.id {
                best.sources = Array(Set(best.sources + other.sources)).sorted()
                if best.due == nil { best.due = other.due }
                if best.quote.isEmpty { best.quote = other.quote }
                // Two updates to one task keep both changes.
                if best.kind == .update, other.kind == .update, best.taskId == other.taskId {
                    if best.status == nil { best.status = other.status }
                    best.diff += other.diff.filter { !best.diff.contains($0) }
                }
            }
            return best
        }
    }

    /// Whether an existing task already covers a suggestion. An open task covers it when they name the same ticket or PR or their titles are
    /// close. A done task covers it only when the titles are nearly the same, so new talk about old work is not hidden.
    static func coveredByTask(_ proposal: CaptureProposal, tasks: [CaptureTask]) -> Bool {
        let proposalIds = identifiers(of: proposal)
        let proposalTokens = tokens(proposal.title)
        for task in tasks {
            let o = overlap(proposalTokens, tokens(task.title))
            if task.isDone {
                if o.jaccard >= 0.8 { return true }
                continue
            }
            let taskIds = identifiers(task.title + " " + task.notes)
            if !proposalIds.isEmpty, !proposalIds.isDisjoint(with: taskIds) { return true }
            if !proposalIds.isEmpty, !identifiers(task.title).isEmpty, identifiers(task.title).isDisjoint(with: proposalIds) { continue }
            if titlesClose(proposal.title, task.title) { return true }
        }
        return false
    }
}
