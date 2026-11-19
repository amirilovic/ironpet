import Foundation

/// One question of a form as Telegram shows it: a field and, for a select, the `<id>_custom` text field that is its
/// "Other" box on the Mac.
struct TelegramFormQuestion: Equatable {
    /// Index into `ElicitationForm.fields`.
    let field: Int
    /// Index of the text field that follows a select field and is named `<id>_custom`.
    let other: Int?
}

/// What a tap on a form button means. The callback data holds only a short form number and indexes, because Telegram
/// allows 64 bytes: `f:<form>:x` skips the form, `f:<form>:<field>:<option>` picks an option, `:s` skips a field and
/// `:d` finishes a multi select.
enum TelegramFormTap: Equatable {
    case skipForm
    case option(field: Int, option: Int)
    case skip(field: Int)
    case done(field: Int)
}

enum TelegramFormLayout {
    static func questions(_ form: ElicitationForm) -> [TelegramFormQuestion] {
        var result: [TelegramFormQuestion] = []
        var index = 0
        while index < form.fields.count {
            let field = form.fields[index]
            var other: Int?
            if index + 1 < form.fields.count, form.fields[index + 1].id == field.id + "_custom", form.fields[index + 1].kind == .text {
                switch field.kind {
                case .single, .multi: other = index + 1
                default: break
                }
            }
            result.append(TelegramFormQuestion(field: index, other: other))
            index += other == nil ? 1 : 2
        }
        return result
    }

    // MARK: Callback data

    static func data(form: Int, _ tap: TelegramFormTap) -> String {
        switch tap {
        case .skipForm: return "f:\(form):x"
        case .option(let field, let option): return "f:\(form):\(field):\(option)"
        case .skip(let field): return "f:\(form):\(field):s"
        case .done(let field): return "f:\(form):\(field):d"
        }
    }

    static func parse(_ data: String) -> (form: Int, tap: TelegramFormTap)? {
        let parts = data.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "f", parts.count >= 3, let form = Int(parts[1]) else { return nil }
        if parts.count == 3, parts[2] == "x" { return (form, .skipForm) }
        guard parts.count == 4, let field = Int(parts[2]) else { return nil }
        switch parts[3] {
        case "s": return (form, .skip(field: field))
        case "d": return (form, .done(field: field))
        default: return Int(parts[3]).map { (form, .option(field: field, option: $0)) }
        }
    }

    // MARK: Text and keyboards

    static func header(_ form: ElicitationForm, fallback: String) -> String {
        let message = form.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((message.isEmpty ? fallback : message).prefix(1500))
    }

    static func question(_ form: ElicitationForm, _ question: TelegramFormQuestion, number: Int, total: Int) -> String {
        let field = form.fields[question.field]
        var lines: [String] = []
        let title = field.title.isEmpty ? field.id : field.title
        lines.append(total > 1 ? "\(number) of \(total). \(title)" : title)
        if !field.detail.isEmpty { lines.append(field.detail) }
        switch field.kind {
        case .single(let options), .multi(let options):
            let described = options.filter { !$0.detail.isEmpty }
            if !described.isEmpty { lines.append("") }
            for option in described { lines.append("\(option.title): \(option.detail)") }
            if case .multi = field.kind { lines.append(contentsOf: ["", "Tap to select, then Done."]) }
            if question.other != nil { lines.append(contentsOf: ["", "Or reply to this message with your own answer."]) }
        case .text:
            lines.append(contentsOf: ["", "Reply to this message with your answer."])
        case .number(let integer):
            lines.append(contentsOf: ["", integer ? "Reply to this message with a whole number." : "Reply to this message with a number."])
        case .boolean:
            break
        }
        if !field.required { lines.append("(optional)") }
        return String(lines.joined(separator: "\n").prefix(3500))
    }

    static func keyboard(_ form: ElicitationForm, _ question: TelegramFormQuestion, form number: Int, picked: Set<Int>) -> [[TelegramButton]] {
        let field = form.fields[question.field]
        func data(_ tap: TelegramFormTap) -> String { Self.data(form: number, tap) }
        var rows: [[TelegramButton]] = []
        switch field.kind {
        case .single(let options):
            rows = options.enumerated().map { [TelegramButton(text: $1.title, data: data(.option(field: question.field, option: $0)))] }
        case .multi(let options):
            rows = options.enumerated().map {
                [TelegramButton(text: (picked.contains($0) ? "✓ " : "") + $1.title, data: data(.option(field: question.field, option: $0)))]
            }
            rows.append([TelegramButton(text: "Done", data: data(.done(field: question.field)))])
        case .boolean:
            rows = [[TelegramButton(text: "Yes", data: data(.option(field: question.field, option: 1))),
                     TelegramButton(text: "No", data: data(.option(field: question.field, option: 0)))]]
        case .text, .number:
            break
        }
        if !field.required {
            let skip = TelegramButton(text: "Skip", data: data(.skip(field: question.field)))
            rows.append([skip])
        }
        return rows
    }
}
