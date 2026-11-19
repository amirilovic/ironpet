import SwiftUI
@testable import IronPet

@MainActor
extension IronPetPanel {
    /// The window on the Chat section with only the chat inside, so transcript tests find its one scroll view.
    static func chat(_ harness: ChatHarness) -> IronPetPanel {
        let model = IronPetWindowModel()
        model.section = .chat
        return IronPetPanel(model: model, session: harness.model, content: ChatView(session: harness.model))
    }

    /// The same over a session the test fills in directly. The window's copy follows through the event bus.
    static func chat(_ session: ChatSession) -> IronPetPanel { chat(ChatHarness(session: session)) }
}
