import AppKit
import Carbon
import Combine

/// User settings in `~/.ironpet/config.json`. The file only needs the keys the user changed: whatever it has is
/// laid over the defaults below. Defaults are conservative: nothing that reaches the network or copies
/// credentials is on until the user turns it on.
struct Config: Codable, Equatable {
    struct Pet: Codable, Equatable {
        var name = "Ghost"
        /// Path to a sprite sheet in the Codex pet v2 layout. Unset: `~/.ironpet/pet/spritesheet.png`, else the
        /// bundled Ghost.
        var sprite: String?
    }

    /// Global shortcuts like `"cmd+opt+g"`. An empty string turns a shortcut off.
    struct Hotkeys: Codable, Equatable {
        var chat = "cmd+opt+g"
        var captureWindow = "cmd+opt+shift+g"
        var captureRegion = "cmd+opt+ctrl+g"
    }

    struct Reminders: Codable, Equatable {
        struct Item: Codable, Equatable {
            var enabled = true
            var minutes: Double
        }

        var paused = false
        var water = Item(minutes: 45)
        var stretch = Item(minutes: 60)
        var eyes = Item(minutes: 20)
        /// Being away from the keyboard this long resets every reminder.
        var idleResetMinutes: Double = 5
        var snoozeMinutes: Double = 10
    }

    struct Integrations: Codable, Equatable {
        /// Status and approval hooks in `~/.cursor/hooks.json`.
        var cursorHooks = false
        /// Status and approval hooks in `~/.claude/settings.json`.
        var claudeHooks = false
        /// Poll every host `gh` is logged in to for PR, CI and review alerts.
        var githubAlerts = false
        /// Copy cursor-agent MCP OAuth sign-ins between per-folder `mcp-auth.json` files before each chat.
        var shareMCPSignIns = false
    }

    var pet = Pet()
    var hotkeys = Hotkeys()
    var reminders = Reminders()
    var integrations = Integrations()

    static let file = Paths.root.appendingPathComponent("config.json")

    /// Reads the file, laying it over the defaults. An unreadable or invalid file gives the defaults plus an error.
    static func load(from file: URL = Config.file) -> (config: Config, error: String?) {
        guard let data = try? Data(contentsOf: file) else { return (Config(), nil) }
        do {
            guard let user = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (Config(), "config.json must contain a JSON object")
            }
            let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as! [String: Any]
            let merged = try JSONSerialization.data(withJSONObject: merge(user, over: defaults))
            return (try JSONDecoder().decode(Config.self, from: merged).sanitized(), nil)
        } catch {
            NSLog("ironpet: ignoring invalid \(file.path): \(error)")
            return (Config(), "config.json is invalid, using defaults: \(Self.describe(error))")
        }
    }

    func save(to file: URL = Config.file) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    private func sanitized() -> Config {
        var c = self
        c.pet.name = c.pet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.pet.name.isEmpty { c.pet.name = Pet().name }
        for path in [\Reminders.water, \Reminders.stretch, \Reminders.eyes] {
            c.reminders[keyPath: path].minutes = max(1, c.reminders[keyPath: path].minutes)
        }
        c.reminders.idleResetMinutes = max(1, c.reminders.idleResetMinutes)
        c.reminders.snoozeMinutes = max(1, c.reminders.snoozeMinutes)
        return c
    }

    private static func merge(_ user: [String: Any], over base: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in user {
            if let nested = value as? [String: Any], let baseNested = base[key] as? [String: Any] {
                result[key] = merge(nested, over: baseNested)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
             DecodingError.dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }
}

/// The live config for the UI. Picks up hand edits to the file within a couple of seconds.
@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published private(set) var config: Config
    @Published private(set) var error: String?
    private var stamp: Date?
    private var timer: Timer?

    private init() {
        (config, error) = Config.load()
        stamp = Self.modificationDate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfChanged() }
        }
    }

    /// For `--render-previews`: uses `config` in memory only, never saves it, and stops watching the file.
    func usePreview(_ config: Config) {
        timer?.invalidate()
        self.config = config
        error = nil
    }

    func update(_ change: (inout Config) -> Void) {
        var next = config
        change(&next)
        guard next != config else { return }
        if error != nil, FileManager.default.fileExists(atPath: Config.file.path) {
            // The file on disk didn't parse; keep the user's hand edits before replacing it.
            let backup = Config.file.deletingPathExtension().appendingPathExtension("invalid.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: Config.file, to: backup)
        }
        do {
            try next.save()
            error = nil
        } catch {
            self.error = "Could not save config.json: \(error.localizedDescription)"
        }
        config = next
        stamp = Self.modificationDate()
    }

    func reloadIfChanged() {
        let current = Self.modificationDate()
        guard current != stamp else { return }
        stamp = current
        let (loaded, loadError) = Config.load()
        error = loadError
        if loaded != config { config = loaded }
    }

    private static func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Config.file.path))?[.modificationDate] as? Date
    }
}

/// A global shortcut written as `"cmd+opt+shift+g"`.
struct Shortcut: Equatable {
    var keyCode: Int
    /// Carbon modifier flags (`cmdKey`, `optionKey`, …).
    var modifiers: Int

    private static let modifierNames: [(names: [String], flag: Int, symbol: String, label: String)] = [
        (["ctrl", "control", "⌃"], controlKey, "⌃", "ctrl"),
        (["opt", "option", "alt", "⌥"], optionKey, "⌥", "opt"),
        (["shift", "⇧"], shiftKey, "⇧", "shift"),
        (["cmd", "command", "⌘"], cmdKey, "⌘", "cmd"),
    ]

    private static let keys: [(name: String, code: Int)] = {
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z),
            ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4),
            ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
            ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal), ("[", kVK_ANSI_LeftBracket), ("]", kVK_ANSI_RightBracket),
            (";", kVK_ANSI_Semicolon), ("'", kVK_ANSI_Quote), (",", kVK_ANSI_Comma), (".", kVK_ANSI_Period),
            ("/", kVK_ANSI_Slash), ("\\", kVK_ANSI_Backslash), ("`", kVK_ANSI_Grave),
            ("space", kVK_Space), ("return", kVK_Return), ("tab", kVK_Tab), ("escape", kVK_Escape),
            ("up", kVK_UpArrow), ("down", kVK_DownArrow), ("left", kVK_LeftArrow), ("right", kVK_RightArrow),
        ]
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11,
                     kVK_F12].enumerated().map { ("f\($0.offset + 1)", $0.element) }
        return letters + fkeys
    }()

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// nil for an empty string (shortcut off) or one that can't be parsed.
    init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, let key = Self.keys.first(where: { $0.name == keyName }) else { return nil }
        var flags = 0
        for part in parts.dropLast() {
            guard let modifier = Self.modifierNames.first(where: { $0.names.contains(part) }) else { return nil }
            flags |= modifier.flag
        }
        guard Self.isAllowed(keyName: keyName, modifiers: flags) else { return nil }
        self.init(keyCode: key.code, modifiers: flags)
    }

    /// From a key press while recording. nil for keys we can't name or presses without a modifier.
    init?(event: NSEvent) {
        guard let key = Self.keys.first(where: { $0.code == Int(event.keyCode) }) else { return nil }
        var flags = 0
        let mods = event.modifierFlags
        if mods.contains(.control) { flags |= controlKey }
        if mods.contains(.option) { flags |= optionKey }
        if mods.contains(.shift) { flags |= shiftKey }
        if mods.contains(.command) { flags |= cmdKey }
        guard Self.isAllowed(keyName: key.name, modifiers: flags) else { return nil }
        self.init(keyCode: key.code, modifiers: flags)
    }

    /// Function keys work alone; anything else needs ⌘, ⌥ or ⌃ so typing (including Shift for capitals) isn't
    /// hijacked.
    private static func isAllowed(keyName: String, modifiers: Int) -> Bool {
        let isFunctionKey = keyName.count > 1 && keyName.hasPrefix("f") && Int(keyName.dropFirst()) != nil
        return isFunctionKey || modifiers & (cmdKey | optionKey | controlKey) != 0
    }

    private var keyName: String { Self.keys.first { $0.code == keyCode }?.name ?? "?" }

    /// `"cmd+opt+g"`, the form stored in config.json.
    var text: String {
        (Self.modifierNames.filter { modifiers & $0.flag != 0 }.map(\.label) + [keyName]).joined(separator: "+")
    }

    /// `"⌥⌘G"`, for menus and labels.
    var display: String {
        let symbols: [String: String] = ["space": "Space", "return": "↩", "tab": "⇥", "escape": "⎋",
                                         "up": "↑", "down": "↓", "left": "←", "right": "→"]
        let key = symbols[keyName] ?? keyName.uppercased()
        return Self.modifierNames.filter { modifiers & $0.flag != 0 }.map(\.symbol).joined() + key
    }

    /// Display form of a config string, or nil when it's off or invalid.
    static func display(_ text: String) -> String? {
        Shortcut(text)?.display
    }
}
