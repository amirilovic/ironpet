import Foundation

/// Reads text out of an accessibility tree without knowing which app it came from. It keeps the text of static text, headings, text
/// areas and text fields, and drops the controls around them: buttons, menus, toolbars, tabs, checkboxes and similar controls, whose
/// labels ("Bold: off", "Reply") are not what the window says. A secure field is never read.
enum CaptureText {
    /// A control and everything inside it is dropped. Its label is not content, and its children are more labels.
    static let chromeRoles: Set<String> = [
        "Button", "MenuItem", "MenuBar", "MenuBarItem", "Menu", "MenuButton", "PopUpButton", "Toolbar", "TabGroup", "Tab", "RadioButton",
        "RadioGroup", "CheckBox", "Switch", "Slider", "ScrollBar", "Image", "DisclosureTriangle", "ValueIndicator", "Incrementor",
        "Splitter", "ColorWell", "SegmentedControl", "BusyIndicator", "ProgressIndicator", "LevelIndicator", "Handle", "GrowArea",
        "Ruler", "RulerMarker", "Matte", "DockItem", "Dock",
    ]

    /// Subroles that mark a control even when the role is generic, as web toolbars and tab lists do.
    static let chromeSubroles: Set<String> = [
        "Toolbar", "TabButton", "CloseButton", "MinimizeButton", "ZoomButton", "FullScreenButton", "ToggleButton", "Switch",
    ]

    /// An element whose own text is content.
    private static let textRoles: Set<String> = ["StaticText", "Heading", "TextArea", "TextField", "SearchField", "ComboBox"]

    private static let inputRoles: Set<String> = ["TextArea", "TextField", "SearchField", "ComboBox"]

    /// At most this much text per capture. A window with more is a log or a document, and the first part says enough.
    static let maxCharacters = 120_000

    /// The lines of text in a window, top to bottom, with spacing trimmed and a line that repeats directly after itself kept once.
    static func lines(in root: AXNode) -> [String] { read(in: root).lines }

    /// The lines of a window, and the lines among them that came from an input field. The diff keeps those apart, because a draft
    /// reappears as a sent message and must not hide it.
    static func read(in root: AXNode) -> (lines: [String], inputs: [String]) {
        var out: [String] = []
        var inputs: [String] = []
        var size = 0
        func add(_ text: String?, input: Bool = false) {
            guard let text else { return }
            for piece in text.split(whereSeparator: \.isNewline) {
                let line = piece.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, line != out.last, size < maxCharacters else { continue }
                out.append(line)
                if input { inputs.append(line) }
                size += line.count + 1
            }
        }
        func walk(_ node: AXNode) {
            if node.isSecure || node.hidden || chromeRoles.contains(node.role) { return }
            if let subrole = node.subrole, chromeSubroles.contains(subrole) { return }
            if textRoles.contains(node.role) {
                // An input holds what was typed. Its title and description name the field ("Message to Ana"), which is not content.
                let isInput = inputRoles.contains(node.role)
                if node.role == "Heading" {
                    // The value of a heading is its level, so a heading reads by its name.
                    add(nonEmpty(node.title) ?? nonEmpty(node.description) ?? nonEmpty(node.value).flatMap { Int($0) == nil ? $0 : nil })
                    return
                }
                add(nonEmpty(node.value) ?? (isInput ? nil : nonEmpty(node.title) ?? nonEmpty(node.description)), input: isInput)
                // Rich text areas hold their text in styled children as well as in the value, so they are not walked again.
                return
            }
            let before = out.count
            node.children.forEach(walk)
            // A link or cell with no text inside it can name itself.
            if node.role == "Link", out.count == before { add(nonEmpty(node.title) ?? nonEmpty(node.description)) }
        }
        walk(root)
        return (out, inputs)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// The first page address of a web area in the tree.
    static func pageURL(in root: AXNode) -> String? {
        if root.role == "WebArea", let url = root.url, !url.isEmpty { return url }
        for child in root.children { if let url = pageURL(in: child) { return url } }
        return nil
    }
}

/// What is new in a window since its last capture.
enum CaptureDiff {
    /// Lines of context kept on each side of a new line, so a stored capture still reads as a piece of the window.
    static let context = 2

    /// The new lines of `current`, each with `context` lines around it, as one text. Chunks that are not next to each other are
    /// separated by a line holding `…`. Nil when nothing is new.
    static func fresh(previous: [String], current: [String], context: Int = context) -> String? {
        let known = Set(previous)
        return fresh(current: current, isKnown: known.contains, context: context)
    }

    /// Same, for a caller that knows the previous lines only by a test, such as a digest lookup.
    static func fresh(current: [String], isKnown: (String) -> Bool, context: Int = context) -> String? {
        var keep = Set<Int>()
        var anyNew = false
        for (index, line) in current.enumerated() where !isKnown(line) {
            anyNew = true
            for neighbour in max(0, index - context)...min(current.count - 1, index + context) { keep.insert(neighbour) }
        }
        guard anyNew else { return nil }
        var out: [String] = []
        var last = -2
        for index in keep.sorted() {
            if index != last + 1, !out.isEmpty { out.append("…") }
            out.append(current[index])
            last = index
        }
        return out.joined(separator: "\n")
    }
}
