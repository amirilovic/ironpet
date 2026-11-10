import Foundation

struct ChatModel: Identifiable, Hashable {
    let id: String
    let name: String

    /// Menu group: "Claude Opus", "Claude Sonnet", "GPT-5.6", "Grok", …
    var family: String {
        let words = name.split(separator: " ")
        guard let first = words.first else { return "Other" }
        if first == "Claude", words.count > 1 { return "Claude \(words[1])" }
        if first == "Auto" { return "Auto" }
        return String(first)
    }
}

/// Models available to the signed-in Cursor account, from `cursor-agent --list-models`.
enum ModelCatalog {
    private static let cacheKey = "cachedModels"

    static var cached: [ChatModel] {
        (UserDefaults.standard.array(forKey: cacheKey) as? [[String]] ?? []).compactMap {
            $0.count == 2 ? ChatModel(id: $0[0], name: $0[1]) : nil
        }
    }

    static func refresh() async -> [ChatModel] {
        guard let exe = CursorAgentBackend.executable() else { return cached }
        let output: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = exe
                process.arguments = ["--list-models"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let output else { return cached }
        let models = parse(output)
        if !models.isEmpty { UserDefaults.standard.set(models.map { [$0.id, $0.name] }, forKey: cacheKey) }
        return models.isEmpty ? cached : models
    }

    /// Lines look like `claude-opus-5-5-high - Claude Opus 5.5 1M High`.
    static func parse(_ output: String) -> [ChatModel] {
        output.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: " - ") else { return nil }
            let id = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let name = line[range.upperBound...]
                .unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint }
                .map(String.init).joined()
                .split(separator: " ").joined(separator: " ")
            guard !id.isEmpty, !id.contains(" ") else { return nil }
            return ChatModel(id: id, name: name)
        }
    }
}
