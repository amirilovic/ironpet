import XCTest
@testable import IronPet

/// The chat as the Mac builds it: the engine, `ChatAPI` over it, and the window's `ChatViewModel` on top, joined by one event bus.
/// A test types into `model` and reads `model` or `api`. The engine is passed in only so the test can set its scripted agent.
@MainActor
final class ChatHarness {
    let session: ChatSession
    let events = APIEventBus()
    let api: ChatAPI
    let model: ChatViewModel

    init(session: ChatSession? = nil, voice: VoiceController? = nil, draftDirectory: URL? = nil) {
        // A turn builds its memory preamble from the memory folder, which a test must never read or write for real.
        TestMemory.isolate()
        let session = session ?? ChatSession(restore: false)
        self.session = session
        session.events = events
        api = ChatAPI(session: session)
        model = ChatViewModel(api: api, voiceAPI: .standalone(settings: .live), events: events, voice: voice, persists: false)
        if let draftDirectory { model.draftDirectory = draftDirectory }
    }

    /// Types `text` and sends it, then waits for the window's copy of the chat to catch up.
    func type(_ text: String) async {
        model.input = text
        await model.sendNow()
        await model.settle()
    }
}
