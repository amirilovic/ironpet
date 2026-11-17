import Foundation

/// One choice in a select field: the value sent back, the label shown, and optional secondary text.
struct ElicitationOption: Equatable {
    let value: String
    let title: String
    let detail: String
}

struct ElicitationField: Identifiable, Equatable {
    enum Kind: Equatable {
        case single([ElicitationOption])
        case multi([ElicitationOption])
        case text
        case number(integer: Bool)
        case boolean
    }

    /// The property name in the schema, which is also the key in the reply.
    let id: String
    let title: String
    let detail: String
    let required: Bool
    let kind: Kind
}

/// What the user has entered so far, per field id.
enum ElicitationValue: Equatable {
    case one(String)
    case many([String])
    case text(String)
    case flag(Bool)
}

typealias ElicitationAnswers = [String: ElicitationValue]

/// One answered line of a form, for the read-only card.
struct ElicitationLine: Codable, Equatable {
    let question: String
    let answer: String
}

/// A form after the user answered or skipped it. It stays in the transcript.
struct ElicitationRecord: Codable, Equatable {
    let message: String
    let skipped: Bool
    let lines: [ElicitationLine]
}

/// The reply to `elicitation/create`.
enum ElicitationReply: Equatable {
    case accept(JSON)
    case decline
    case cancel

    var json: JSON {
        switch self {
        case .accept(let content): return ["action": "accept", "content": content]
        case .decline: return ["action": "decline"]
        case .cancel: return ["action": "cancel"]
        }
    }

    static func == (a: ElicitationReply, b: ElicitationReply) -> Bool {
        NSDictionary(dictionary: a.json).isEqual(to: b.json)
    }
}

/// A form request from the agent: the message and a flat list of fields, parsed from `requestedSchema`.
struct ElicitationForm: Equatable {
    let message: String
    let fields: [ElicitationField]

    /// Nil when the request is not a form ironpet can draw: another mode, or a schema with nested objects, arrays of
    /// objects or properties without a known type. The caller declines those.
    static func parse(_ params: JSON) -> ElicitationForm? {
        guard params["mode"] as? String == "form",
              let schema = params["requestedSchema"] as? JSON,
              schema["type"] as? String == "object",
              let properties = schema["properties"] as? JSON else { return nil }
        let required = Set(schema["required"] as? [String] ?? [])
        // JSON objects have no order. Sorting with numbers compared as numbers keeps question_2 before question_10 and
        // each question_<n> right before its question_<n>_custom.
        var fields: [ElicitationField] = []
        for key in properties.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            guard let property = properties[key] as? JSON, let kind = kind(of: property) else { return nil }
            fields.append(ElicitationField(id: key, title: property["title"] as? String ?? "", detail: property["description"] as? String ?? "",
                                           required: required.contains(key), kind: kind))
        }
        return ElicitationForm(message: params["message"] as? String ?? "", fields: fields)
    }

    private static func kind(of property: JSON) -> ElicitationField.Kind? {
        switch property["type"] as? String {
        case "string":
            if let options = options(in: property) { return .single(options) }
            return property["oneOf"] == nil && property["enum"] == nil ? .text : nil
        case "array":
            guard let items = property["items"] as? JSON, let options = options(in: items) else { return nil }
            return .multi(options)
        case "number": return .number(integer: false)
        case "integer": return .number(integer: true)
        case "boolean": return .boolean
        default: return nil
        }
    }

    /// Choices from `oneOf`/`anyOf` entries (`const`, `title`, `description`) or from a plain `enum` with optional `enumNames`.
    private static func options(in schema: JSON) -> [ElicitationOption]? {
        for key in ["oneOf", "anyOf"] {
            guard let entries = schema[key] as? [JSON] else { continue }
            var result: [ElicitationOption] = []
            for entry in entries {
                guard let value = entry["const"] as? String else { return nil }
                result.append(ElicitationOption(value: value, title: entry["title"] as? String ?? value,
                                                detail: entry["description"] as? String ?? ""))
            }
            return result
        }
        guard let values = schema["enum"] as? [String] else { return nil }
        let names = schema["enumNames"] as? [String] ?? []
        return values.enumerated().map { index, value in
            ElicitationOption(value: value, title: index < names.count ? names[index] : value, detail: "")
        }
    }

    // MARK: Answers

    /// True when every required field has an answer and every number parses.
    func canSubmit(_ answers: ElicitationAnswers) -> Bool {
        fields.allSatisfy { field in
            let filled = content(for: field, answers) != nil
            if case .number = field.kind, case .text(let raw)? = answers[field.id], !raw.trimmingCharacters(in: .whitespaces).isEmpty, !filled {
                return false
            }
            return filled || !field.required
        }
    }

    /// The `content` object of an accept reply. Fields left empty are left out, so `_custom` only appears when filled.
    func content(_ answers: ElicitationAnswers) -> JSON {
        var result: JSON = [:]
        for field in fields {
            if let value = content(for: field, answers) { result[field.id] = value }
        }
        return result
    }

    private func content(for field: ElicitationField, _ answers: ElicitationAnswers) -> Any? {
        switch (field.kind, answers[field.id]) {
        case (.single, .one(let value)?):
            return value
        case (.multi(let options), .many(let values)?):
            // Keep the schema's order, not the order the user clicked in.
            let picked = options.map(\.value).filter(values.contains)
            return picked.isEmpty ? nil : picked
        case (.text, .text(let text)?):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case (.number(let integer), .text(let text)?):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if integer { return Int(trimmed).map { $0 as Any } }
            return Double(trimmed).map { $0 as Any }
        case (.boolean, .flag(let on)?):
            return on
        default:
            return nil
        }
    }

    /// The answered lines for the read-only card, with option titles instead of values.
    func lines(_ answers: ElicitationAnswers) -> [ElicitationLine] {
        let content = content(answers)
        return fields.compactMap { field in
            guard let value = content[field.id] else { return nil }
            let text: String
            switch field.kind {
            case .single(let options):
                text = options.first { $0.value == value as? String }?.title ?? "\(value)"
            case .multi(let options):
                text = (value as? [String] ?? []).map { picked in options.first { $0.value == picked }?.title ?? picked }.joined(separator: ", ")
            case .boolean:
                text = (value as? Bool) == true ? "Yes" : "No"
            default:
                text = "\(value)"
            }
            let name = field.title.isEmpty ? field.id : field.title
            let question = field.detail.isEmpty || field.id.hasSuffix("_custom") ? name : "\(name): \(field.detail)"
            return ElicitationLine(question: question, answer: text)
        }
    }
}
