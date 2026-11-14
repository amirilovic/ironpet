import Combine
import CryptoKit
import Foundation

/// Where automations live on disk. `~/.ironpet/automations.json` is the list, and `~/.ironpet/automations/` holds
/// state that is not meant for hand editing. Runtime state is in `ironpet.db`. Tests point both elsewhere.
struct AutomationPaths {
    var file: URL
    var directory: URL

    static let standard = AutomationPaths(file: Paths.root.appendingPathComponent("automations.json"),
                                          directory: Paths.root.appendingPathComponent("automations"))

    var schema: URL { file.deletingLastPathComponent().appendingPathComponent("automations.schema.json") }
    /// The app's common database. Automations keep their runtime state in it, in `automation_*` tables.
    var database: URL { file.deletingLastPathComponent().appendingPathComponent("ironpet.db") }
    /// The folder a `prompt` action's agent works in.
    var workspace: URL { directory.appendingPathComponent("workspace") }
}

/// The automations list, kept in step with the file. A hand edit or an agent's write is picked up within two
/// seconds. A file that does not validate is ignored: the last good list stays active and `onInvalid` is called once
/// per distinct problem.
@MainActor
final class AutomationStore: ObservableObject {
    @Published private(set) var automations: [Automation] = []
    @Published private(set) var error: String?
    let paths: AutomationPaths
    /// Called with the problems when the file on disk is invalid.
    var onInvalid: ((String) -> Void)?
    /// Called after the list changed, from a write or a reload.
    var onChange: (([Automation]) -> Void)?

    private var stamp: Date?
    private var lastReported: String?
    private var timer: Timer?

    init(paths: AutomationPaths = .standard, defaults: () -> [Automation], watch: Bool = true) {
        self.paths = paths
        if FileManager.default.fileExists(atPath: paths.file.path) {
            reload(force: true)
        } else {
            automations = defaults()
            try? write(automations)
        }
        writeSchema()
        if watch {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    /// Reads the file if it changed. Keeps the current list when the new one is invalid.
    func reload(force: Bool = false) {
        let current = Self.modificationDate(paths.file)
        guard force || current != stamp else { return }
        stamp = current
        guard var data = try? Data(contentsOf: paths.file) else { return }
        // An earlier build stored GitHub and Sentry as built-in sources. They are scripts now.
        if let upgraded = AutomationDefaults.replacingBuiltins(in: data) {
            try? upgraded.write(to: paths.file, options: .atomic)
            stamp = Self.modificationDate(paths.file)
            data = upgraded
        }
        let (list, errors) = AutomationValidator.parse(data)
        if errors.isEmpty {
            error = nil
            lastReported = nil
            if list != automations {
                automations = list
                onChange?(list)
            }
        } else {
            let message = errors.prefix(3).joined(separator: "; ") + (errors.count > 3 ? " (+\(errors.count - 3) more)" : "")
            error = message
            if message != lastReported {
                lastReported = message
                onInvalid?(message)
            }
        }
    }

    /// Replaces the list and writes the file. The caller validated it.
    func replace(_ list: [Automation]) throws {
        try write(list)
        automations = list
        onChange?(list)
    }

    func update(_ id: String, _ change: (inout Automation) -> Void) throws {
        var list = automations
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        guard list != automations else { return }
        try replace(list)
    }

    private func write(_ list: [Automation]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: paths.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // `$schema` first would need ordered keys. A sibling schema file is enough for editors that look for it.
        try encoder.encode(AutomationFile(automations: list)).write(to: paths.file, options: .atomic)
        stamp = Self.modificationDate(paths.file)
    }

    private func writeSchema() {
        let text = AutomationSchema.json
        if (try? String(contentsOf: paths.schema, encoding: .utf8)) != text {
            try? text.write(to: paths.schema, atomically: true, encoding: .utf8)
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// What the old `config.json` reminders and integrations become on the first launch with automations.
enum AutomationMigration {
    struct Reminder {
        let id: String, name: String, title: String, body: String, symbol: String, mood: PetMood
    }

    static let reminders: [Reminder] = [
        Reminder(id: "water", name: "Drink water", title: "Drink some water", body: "Have a glass of water.", symbol: "drop.fill", mood: .drinking),
        Reminder(id: "stretch", name: "Stretch", title: "Stretch a bit", body: "Stand up, roll your shoulders, stretch your back.",
                 symbol: "figure.flexibility", mood: .stretching),
        Reminder(id: "eyes", name: "Eye break", title: "Rest your eyes", body: "Look at something 6 m away for 20 seconds.", symbol: "eye.fill", mood: .listening),
    ]

    static let githubID = AutomationDefaults.githubID
    static let sentryID = AutomationDefaults.sentryID

    /// The three reminders, from the old settings. GitHub and Sentry alerts are added only for someone who already had them on
    /// (`integrations.githubAlerts`, or a `sentry.json`), so a fresh install starts with the reminders only.
    static func defaults(from config: Config, sentryConfigured: Bool) -> [Automation] {
        let items: [String: Config.Reminders.Item] = ["water": config.reminders.water, "stretch": config.reminders.stretch, "eyes": config.reminders.eyes]
        var list = reminders.map { r in
            Automation(id: r.id, name: r.name, enabled: items[r.id]?.enabled ?? true,
                       trigger: .init(type: "interval", minutes: items[r.id]?.minutes ?? 45, clock: "active"),
                       action: .init(type: "bubble", title: r.title, body: r.body),
                       presentation: .init(mood: r.mood.rawValue, symbol: r.symbol, buttons: ["done", "snooze"]),
                       createdBy: "user")
        }
        if config.integrations.githubAlerts { list.append(AutomationDefaults.github(enabled: true)) }
        if sentryConfigured { list.append(AutomationDefaults.sentry(enabled: true)) }
        return list
    }
}

/// JSON Schema for `automations.json`, written next to it as `automations.schema.json`.
enum AutomationSchema {
    static let json = #"""
    {
      "$schema": "http://json-schema.org/draft-07/schema#",
      "title": "ironpet automations",
      "type": "object",
      "required": ["automations"],
      "properties": {
        "automations": { "type": "array", "items": { "$ref": "#/definitions/automation" } }
      },
      "definitions": {
        "automation": {
          "type": "object",
          "required": ["id", "name", "trigger"],
          "additionalProperties": false,
          "properties": {
            "id": { "type": "string", "pattern": "^[a-z0-9][a-z0-9-]{0,63}$" },
            "name": { "type": "string", "minLength": 1 },
            "enabled": { "type": "boolean", "default": true },
            "createdBy": { "type": "string", "description": "\"user\" or the name of the agent that wrote it. Anything else needs approval before a shell command or prompt runs." },
            "note": { "type": "string" },
            "trigger": { "$ref": "#/definitions/trigger" },
            "action": { "$ref": "#/definitions/action" },
            "presentation": { "$ref": "#/definitions/presentation" }
          }
        },
        "trigger": {
          "type": "object",
          "required": ["type"],
          "additionalProperties": false,
          "properties": {
            "type": { "enum": ["interval", "daily", "once", "poll", "script"] },
            "minutes": { "type": "number", "minimum": 1, "description": "interval: minutes between runs. poll: minutes between polls." },
            "clock": { "enum": ["active", "wall"], "description": "active counts keyboard time only. wall counts clock time." },
            "times": { "type": "array", "items": { "type": "string", "pattern": "^[0-2]?[0-9]:[0-5][0-9]$" } },
            "weekdays": { "type": "array", "items": { "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"] } },
            "at": { "type": "string", "description": "ISO 8601 date and time" },
            "source": { "$ref": "#/definitions/source" },
            "mode": { "enum": ["json", "lines", "text", "exit_code"] },
            "script": { "type": "string", "description": "script trigger: JavaScript defining poll(state), which returns {state, actions}. Has sh(command) and console.log. No fetch, files or modules. A script automation has no action field." },
            "items": { "type": "string", "description": "JMESPath expression that yields the items, such as data.runs[?conclusion=='failure']. Default @" },
            "id": { "type": "string", "description": "JMESPath expression on one item that yields its id" },
            "version": { "type": "string", "description": "JMESPath expression on one item. A new value for a known id fires again." },
            "cooldownMinutes": { "type": "number", "minimum": 0 }
          }
        },
        "source": {
          "type": "object",
          "required": ["type"],
          "additionalProperties": false,
          "properties": {
            "type": { "enum": ["shell", "http"] },
            "command": { "type": "string" },
            "timeoutSeconds": { "type": "number" },
            "url": { "type": "string" },
            "headers": { "type": "object", "additionalProperties": { "type": "string", "pattern": "^\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}$" } }
          }
        },
        "action": {
          "type": "object",
          "required": ["type"],
          "additionalProperties": false,
          "properties": {
            "type": { "enum": ["bubble", "prompt", "shell"] },
            "title": { "type": "string" },
            "body": { "type": "string" },
            "prompt": { "type": "string" },
            "agent": { "type": "string" },
            "model": { "type": "string" },
            "command": { "type": "string" },
            "timeoutSeconds": { "type": "number", "minimum": 1, "maximum": 600 }
          }
        },
        "presentation": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "mood": { "enum": ["idle", "working", "needsInput", "done", "failed", "listening", "sleeping", "drinking", "stretching"] },
            "symbol": { "type": "string" },
            "buttons": { "type": "array", "items": { "enum": ["done", "snooze"] } },
            "notification": { "type": "boolean" },
            "expiresSeconds": { "type": "number", "minimum": 3 }
          }
        }
      }
    }
    """#
}
