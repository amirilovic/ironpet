import Foundation

/// One command from the agent's `available_commands_update`.
struct SlashCommand: Identifiable, Hashable {
    let name: String
    let detail: String
    let hint: String?
    var id: String { name }

    init(name: String, detail: String = "", hint: String? = nil) {
        self.name = name
        self.detail = detail
        self.hint = hint
    }

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        self.init(name: name, detail: json["description"] as? String ?? "",
                  hint: (json["input"] as? [String: Any])?["hint"] as? String)
    }

    static func parse(_ list: [[String: Any]]) -> [SlashCommand] {
        // Names identify rows in the popup, so a repeated name keeps only its first entry.
        var seen = Set<String>()
        return list.compactMap(SlashCommand.init(json:)).filter { seen.insert($0.name).inserted }
    }

    /// Commands the popup offers for this input. Empty unless the input starts with `/` and has no space, tab or newline yet.
    /// Prefix matches on the name come first, then substring matches.
    static func matches(for input: String, in commands: [SlashCommand]) -> [SlashCommand] {
        guard input.hasPrefix("/"), !input.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else { return [] }
        let query = input.dropFirst().lowercased()
        if query.isEmpty { return commands }
        let prefix = commands.filter { $0.name.lowercased().hasPrefix(query) }
        let inner = commands.filter { !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query) }
        return prefix + inner
    }

    static func cacheKey(_ agentID: String) -> String { "cachedCommands.\(agentID)" }

    static func cached(for agentID: String, defaults: UserDefaults = .standard) -> [SlashCommand] {
        (defaults.array(forKey: cacheKey(agentID)) as? [[String]] ?? []).compactMap {
            $0.count == 3 ? SlashCommand(name: $0[0], detail: $0[1], hint: $0[2].isEmpty ? nil : $0[2]) : nil
        }
    }

    static func store(_ commands: [SlashCommand], for agentID: String, defaults: UserDefaults = .standard) {
        defaults.set(commands.map { [$0.name, $0.detail, $0.hint ?? ""] }, forKey: cacheKey(agentID))
    }
}

/// Selection and visibility state of the popup, kept apart from the view so it can be tested.
struct SlashPopupState: Equatable {
    var selection = 0
    /// Set by Esc. Cleared when the input changes.
    var dismissed = false

    mutating func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    mutating func reset() {
        selection = 0
        dismissed = false
    }
}
