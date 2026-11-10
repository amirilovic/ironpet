enum PetMood: String, CaseIterable {
    case idle, working, needsInput, done, failed, listening, sleeping, drinking, stretching

    var row: AtlasRow {
        switch self {
        case .idle, .sleeping: return .idle
        case .working: return .running
        case .needsInput: return .waiting
        case .done: return .jumping
        case .failed: return .failed
        case .listening: return .waving
        case .drinking: return .drinking
        case .stretching: return .stretching
        }
    }

    /// Row for atlases without ironpet's extra rows (e.g. Codex pets).
    var fallbackRow: AtlasRow { .waving }

    /// Row to settle into after a one-shot row finishes.
    var followUp: AtlasRow? {
        switch self {
        case .done: return .review
        case .listening: return .idle
        default: return nil
        }
    }
}
