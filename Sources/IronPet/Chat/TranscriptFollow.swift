import CoreGraphics

/// Whether the transcript follows new content, and whether to offer a jump to the latest.
///
/// Only the reader's own scrolling can unpin it. Content growth and window resizes move the distance from the
/// bottom too, and the lazy stack realizes the bottom marker early, so neither says where the reader is.
struct TranscriptFollow {
    private(set) var pinned = true
    /// New content arrived below the viewport while the reader was scrolled up.
    private(set) var newBelow = false

    static let bottomTolerance: CGFloat = 24

    /// `userDriven`: the scroll view is being dragged, scrolled by wheel or trackpad, or coasting.
    mutating func geometryChanged(distanceFromBottom: CGFloat, userDriven: Bool) {
        let atBottom = distanceFromBottom <= Self.bottomTolerance
        if userDriven {
            pinned = atBottom
        } else if atBottom {
            pinned = true
        }
        if pinned { newBelow = false }
    }

    /// Sending a message jumps to the end and follows from there.
    mutating func sent() {
        pinned = true
        newBelow = false
    }

    mutating func jumpedToLatest() { sent() }

    /// The app scrolled the reader to a place in the history, such as a find match.
    mutating func leftTheEnd() { pinned = false }

    /// New items, streamed text or a status change arrived. `readerSent`: the change is a message the reader just
    /// sent from here. A user message that was already last, or that came from Telegram, does not count.
    /// `newContent` is false for a change that adds nothing to read, such as the agent finishing.
    mutating func contentArrived(readerSent: Bool, newContent: Bool = true) {
        if readerSent { sent() }
        if !pinned && newContent { newBelow = true }
    }
}
