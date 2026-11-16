import SwiftUI
@testable import IronPet

@MainActor
extension IronPetPanel {
    /// The window on the Chat section with only the chat inside, so transcript tests find its one scroll view.
    static func chat(_ session: ChatSession) -> IronPetPanel {
        let model = IronPetWindowModel()
        model.section = .chat
        return IronPetPanel(model: model, session: session, content: ChatView(session: session, close: {}))
    }
}
