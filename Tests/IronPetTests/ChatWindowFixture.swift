import SwiftUI
@testable import IronPet

@MainActor
extension IronPetPanel {
    /// The window on the Chat section with only the chat inside, so transcript tests find its one scroll view.
    static func chat(_ session: ChatSession) -> IronPetPanel {
        let model = IronPetWindowModel()
        model.section = .chat
        let api = ChatAPI(session: session)
        return IronPetPanel(model: model, session: api, content: ChatView(session: api))
    }
}
