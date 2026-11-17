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

/// Last-resort repair for a transcript viewport that shows no rows although there is content to show.
///
/// A lazy stack can leave the offset past the rows it has laid out, so the viewport is empty until the reader scrolls.
/// This fires only when nothing is visible and the content is taller than the viewport, and at most once for each
/// content height, so one layout pass cannot trigger a chain of scrolls. Any visible row re-arms it.
struct BlankViewportGuard {
    private var firedAtHeight: CGFloat?

    mutating func rowsVisible() { firedAtHeight = nil }

    mutating func shouldReanchor(visibleRows: Int, hasRows: Bool, contentHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        if visibleRows > 0 {
            rowsVisible()
            return false
        }
        guard hasRows, viewportHeight > 0, contentHeight > viewportHeight, firedAtHeight != contentHeight else { return false }
        firedAtHeight = contentHeight
        return true
    }
}
