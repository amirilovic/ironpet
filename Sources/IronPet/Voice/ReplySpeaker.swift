import Foundation

/// Speaks a reply while the agent is still writing it: each sentence goes to `speak` as soon as it is complete, one after
/// another, so speech starts after the first sentence instead of after the whole turn.
@MainActor
final class ReplySpeaker {
    private let speak: (String) async throws -> Void
    private var buffer = ""
    private var pending: [String] = []
    private var pump: Task<Void, Never>?
    private var spoken = 0
    /// Set by `cancel()`: text that the agent still sends afterwards is dropped.
    private var stopped = false
    /// Sentences handed to the speaker so far, including the one being said.
    private(set) var queued = 0

    /// Called once, before the first sentence is said.
    var onFirstSentence: () -> Void = {}
    /// The speaker failed; the rest of the reply is dropped.
    var onFailure: (Error) -> Void = { _ in }

    init(speak: @escaping (String) async throws -> Void) {
        self.speak = speak
    }

    /// More of the reply's text arrived.
    func add(_ chunk: String) {
        guard !stopped else { return }
        buffer += chunk
        let (sentences, rest) = SpeechText.completeSentences(buffer, final: false)
        buffer = rest
        enqueue(sentences)
    }

    /// The reply is complete. Says what is left, or `fallback` when no sentence was ever queued, and returns once
    /// everything has been said.
    func finish(ifNothingSpoken fallback: String) async {
        if queued == 0 { buffer = fallback }
        let (sentences, _) = SpeechText.completeSentences(buffer, final: true)
        buffer = ""
        enqueue(sentences)
        await pump?.value
    }

    /// Drops what is queued and stops the sentence being said.
    func cancel() {
        stopped = true
        pump?.cancel()
        pump = nil
        pending = []
        buffer = ""
    }

    private func enqueue(_ sentences: [String]) {
        guard !sentences.isEmpty else { return }
        pending += sentences
        queued += sentences.count
        if pump == nil { pump = Task { [weak self] in await self?.run() } }
    }

    private func run() async {
        while !pending.isEmpty, !Task.isCancelled {
            let sentence = pending.removeFirst()
            if spoken == 0 { onFirstSentence() }
            spoken += 1
            do {
                try await speak(sentence)
            } catch is CancellationError {
                break
            } catch {
                onFailure(error)
                pending = []
                break
            }
        }
        pump = nil
    }
}
