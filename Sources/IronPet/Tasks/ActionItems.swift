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
        var inSection = false
        var items: [Item] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
                inSection = heading == "action items"
                continue
            }
            guard inSection, let body = checklistBody(line) else { continue }
            items.append(item(body))
        }
        return items
    }

    /// The items that are the user's own, as suggestions for `TaskStore.suggest`.
    static func mine(_ markdown: String) -> [(title: String, due: String?)] {
        parse(markdown).filter { $0.owner.map { $0.caseInsensitiveCompare("me") == .orderedSame } ?? false }.map { ($0.title, $0.due) }
    }

    /// `- [ ] text` or `* [ ] text`, also already ticked ones, which are still open work from the meeting's view.
    private static func checklistBody(_ line: String) -> String? {
        for prefix in ["- [ ]", "* [ ]", "- [x]", "- [X]", "* [x]", "* [X]"] where line.hasPrefix(prefix) {
            let body = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : body
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
