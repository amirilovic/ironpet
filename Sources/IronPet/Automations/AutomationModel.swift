import Foundation

/// One reminder, watcher or scheduled job. `~/.ironpet/automations.json` holds a list of these.
///
/// Trigger and action are flat records with a `type` field, so an agent can write them by hand and the validator
/// can name the exact field that is wrong.
struct Automation: Codable, Equatable, Identifiable {
    struct Trigger: Codable, Equatable {
        /// `interval`, `daily`, `once` or `poll`.
        var type: String
        /// `interval`: minutes between runs. `poll`: minutes between polls.
        var minutes: Double?
        /// `interval`: `active` counts keyboard time only, `wall` counts clock time.
        var clock: String?
        /// `daily`: times of day as `HH:mm`.
        var times: [String]?
        /// `daily`: `mon` … `sun`. Missing means every day.
        var weekdays: [String]?
        /// `once`: an ISO 8601 date and time.
        var at: String?
        /// `poll`
        var source: PollSource?
        /// `poll`: how to read the output: `json` (default), `lines`, `text` or `exit_code`.
        var mode: String?
        /// `poll`, json mode: a JMESPath expression that yields the items, such as `data.runs[?conclusion=='failure']`.
        /// Default `@`. A result that is an array is the list of items.
        var items: String?
        /// `poll`, json mode: a JMESPath expression on one item that yields its id, such as `number`.
        var id: String?
        /// `poll`, json mode: a JMESPath expression on one item. A new value for a known id fires again.
        var version: String?
        /// `script`: JavaScript that defines `poll(state)`. It gets the state it returned last time and returns
        /// `{state, fire, dismiss}`. See `AutomationScript`.
        var script: String?
        /// `poll`: after a run fires, this many minutes pass before the next one can.
        var cooldownMinutes: Double?
        /// `daily`: a slot missed while the Mac slept or ironpet was not running still fires when it is at most this many
        /// minutes late. Only the latest missed slot fires. Without it, a slot missed during sleep fires once on wake and
        /// one missed before launch never does.
        var catchUpMinutes: Double?

        /// An `interval` on the `active` clock (the default): time counts only while the user is at the keyboard.
        var countsKeyboardTime: Bool { type == "interval" && clock != "wall" }
    }

    struct PollSource: Codable, Equatable {
        /// `shell` or `http`.
        var type: String
        var command: String?
        var timeoutSeconds: Double?
        var url: String?
        /// Header values may only be `${ENV_VAR}` references.
        var headers: [String: String]?
    }

    struct Action: Codable, Equatable {
        /// `bubble`, `prompt`, `shell` or `digest`.
        var type: String
        var title: String?
        var body: String?
        /// `prompt`: what to ask. `{{item.*}}` is filled in first.
        var prompt: String?
        /// `prompt`: an ACP agent id. Default is the agent the chat uses.
        var agent: String?
        var model: String?
        /// `shell`: runs with `/bin/sh -c`.
        var command: String?
        var timeoutSeconds: Double?
        /// `digest`: `brief` (what needs you today) or `recap` (what happened today), built from data on this Mac.
        var digest: String?
    }

    struct Presentation: Codable, Equatable {
        /// What Ghost does: a `PetMood` name. Default `listening`.
        var mood: String?
        /// An SF Symbol name.
        var symbol: String?
        /// `done`, `snooze`. Default both.
        var buttons: [String]?
        /// Also send a macOS notification.
        var notification: Bool?
        var expiresSeconds: Double?
    }

    var id: String
    var name: String
    var enabled = true
    var trigger: Trigger
    var action: Action
    var presentation = Presentation()
    /// `user` or the name of whatever created it, such as `agent:ghost`.
    var createdBy = "user"
    var note: String?

    var isByUser: Bool { createdBy == "user" }

    /// A break reminder such as drink water: a bubble on keyboard time. A watcher, shell job or prompt on keyboard time is not one.
    var isBreakReminder: Bool { trigger.countsKeyboardTime && action.type == "bubble" }

    init(id: String, name: String, enabled: Bool = true, trigger: Trigger, action: Action, presentation: Presentation = Presentation(),
         createdBy: String = "user", note: String? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.trigger = trigger
        self.action = action
        self.presentation = presentation
        self.createdBy = createdBy
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case id, name, enabled, trigger, action, presentation, createdBy, note }

    /// A script automation has no `action`: the script returns its own actions.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(trigger, forKey: .trigger)
        if action.type != "none" { try c.encode(action, forKey: .action) }
        try c.encode(presentation, forKey: .presentation)
        try c.encode(createdBy, forKey: .createdBy)
        try c.encodeIfPresent(note, forKey: .note)
    }

    /// `enabled`, `presentation` and `createdBy` may be left out of the file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        trigger = try c.decode(Trigger.self, forKey: .trigger)
        action = try c.decodeIfPresent(Action.self, forKey: .action) ?? Action(type: "none")
        presentation = try c.decodeIfPresent(Presentation.self, forKey: .presentation) ?? Presentation()
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? "user"
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    /// Text whose change needs a new approval: the commands and prompts that can run on this Mac.
    var riskText: String? {
        var parts: [String] = []
        if action.type == "shell" { parts.append("shell:" + (action.command ?? "")) }
        if action.type == "prompt" { parts.append("prompt:" + (action.prompt ?? "") + "|" + (action.agent ?? "") + "|" + (action.model ?? "")) }
        if trigger.type == "script" { parts.append("script:" + (trigger.script ?? "")) }
        if trigger.type == "poll", trigger.source?.type == "shell" { parts.append("poll:" + (trigger.source?.command ?? "")) }
        if trigger.type == "poll", trigger.source?.type == "http" {
            parts.append("http:" + (trigger.source?.url ?? "") + "|" + (trigger.source?.headers ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

/// The full file: `{"automations": [...]}`.
struct AutomationFile: Codable {
    var automations: [Automation]
}

enum AutomationValidator {
    static let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    static let triggerTypes = ["interval", "daily", "once", "poll", "script"]
    static let actionTypes = ["bubble", "prompt", "shell", "digest"]
    static let digestKinds = ["brief", "recap"]
    static let pollModes = ["json", "lines", "text", "exit_code"]
        static let buttons = ["done", "snooze"]

    private static let keys: [String: Set<String>] = [
        "automation": ["id", "name", "enabled", "trigger", "action", "presentation", "createdBy", "note"],
        "trigger": ["type", "minutes", "clock", "times", "weekdays", "at", "source", "mode", "items", "id", "version", "script", "cooldownMinutes", "catchUpMinutes"],
        "source": ["type", "command", "timeoutSeconds", "url", "headers"],
        "action": ["type", "title", "body", "prompt", "agent", "model", "command", "timeoutSeconds", "digest"],
        "presentation": ["mood", "symbol", "buttons", "notification", "expiresSeconds"],
    ]

    /// Reads the file text. Returns the automations, or every problem found.
    static func parse(_ data: Data) -> (automations: [Automation], errors: [String]) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return ([], ["automations.json is not valid JSON"])
        }
        let raw: [Any]
        if let list = object as? [Any] { raw = list }
        else if let dict = object as? [String: Any], let list = dict["automations"] as? [Any] { raw = list }
        else { return ([], ["automations.json must be an object with an \"automations\" list"]) }
        var errors: [String] = []
        var result: [Automation] = []
        for (index, entry) in raw.enumerated() {
            let label = "automations[\(index)]" + ((entry as? [String: Any])?["id"] as? String).map { " (\($0))" }.orEmpty
            guard let dict = entry as? [String: Any] else { errors.append("\(label) must be an object"); continue }
            errors += unknownKeys(dict, label: label)
            do {
                let bytes = try JSONSerialization.data(withJSONObject: dict)
                result.append(try JSONDecoder().decode(Automation.self, from: bytes))
            } catch {
                errors.append("\(label): \(describe(error))")
            }
        }
        if errors.isEmpty { errors = validate(result) }
        return (result, errors)
    }

    /// Parses one automation given as a JSON object, for `automations_create`.
    static func parseOne(_ dict: [String: Any], label: String = "automation") -> (Automation?, [String]) {
        var errors = unknownKeys(dict, label: label)
        do {
            let value = try JSONDecoder().decode(Automation.self, from: JSONSerialization.data(withJSONObject: dict))
            return (value, errors)
        } catch {
            errors.append("\(label): \(describe(error))")
            return (nil, errors)
        }
    }

    private static func unknownKeys(_ dict: [String: Any], label: String) -> [String] {
        var errors: [String] = []
        for key in dict.keys.sorted() where !keys["automation"]!.contains(key) { errors.append("\(label): unknown key \"\(key)\"") }
        for (name, path) in [("trigger", "trigger"), ("action", "action"), ("presentation", "presentation")] {
            if let inner = dict[name] as? [String: Any] {
                for key in inner.keys.sorted() where !keys[path]!.contains(key) {
                    let hint = name == "trigger" && ["where", "match"].contains(key) ? ". Filter with JMESPath in items instead, such as [?state=='open']" : ""
                    errors.append("\(label).\(name): unknown key \"\(key)\"\(hint)")
                }
                if name == "trigger", let source = inner["source"] as? [String: Any] {
                    for key in source.keys.sorted() where !keys["source"]!.contains(key) { errors.append("\(label).trigger.source: unknown key \"\(key)\"") }
                }
            }
        }
        return errors
    }

    /// Problems across the whole list, each prefixed with where it is.
    static func validate(_ list: [Automation]) -> [String] {
        var errors: [String] = []
        var ids = Set<String>()
        for (index, item) in list.enumerated() {
            let label = "automations[\(index)] (\(item.id))"
            if !ids.insert(item.id).inserted { errors.append("\(label): duplicate id") }
            errors += validate(item).map { "\(label): \($0)" }
        }
        return errors
    }

    /// Problems with one automation.
    static func validate(_ a: Automation, now: Date = Date(), isNew: Bool = false) -> [String] {
        var errors: [String] = []
        if a.id.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) == nil {
            errors.append("id must be lowercase letters, digits and dashes, up to 64 characters")
        }
        if a.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("name is empty") }
        errors += validate(trigger: a.trigger, now: now, isNew: isNew)
        errors += validate(action: a.action, trigger: a.trigger)
        errors += validate(presentation: a.presentation)
        let text = [a.name, a.action.title, a.action.body, a.riskText].compactMap { $0 }.joined(separator: "\n")
        if let leak = secretLike(in: text) {
            errors.append("looks like it holds a secret (\(leak)). Use an environment variable reference such as $NAME instead")
        }
        return errors
    }

    private static func validate(trigger t: Automation.Trigger, now: Date, isNew: Bool) -> [String] {
        var errors: [String] = []
        guard triggerTypes.contains(t.type) else { return ["trigger.type must be one of \(triggerTypes.joined(separator: ", "))"] }
        if t.catchUpMinutes != nil, t.type != "daily" { errors.append("trigger.catchUpMinutes only applies to daily triggers") }
        switch t.type {
        case "interval":
            if let m = t.minutes, m >= 1, m <= 525_600 {} else { errors.append("trigger.minutes must be a number from 1 to 525600") }
            if let clock = t.clock, !["active", "wall"].contains(clock) { errors.append("trigger.clock must be \"active\" or \"wall\"") }
        case "daily":
            let times = t.times ?? []
            if times.isEmpty { errors.append("trigger.times needs at least one HH:mm time") }
            for time in times where AutomationClock.minutes(of: time) == nil { errors.append("trigger.times: \"\(time)\" is not HH:mm") }
            for day in t.weekdays ?? [] where !weekdays.contains(day) { errors.append("trigger.weekdays: \"\(day)\" is not one of \(weekdays.joined(separator: ", "))") }
            if let c = t.catchUpMinutes, c < 0 || c > 720 { errors.append("trigger.catchUpMinutes must be a number from 0 to 720") }
        case "once":
            if let at = t.at, let date = AutomationClock.parse(at) {
                if isNew, date <= now { errors.append("trigger.at is in the past") }
            } else { errors.append("trigger.at must be an ISO 8601 date and time, such as 2026-11-20T15:30:00+01:00") }
        case "script":
            if let m = t.minutes, m >= 1, m <= 525_600 {} else { errors.append("trigger.minutes must be a number from 1 to 525600") }
            if (t.script ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("trigger.script is empty") }
            else if let problem = AutomationScript.check(t.script ?? "") { errors.append("trigger.script: \(problem)") }
        default:
            if let m = t.minutes, m >= 1, m <= 525_600 {} else { errors.append("trigger.minutes must be a number from 1 to 525600") }
            if let mode = t.mode, !pollModes.contains(mode) { errors.append("trigger.mode must be one of \(pollModes.joined(separator: ", "))") }
            if let c = t.cooldownMinutes, c < 0 { errors.append("trigger.cooldownMinutes cannot be negative") }
            for (field, expression) in [("items", t.items), ("id", t.id), ("version", t.version)] {
                if let expression, let problem = JMES.check(expression) { errors.append("trigger.\(field) is not valid JMESPath: \(problem)") }
            }
            guard let source = t.source else { errors.append("trigger.source is required for poll"); break }
            switch source.type {
            case "shell":
                if (source.command ?? "").trimmingCharacters(in: .whitespaces).isEmpty { errors.append("trigger.source.command is empty") }
                if let t = source.timeoutSeconds, t < 1 || t > 600 { errors.append("trigger.source.timeoutSeconds must be between 1 and 600") }
            case "http":
                if let t = source.timeoutSeconds, t < 1 || t > 600 { errors.append("trigger.source.timeoutSeconds must be between 1 and 600") }
                if let url = source.url.flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme ?? ""), url.host != nil {} else {
                    errors.append("trigger.source.url must be an http or https URL")
                }
                for (name, value) in source.headers ?? [:] where value.range(of: #"^\$\{[A-Za-z_][A-Za-z0-9_]*\}$"#, options: .regularExpression) == nil {
                    errors.append("trigger.source.headers.\(name) must be an environment variable reference like ${TOKEN}, not a literal value")
                }
                if let url = source.url, url.range(of: #"[?&](token|key|api_key|apikey|access_token|secret)="#, options: [.regularExpression, .caseInsensitive]) != nil {
                    errors.append("trigger.source.url puts a secret in the query string. Send it in a header with an environment variable reference instead")
                }
            default:
                errors.append("trigger.source.type must be shell or http")
            }
        }
        return errors
    }

    /// True when a `{{` sits inside single or double quotes, where the automatic quoting of item values would not hold.
    static func placeholderInQuotes(_ command: String) -> Bool {
        var quote: Character?
        var escaped = false
        let chars = Array(command)
        for (i, c) in chars.enumerated() {
            if escaped { escaped = false; continue }
            if c == "\\", quote != "'" { escaped = true; continue }
            if let q = quote { if c == q { quote = nil } } else if c == "'" || c == "\"" { quote = c }
            if quote != nil, c == "{", i + 1 < chars.count, chars[i + 1] == "{" { return true }
        }
        return false
    }

    private static func validate(action a: Automation.Action, trigger: Automation.Trigger) -> [String] {
        if trigger.type == "script" {
            return a.type == "none" ? [] : ["a script returns its own actions, so leave action out"]
        }
        guard actionTypes.contains(a.type) else {
            return [a.type == "none" ? "action is required" : "action.type must be one of \(actionTypes.joined(separator: ", "))"]
        }
        var errors: [String] = []
        switch a.type {
        case "bubble":
            if (a.title ?? "").isEmpty, (a.body ?? "").isEmpty { errors.append("action needs a title or a body") }
        case "prompt":
            if (a.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("action.prompt is empty") }
            if let agent = a.agent, AgentCatalog.agent(id: agent) == nil { errors.append("action.agent \"\(agent)\" is not a known agent") }
        case "digest":
            if !digestKinds.contains(a.digest ?? "") { errors.append("action.digest must be one of \(digestKinds.joined(separator: ", "))") }
            if trigger.type == "poll" { errors.append("a digest action runs on an interval, daily or once trigger, not a poll") }
        default:
            if (a.command ?? "").trimmingCharacters(in: .whitespaces).isEmpty { errors.append("action.command is empty") }
            if placeholderInQuotes(a.command ?? "") {
                errors.append("action.command has a {{...}} placeholder inside quotes. Write it outside quotes: values are quoted for the shell automatically")
            }
        }
        if let t = a.timeoutSeconds, t < 1 || t > 600 { errors.append("action.timeoutSeconds must be between 1 and 600") }
        return errors
    }

    private static func validate(presentation p: Automation.Presentation) -> [String] {
        var errors: [String] = []
        if let mood = p.mood, PetMood(rawValue: mood) == nil { errors.append("presentation.mood must be one of \(PetMood.allCases.map(\.rawValue).joined(separator: ", "))") }
        for button in p.buttons ?? [] where !buttons.contains(button) { errors.append("presentation.buttons: \"\(button)\" is not done or snooze") }
        if let e = p.expiresSeconds, e < 3 { errors.append("presentation.expiresSeconds must be at least 3") }
        return errors
    }

    /// The first thing in `text` that looks like a pasted credential, or nil.
    static func secretLike(in text: String) -> String? {
        let patterns: [(String, String)] = [
            ("API key", #"\bsk-[A-Za-z0-9_\-]{16,}"#),
            ("GitHub token", #"\bgh[pousr]_[A-Za-z0-9]{20,}"#),
            ("Slack token", #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#),
            ("AWS key", #"\bAKIA[0-9A-Z]{16}\b"#),
            ("bearer token", #"(?i)\bbearer\s+[A-Za-z0-9._\-]{20,}"#),
            ("password", #"(?i)(password|passwd|secret|api[_-]?key|token)\s*[=:]\s*['"]?[A-Za-z0-9/+_\-]{12,}"#),
        ]
        for (label, pattern) in patterns where text.range(of: pattern, options: .regularExpression) != nil { return label }
        return nil
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            let path = (context.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: ".")
            return "\(path) is missing"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context), DecodingError.dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }

    /// `"Drink water"` becomes `drink-water`, made unique among `taken`.
    static func slug(_ name: String, taken: Set<String>) -> String {
        var base = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
        base = String(base.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(48))
        if base.isEmpty || !(base.first!.isLetter || base.first!.isNumber) { base = "automation" }
        var candidate = base
        var n = 2
        while taken.contains(candidate) { candidate = "\(base)-\(n)"; n += 1 }
        return candidate
    }
}

extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

/// Date and time-of-day helpers.
enum AutomationClock {
    static func parse(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        // No zone given: local time.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let d = local.date(from: text) { return d }
        }
        return nil
    }

    static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }

    /// Minutes after midnight for `HH:mm`.
    static func minutes(of time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
}

/// `{{item.title}}`, `{{name}}` and `{{now}}` in action text.
enum AutomationTemplate {
    static func render(_ text: String, values: [String: Any]) -> String {
        guard text.contains("{{") else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            guard let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else { out += rest[open.lowerBound...]; return out }
            let key = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            out += lookup(key, in: values)
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    private static func lookup(_ path: String, in values: [String: Any]) -> String {
        var current: Any? = values
        for part in path.split(separator: ".") {
            if let dict = current as? [String: Any] { current = dict[String(part)] }
            else if let list = current as? [Any], let i = Int(part), list.indices.contains(i) { current = list[i] }
            else { return "" }
        }
        switch current {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.doubleValue == n.doubleValue.rounded() ? String(n.int64Value) : String(n.doubleValue)
        case let value?:
            if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                return String(decoding: data, as: UTF8.self)
            }
            return "\(value)"
        }
    }
}
