import Foundation

/// Stand-ins for `--test-mode` only. An automated run must never read the real screen, start an agent or depend on a local model, so
/// the test endpoints swap these in. They are not reachable outside test mode.

/// A source that never delivers an event and reads nothing.
final class IdleCaptureSource: CaptureSource {
    func start(onEvent: @escaping (CaptureEvent) -> Void) {}
    func stop() {}
    var isTrusted: Bool { true }
    func frontmostApp() -> CaptureApp? { nil }
    func readFocusedWindow(of app: CaptureApp, budget: CaptureReadBudget) -> CaptureSnapshot? { nil }
    func readText(in rect: CaptureRect) -> [String]? { nil }
    func isWebApp(_ app: CaptureApp) -> Bool { false }
    func enableWebAccessibility(_ app: CaptureApp) {}
}

/// Answers every analysis run with `answer`. The text `"$IDS"` stands for the ids of the captures in the prompt as a JSON array, so a
/// test does not have to know them.
struct StubCaptureRunner: CaptureModelRunning {
    var answer: String

    func run(agent: ACPAgent, model: String?, prompt: String, workspace: URL) async -> Result<String, CaptureRunError> {
        let pattern = try! NSRegularExpression(pattern: #"\[capture (\d+),"#)
        let range = NSRange(prompt.startIndex..., in: prompt)
        let ids = pattern.matches(in: prompt, range: range).compactMap { Range($0.range(at: 1), in: prompt).map { String(prompt[$0]) } }
        return .success(answer.replacingOccurrences(of: "\"$IDS\"", with: "[\(ids.joined(separator: ","))]"))
    }
}

/// A decision model that calls a text secret when it contains one of `secretWords`.
struct StubDecisionClient: CaptureDecisionClient {
    var secretWords: [String]

    func probabilities(text: String, existingTasks: [String: String], questions: [(name: String, instructions: String)]) async throws -> [String: Double] {
        Dictionary(uniqueKeysWithValues: questions.map { ($0.name, $0.name == "q4" && secretWords.contains { text.contains($0) } ? 0.9 : 0.02) })
    }
}
