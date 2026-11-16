import Foundation

/// Reads the `## Action items` checklist that `MeetingController.summaryPrompt` asks for:
/// `- [ ] <task> (owner: <Me, Them, or a name>, due: <date>)`. Only items owned by "Me" become task suggestions.
enum ActionItems {
    struct Item: Equatable {
        var title: String
        var owner: String?
        var due: String?
    }

    /// Every checklist item in the section, in order. "None." and a missing section give an empty list.
    static func parse(_ markdown: String) -> [Item] {
        entries(markdown).map(\.item)
    }

    /// One checklist line of the section, with its position in the text and whether it is ticked.
    private struct Entry {
        var line: Int
        var checked: Bool
        var item: Item
    }

    private static func entries(_ markdown: String) -> [Entry] {
        var inSection = false
        var found: [Entry] = []
        for (number, raw) in markdown.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
                inSection = heading == "action items"
                continue
            }
            guard inSection, let (checked, body) = checklistBody(line) else { continue }
            found.append(Entry(line: number, checked: checked, item: item(body)))
        }
        return found
    }

    /// The text of an item for comparing two summaries: case, runs of spaces and a closing full stop do not count.
    static func normalized(_ title: String) -> String {
        var text = title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = text.last, ".,;:!".contains(last) { text.removeLast() }
        return text
    }

    /// Ticks the items of a regenerated summary that were ticked in the one it replaces, matched by their text.
    /// An item the model worded differently comes back unticked.
    static func carryChecked(from old: String, into new: String) -> String {
        let ticked = Set(entries(old).filter(\.checked).map { normalized($0.item.title) })
        guard !ticked.isEmpty else { return new }
        var lines = new.components(separatedBy: "\n")
        for entry in entries(new) where !entry.checked && ticked.contains(normalized(entry.item.title)) {
            guard let box = lines[entry.line].range(of: "[ ]") else { continue }
            lines[entry.line].replaceSubrange(box, with: "[x]")
        }
        return lines.joined(separator: "\n")
    }

    /// The user's own items in a regenerated summary that the summary it replaces did not have. The ones it had were
    /// already offered, and the user may have skipped them.
    static func newMine(old: String?, new: String) -> [(title: String, due: String?)] {
        let known = Set((old.map(parse) ?? []).map { normalized($0.title) })
        return mine(new).filter { !known.contains(normalized($0.title)) }
    }

    /// The items that are the user's own, as suggestions for `TaskStore.suggest`.
    static func mine(_ markdown: String) -> [(title: String, due: String?)] {
        parse(markdown).filter { $0.owner.map { $0.caseInsensitiveCompare("me") == .orderedSame } ?? false }.map { ($0.title, $0.due) }
    }

    /// `- [ ] text` or `* [ ] text`, also already ticked ones, which are still open work from the meeting's view.
    private static func checklistBody(_ line: String) -> (checked: Bool, body: String)? {
        for prefix in ["- [ ]", "* [ ]", "- [x]", "- [X]", "* [x]", "* [X]"] where line.hasPrefix(prefix) {
            let body = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : (!prefix.hasSuffix("[ ]"), body)
        }
        return nil
    }

    /// Splits a trailing `(owner: …, due: …)` off the text. Text without it has no owner.
    private static func item(_ body: String) -> Item {
        guard body.hasSuffix(")"), let open = body.range(of: "(", options: .backwards) else { return Item(title: body) }
        let inside = body[open.upperBound..<body.index(before: body.endIndex)]
        var owner: String?
        var due: String?
        var inDue = false
        for part in inside.split(separator: ",") {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            switch pair.count == 2 ? pair[0].lowercased() : nil {
            case "owner": owner = pair[1]; inDue = false
            case "due": due = pair[1]; inDue = true
            default:
                // A date with a comma, as in `due: Nov 20, 2026`. An owner list keeps its first name only.
                if inDue, let start = due { due = start + ", " + part.trimmingCharacters(in: .whitespaces) }
            }
        }
        owner = owner.flatMap { $0.isEmpty ? nil : $0 }
        due = due.flatMap { $0.isEmpty ? nil : $0 }
        guard owner != nil || due != nil else { return Item(title: body) }
        let title = body[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
        return Item(title: title.isEmpty ? body : title, owner: owner, due: due)
    }
}
