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
        /// Starts and stops a voice note (see `Voice.holdToTalk`). Only registered while voice notes are on.
        var voice = "cmd+opt+v"
        /// Starts the meeting picker, or stops a running meeting. No default binding. Only registered while meeting
        /// transcripts are on.
        var meeting = ""
    }

    /// Voice notes: record the mic and send the audio to an OpenAI-compatible transcription server. The API key is
    /// not here; it lives in the Keychain (`VoiceKey`).
    struct Voice: Codable, Equatable {
        /// Off by default: turning it on is what lets audio leave the Mac.
        var enabled = false
        /// The server's base URL; `/audio/transcriptions` is added to it.
        var baseUrl = "http://localhost:8000/v1"
        var model = "mlx-community/parakeet-tdt-0.6b-v3"
        /// On: hold the shortcut to record and release to transcribe. Off: press once to start and again to stop.
        var holdToTalk = true
    }

    /// Spoken replies: Ghost reads chat replies aloud with a voice from an OpenAI-compatible speech server. Uses the
    /// server in `voice` (base URL, Keychain key).
    struct Speech: Codable, Equatable {
        /// Off by default: turning it on sends reply text to the voice server.
        var enabled = false
        var model = Speech.defaultModel
        /// One of the model's voices, such as Kokoro's `am_puck` or OpenAI's `nova`.
        var voice = Speech.defaultVoice

        static let defaultModel = "mlx-community/Kokoro-82M-bf16"
        static let defaultVoice = "am_puck"
    }

    /// Meeting transcripts: the mic and one app's audio go to the voice server in chunks, and an agent summarizes the
    /// result. Uses the server in `voice` (base URL, model, Keychain key).
    struct Meetings: Codable, Equatable {
        /// Off by default: turning it on lets meeting audio leave the Mac and the transcript reach an agent.
        var enabled = false
        /// Bundle id of the app recorded last time, or `"all"` for all system audio. Empty until the first meeting.
        var lastApp = ""
        /// An ACP agent id from `AgentCatalog`, such as `"claude"` or `"cursor"`.
        var summaryAgent = "claude"
        /// nil uses the agent's default model.
        var summaryModel: String?
        /// Run the summary agent as soon as the transcript is final.
        var autoSummary = true
        /// Ghost offers to record when another app holds the microphone for a call. Only applies with `enabled` on.
        var offerToRecordCalls = true
        /// Splits "Them" into individual speakers and recognises voices the user has named. Off by default because
        /// voiceprints are biometric data. Turning it on downloads the models once.
        var recogniseSpeakers = false
    }

    /// Screen capture: ironpet reads the text of the window you are using through Accessibility and keeps it, redacted, in its local
    /// database. Agents you run read it through MCP tools. Off by default. With it off nothing is read and no permission prompt appears.
    struct ScreenCapture: Codable, Equatable {
        var enabled = false
        /// When a window exposes no text, take a screenshot of it and read the text on this Mac. The image is never saved. Turning this
        /// on asks for Screen Recording permission.
        var ocr = false
        /// Captures older than this are deleted.
        var retentionDays = 7
        /// Bundle ids or names of apps never captured at all. Password managers are always excluded and do not need to be listed.
        var excludedApps: [String] = []
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

    struct Automations: Codable, Equatable {
        /// Execution logs older than this many days are deleted.
        var logRetentionDays = 14
        /// When an automation fails, send the error to the chat and ask the agent to fix it.
        var autoFix = true
        /// Approve commands, scripts and prompts that an agent writes without asking. Off by default.
        var autoApprove = false
    }

    struct Skills: Codable, Equatable {
        /// Install the skills that are missing for the agents found on this Mac, and update installed ones when ironpet ships a newer text.
        var autoUpdate = true
    }

    struct Tasks: Codable, Equatable {
        /// After a meeting summary, offer the action items that belong to "Me" as tasks. Nothing is added without a click.
        var meetingSuggestions = true
        /// Ghost says when an open task is due today or overdue, once per due date. Held by `reminders.paused`.
        var dueReminders = true
        /// Done tasks older than this many days are deleted, with their history.
        var keepDoneDays = 30
    }

    /// After the user has been away for `reminders.idleResetMinutes`, one bubble sums up what happened meanwhile. Built from
    /// ironpet's own activity log and stores; nothing is sent anywhere, so it is on by default.
    struct WelcomeBack: Codable, Equatable {
        var enabled = true
    }

    struct Integrations: Codable, Equatable {
        /// Status hooks in `~/.cursor/hooks.json`.
        var cursorHooks = false
        /// Status hooks in `~/.claude/settings.json`.
        var claudeHooks = false
        /// Watch switches for the other agents, by `HookInstaller.Agent` raw value (`"codex": true`).
        var hooks: [String: Bool] = [:]
        /// Whether ironpet watches this agent. Cursor and Claude Code keep their own keys for older config files.
        func watches(_ agent: HookInstaller.Agent) -> Bool {
            switch agent {
            case .cursor: return cursorHooks
            case .claude: return claudeHooks
            default: return hooks[agent.rawValue] ?? false
            }
        }

        mutating func setWatches(_ on: Bool, _ agent: HookInstaller.Agent) {
            switch agent {
            case .cursor: cursorHooks = on
            case .claude: claudeHooks = on
            default: hooks[agent.rawValue] = on
            }
        }

        /// Poll every host `gh` is logged in to for PR, CI and review alerts.
        var githubAlerts = false
        /// Copy cursor-agent MCP OAuth sign-ins between per-folder `mcp-auth.json` files before each chat.
        var shareMCPSignIns = false
    }

    /// Chat with the pet from Telegram through the user's own bot. The bot token is not here; it lives in the
    /// Keychain (`TelegramToken`). Off by default: turning it on makes ironpet poll api.telegram.org.
    struct Telegram: Codable, Equatable {
        struct User: Codable, Equatable, Identifiable {
            var id: Int64
            var name: String
            var username: String?
        }

        var enabled = false
        /// Only messages from these Telegram user ids reach the chat.
        var allowedUsers: [User] = []
    }

    /// An extra app for the "Open sessions in" picker. Without `urlTemplate` the folder is opened with the app;
    /// `{cwd}` in a template becomes the percent-encoded folder path.
    struct Editor: Codable, Equatable {
        var name: String
        var bundleId: String
        var urlTemplate: String?
    }

    struct Chat: Codable, Equatable {
        /// `"default"` (plain), a built-in id such as `"paws"`, or `"custom"` for the image in `customImage`.
        var background = "default"
        /// File name of the imported image in `~/.ironpet/backgrounds`.
        var customImage: String?
        /// A paste over this many characters becomes a `pasted-text.txt` attachment.
        var pasteAttachmentChars = Chat.defaultPasteChars
        /// A paste over this many lines becomes a `pasted-text.txt` attachment.
        var pasteAttachmentLines = Chat.defaultPasteLines

        static let defaultPasteChars = 4_000
        static let defaultPasteLines = 60
        static let pasteCharsRange = 500...100_000
        static let pasteLinesRange = 10...2_000
    }

    /// The ironpet window (chat, agents, tasks and the other sections).
    struct Window: Codable, Equatable {
        /// Hide the window when another app becomes active, and bring it back when ironpet is activated again.
        /// Off by default: the window then stays as it is today.
        var autoHide = false
    }

    var pet = Pet()
    var chat = Chat()
    var window = Window()
    /// `"auto"` (the app that started the agent) or the bundle id of a fixed app.
    var openIn = "auto"
    var editors: [Editor] = []
    var hotkeys = Hotkeys()
    var reminders = Reminders()
    var integrations = Integrations()
    var automations = Automations()
    var skills = Skills()
    var tasks = Tasks()
    var welcomeBack = WelcomeBack()
    var voice = Voice()
    var speech = Speech()
    var meetings = Meetings()
    var telegram = Telegram()
    var screenCapture = ScreenCapture()

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
        if c.chat.background != ChatBackground.defaultID, c.chat.background != ChatBackground.customID,
           ChatBackground.builtIn(c.chat.background) == nil {
            c.chat.background = ChatBackground.defaultID
        }
        // A file name only: a hand-edited "../x" must not read or delete anything outside the backgrounds folder.
        if let file = c.chat.customImage {
            let name = (file as NSString).lastPathComponent
            c.chat.customImage = name.isEmpty || name.hasPrefix(".") ? nil : name
        }
        if c.chat.background == ChatBackground.customID, c.chat.customImage == nil { c.chat.background = ChatBackground.defaultID }
        c.chat.pasteAttachmentChars = min(Chat.pasteCharsRange.upperBound, max(Chat.pasteCharsRange.lowerBound, c.chat.pasteAttachmentChars))
        c.chat.pasteAttachmentLines = min(Chat.pasteLinesRange.upperBound, max(Chat.pasteLinesRange.lowerBound, c.chat.pasteAttachmentLines))
        c.openIn = c.openIn.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.openIn.isEmpty { c.openIn = Config().openIn }
        c.editors = c.editors.filter { !$0.name.isEmpty && !$0.bundleId.isEmpty }
        c.reminders.idleResetMinutes = max(1, c.reminders.idleResetMinutes)
        c.reminders.snoozeMinutes = max(1, c.reminders.snoozeMinutes)
        c.automations.logRetentionDays = min(365, max(1, c.automations.logRetentionDays))
        c.tasks.keepDoneDays = min(365, max(1, c.tasks.keepDoneDays))
        c.voice.baseUrl = c.voice.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        c.voice.model = c.voice.model.trimmingCharacters(in: .whitespacesAndNewlines)
        c.speech.model = c.speech.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.speech.model.isEmpty { c.speech.model = Speech.defaultModel }
        c.speech.voice = c.speech.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.speech.voice.isEmpty { c.speech.voice = Speech.defaultVoice }
        if c.meetings.summaryModel?.trimmingCharacters(in: .whitespaces).isEmpty == true { c.meetings.summaryModel = nil }
        c.screenCapture.retentionDays = min(365, max(1, c.screenCapture.retentionDays))
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
