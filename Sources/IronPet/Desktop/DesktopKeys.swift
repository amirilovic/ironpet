import ApplicationServices
import Foundation

/// One key press: a virtual key code and the modifiers held with it.
struct DesktopKeyStroke: Equatable {
    var keyCode: CGKeyCode
    var flags: CGEventFlags
    /// The name as ironpet writes it in the log and the approval: modifiers first, then the key ("cmd+shift+t").
    var label: String

    var hasCommand: Bool { flags.contains(.maskCommand) }
    var isReturn: Bool { keyCode == DesktopKeys.returnCode || keyCode == DesktopKeys.enterCode }
}

/// Key names an agent may send, and what they mean on a US layout. A key code names a physical key, so letters and punctuation are
/// the keys of an ANSI keyboard.
enum DesktopKeys {
    static let returnCode: CGKeyCode = 36
    static let enterCode: CGKeyCode = 76

    private static let named: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    /// The canonical name of each named key, so "esc" and "escape" are logged alike.
    private static let canonical: [String: String] = ["enter": "return", "backspace": "delete", "esc": "escape"]

    private static let characters: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    /// Modifier names and their flags, in the order a label lists them.
    private static let modifiers: [(name: String, aliases: [String], flag: CGEventFlags)] = [
        ("cmd", ["cmd", "command", "meta"], .maskCommand),
        ("shift", ["shift"], .maskShift),
        ("opt", ["opt", "option", "alt"], .maskAlternate),
        ("ctrl", ["ctrl", "control"], .maskControl),
    ]

    static var knownNames: String {
        "letters, digits, punctuation, " + named.keys.filter { canonical[$0] == nil }.sorted().joined(separator: ", ")
    }

    /// "return", "cmd+l", "shift+tab", "cmd+shift+t". Names are lowercase and joined by "+". Throws a message an agent can act on.
    static func parse(_ raw: String) -> Result<DesktopKeyStroke, KeyError> {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return .failure(KeyError("key is required, such as \"return\" or \"cmd+l\".")) }
        var parts = text.components(separatedBy: "+")
        // "cmd++" holds the plus key, which has no key of its own here.
        if parts.contains(where: \.isEmpty) { return .failure(KeyError("\"\(raw)\" is not a key. Join modifiers and a key with \"+\", such as \"cmd+shift+t\".")) }
        let key = parts.removeLast()
        var flags: CGEventFlags = []
        var seen: [String] = []
        for part in parts {
            guard let modifier = modifiers.first(where: { $0.aliases.contains(part) }) else {
                return .failure(KeyError("\"\(part)\" is not a modifier. Use cmd, shift, opt or ctrl."))
            }
            if seen.contains(modifier.name) { return .failure(KeyError("\"\(modifier.name)\" appears twice in \"\(raw)\".")) }
            seen.append(modifier.name)
            flags.insert(modifier.flag)
        }
        let name = canonical[key] ?? key
        guard let code = named[key] ?? characters[key] else {
            return .failure(KeyError("\"\(key)\" is not a key ironpet knows. Known keys: \(knownNames). For text use desktop_type."))
        }
        let ordered = modifiers.filter { seen.contains($0.name) }.map(\.name)
        return .success(DesktopKeyStroke(keyCode: code, flags: flags, label: (ordered + [name]).joined(separator: "+")))
    }

    struct KeyError: Error, Equatable {
        var message: String
        init(_ message: String) { self.message = message }
    }
}
