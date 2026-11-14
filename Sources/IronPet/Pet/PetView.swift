import AppKit

final class PetView: NSView {
    var onClick: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var contextMenu: (() -> NSMenu)?
    var onRecordingClick: (() -> Void)?

    enum Recording { case none, shown, hidden }
    /// `.hidden` means a meeting is recording and its bubble is closed, so the pet shows a Recording button.
    var recording: Recording = .none {
        didSet { if recording != oldValue { needsDisplay = true } }
    }
    private var recordingRect: CGRect {
        CGRect(x: bounds.midX - 38, y: 4, width: 76, height: 20)
    }

    private var atlas: Atlas?
    private(set) var mood: PetMood = .idle
    private var badge = 0
    private var row: AtlasRow = .idle
    private var frameIndex = 0
    private var frameElapsed: Double = 0
    private var lookIndex: Int?

    private var dragDirection: Int?
    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    private var didDrag = false
    private var lastDragTime = Date.distantPast

    init(atlas: Atlas?, size: CGSize) {
        self.atlas = atlas
        super.init(frame: CGRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setAtlas(_ newAtlas: Atlas?) {
        atlas = newAtlas
        play(atlas?.has(mood.row) == false ? mood.fallbackRow : mood.row)
        needsDisplay = true
    }

    func show(_ newMood: PetMood, badge newBadge: Int) {
        badge = newBadge
        if newMood != mood {
            mood = newMood
            play(atlas?.has(newMood.row) == false ? newMood.fallbackRow : newMood.row)
        }
        needsDisplay = true
    }

    /// Plays the run row for a moment, as if dragged; call every frame to keep running.
    func run(direction: Int) {
        dragDirection = direction
        lastDragTime = Date()
    }

    private func play(_ r: AtlasRow) {
        row = r
        frameIndex = 0
        frameElapsed = 0
    }

    private var activeRow: AtlasRow {
        if let d = dragDirection { return d > 0 ? .runRight : .runLeft }
        return row
    }

    func tick(_ dt: Double) {
        defer { needsDisplay = true }
        if dragDirection != nil, Date().timeIntervalSince(lastDragTime) > 0.15 { dragDirection = nil }
        updateLook()
        if mood == .sleeping || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            frameIndex = 0
            return
        }
        let r = activeRow
        frameElapsed += dt
        while frameElapsed >= r.durations[min(frameIndex, r.durations.count - 1)] {
            frameElapsed -= r.durations[min(frameIndex, r.durations.count - 1)]
            frameIndex += 1
            guard frameIndex >= r.durations.count else { continue }
            if r.loops || dragDirection != nil {
                frameIndex = 0
            } else if let next = mood.followUp {
                play(next)
                return
            } else {
                frameIndex = r.durations.count - 1
                frameElapsed = 0
                return
            }
        }
    }

    /// While idle the eyes follow the cursor; inside the deadzone or far away, fall back to idle.
    private func updateLook() {
        lookIndex = nil
        guard mood == .idle, row == .idle, dragDirection == nil, let window, atlas?.look.count == 16 else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - window.frame.midX, dy = mouse.y - window.frame.midY
        let distance = hypot(dx, dy)
        guard distance > 70, distance < 500 else { return }
        var degrees = atan2(dx, dy) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        lookIndex = Int((degrees / 22.5).rounded()) % 16
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.saveGState()
        ctx.setAlpha(mood == .sleeping ? 0.55 : 1)
        if let atlas {
            let image = lookIndex.map { atlas.look[$0] } ?? atlas.frame(activeRow, frameIndex)
            if let image { ctx.draw(image, in: bounds) }
        } else {
            drawPlaceholder(ctx)
        }
        ctx.restoreGState()
        if badge > 0, [.needsInput, .failed, .done].contains(mood) { drawBadge() }
        if recording == .hidden { drawRecordingButton() }
    }

    private func drawRecordingButton() {
        let rect = recordingRect
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: CGRect(x: rect.minX + 8, y: rect.midY - 3.5, width: 7, height: 7)).fill()
        let text = NSAttributedString(string: "Recording", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white,
        ])
        let s = text.size()
        text.draw(at: NSPoint(x: rect.minX + 19, y: rect.midY - s.height / 2))
    }

    private func drawPlaceholder(_ ctx: CGContext) {
        let body = bounds.insetBy(dx: bounds.width * 0.15, dy: bounds.height * 0.18)
        let color: NSColor = switch mood {
        case .needsInput: .systemOrange
        case .failed: .systemRed
        case .done: .systemGreen
        case .working: .systemBlue
        default: .systemIndigo
        }
        color.setFill()
        NSBezierPath(roundedRect: body, xRadius: body.width * 0.3, yRadius: body.width * 0.3).fill()
        NSColor.white.setFill()
        let eye = body.width * 0.12
        for x in [body.midX - body.width * 0.18, body.midX + body.width * 0.18] {
            NSBezierPath(ovalIn: CGRect(x: x - eye / 2, y: body.midY, width: eye, height: eye * 1.3)).fill()
        }
    }

    private func drawBadge() {
        let color: NSColor = switch mood {
        case .needsInput: .systemOrange
        case .failed: .systemRed
        default: .systemGreen
        }
        let d: CGFloat = 22
        let rect = CGRect(x: bounds.maxX - d - 2, y: bounds.maxY - d - 2, width: d, height: d)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let text = NSAttributedString(string: "\(badge)", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white,
        ])
        let s = text.size()
        text.draw(at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let origin = windowStart, let window else { return }
        let now = NSEvent.mouseLocation
        if hypot(now.x - start.x, now.y - start.y) > 3 { didDrag = true }
        window.setFrameOrigin(NSPoint(x: origin.x + now.x - start.x, y: origin.y + now.y - start.y))
        if abs(event.deltaX) > 0.5 { dragDirection = event.deltaX > 0 ? 1 : -1 }
        lastDragTime = Date()
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        dragDirection = nil
        if didDrag {
            onDragEnded?()
        } else if recording == .hidden, recordingRect.contains(convert(event.locationInWindow, from: nil)) {
            onRecordingClick?()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
