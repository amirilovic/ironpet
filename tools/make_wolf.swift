// Draws ironpet's baby wolf into a Codex v2 atlas (8 columns of 192x208 cells), plus two extra rows
// for drinking and stretching, so the sheet is 1536x2704.
// Themes: "ghost" (white direwolf in a Night's Watch cloak, default) and "mochi" (mint wolf).
// Run: swift tools/make_wolf.swift [ghost|mochi] [output.png]
import AppKit

// MARK: - Theme

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

struct Theme {
    var fur: CGColor
    var furShade: CGColor
    var outline: CGColor
    var cream: CGColor
    var earPink: CGColor
    var blush: CGColor
    var iris: CGColor
    var pupil: CGColor?
    var mark: CGColor?
    var tongueOut = false
    var cloak: (cape: CGColor, mantle: CGColor, clasp: CGColor)?
}

let themes: [String: Theme] = [
    "mochi": Theme(fur: rgb(0x9BE8D0), furShade: rgb(0x72CFB2), outline: rgb(0x2C5F56), cream: rgb(0xF5FFFA),
                   earPink: rgb(0xFFB7C5), blush: rgb(0xFF8FA8, 0.5), iris: rgb(0x1E2B2A), mark: rgb(0x72CFB2)),
    "ghost": Theme(fur: rgb(0xF7F8FA), furShade: rgb(0xD9DFE6), outline: rgb(0x46505C), cream: rgb(0xFFFFFF),
                   earPink: rgb(0xF4C3CC), blush: rgb(0xFF9DB0, 0.4), iris: rgb(0xD7263D), pupil: rgb(0x6E0F1C),
                   tongueOut: true, cloak: (cape: rgb(0x1E2228), mantle: rgb(0x4A4F58), clasp: rgb(0xC9CED6))),
]

var cliArgs = Array(CommandLine.arguments.dropFirst())
let themeName = cliArgs.first.flatMap { themes[$0] != nil ? $0 : nil } ?? "ghost"
if cliArgs.first == themeName { cliArgs.removeFirst() }
let theme = themes[themeName]!

let fur = theme.fur
let furShade = theme.furShade
let outline = theme.outline
let cream = theme.cream
let earPink = theme.earPink
let blush = theme.blush
let ink = rgb(0x1E2B2A)
let tongue = rgb(0xFF8FA3)
let tearBlue = rgb(0x8FD3FF)
let laptopBody = rgb(0x3B5563)
let laptopEdge = rgb(0x253842)
let glassTint = rgb(0xE8F6FF)
let water = rgb(0x6EC6F5)

// MARK: - Pose

enum Eyes { case open(CGFloat), happy, sad, closed, focused }
enum Mouth { case smile, open, frown, oh, flat }

struct Pose {
    var y: CGFloat = 0
    var squash: CGFloat = 1
    var lean: CGFloat = 0
    var headTilt: CGFloat = 0
    var head = CGPoint.zero
    var ears: CGFloat = 0
    var earTwitch: CGFloat = 0
    var eyes: Eyes = .open(1)
    var look = CGPoint.zero
    var mouth: Mouth = .smile
    var tail: CGFloat = 0
    var leftFoot: CGFloat = 0
    var rightFoot: CGFloat = 0
    var wave: CGFloat?
    var askPaw = false
    var chinPaw = false
    var laptop = false
    var typing: CGFloat = 0
    var tear = false
    /// Mug held in both paws: 0 at the chest, 1 at the mouth.
    var cup: CGFloat?
    /// Both arms raised: 0 out at the sides, 1 straight overhead.
    var reach: CGFloat?
    var sparkle = false
}

// MARK: - Drawing helpers

let lineWidth: CGFloat = 5

func ellipse(_ c: CGPoint, _ w: CGFloat, _ h: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), transform: nil)
}

/// Strokes every path first and fills afterwards, so overlapping parts share one silhouette outline.
func silhouette(_ ctx: CGContext, _ parts: [(CGPath, CGColor)]) {
    ctx.setStrokeColor(outline)
    ctx.setLineWidth(lineWidth * 2)
    ctx.setLineJoin(.round)
    for (path, _) in parts { ctx.addPath(path); ctx.strokePath() }
    for (path, color) in parts { ctx.setFillColor(color); ctx.addPath(path); ctx.fillPath() }
}

func stroke(_ ctx: CGContext, _ width: CGFloat, _ color: CGColor = ink, _ build: (CGMutablePath) -> Void) {
    let path = CGMutablePath()
    build(path)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(path)
    ctx.strokePath()
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.addPath(path)
    ctx.fillPath()
}

func rotated(_ path: CGPath, around p: CGPoint, by angle: CGFloat) -> CGPath {
    var t = CGAffineTransform(translationX: p.x, y: p.y).rotated(by: angle).translatedBy(x: -p.x, y: -p.y)
    return path.copy(using: &t) ?? path
}

// MARK: - Parts (cell coordinates: origin bottom-left, ground at y = 18)

func tailPath(_ angle: CGFloat) -> (CGPath, CGPath) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 116, y: 38))
    p.addCurve(to: CGPoint(x: 158, y: 100), control1: CGPoint(x: 160, y: 36), control2: CGPoint(x: 172, y: 70))
    p.addCurve(to: CGPoint(x: 124, y: 62), control1: CGPoint(x: 146, y: 96), control2: CGPoint(x: 134, y: 78))
    p.closeSubpath()
    let anchor = CGPoint(x: 120, y: 46)
    return (rotated(p, around: anchor, by: angle), rotated(ellipse(CGPoint(x: 154, y: 90), 20, 24), around: anchor, by: angle))
}

func earPath(left: Bool) -> (outer: CGPath, inner: CGPath, base: CGPoint) {
    let s: CGFloat = left ? -1 : 1
    let outer = CGMutablePath()
    outer.move(to: CGPoint(x: s * 50, y: 22))
    outer.addQuadCurve(to: CGPoint(x: s * 44, y: 80), control: CGPoint(x: s * 58, y: 60))
    outer.addQuadCurve(to: CGPoint(x: s * 12, y: 42), control: CGPoint(x: s * 22, y: 70))
    outer.closeSubpath()
    let inner = CGMutablePath()
    inner.move(to: CGPoint(x: s * 42, y: 32))
    inner.addQuadCurve(to: CGPoint(x: s * 42, y: 68), control: CGPoint(x: s * 48, y: 56))
    inner.addQuadCurve(to: CGPoint(x: s * 22, y: 42), control: CGPoint(x: s * 28, y: 60))
    inner.closeSubpath()
    return (outer, inner, CGPoint(x: s * 32, y: 32))
}

func cheekTufts() -> CGPath {
    let p = CGMutablePath()
    for s: CGFloat in [-1, 1] {
        p.move(to: CGPoint(x: s * 48, y: 2))
        p.addLine(to: CGPoint(x: s * 66, y: -16))
        p.addLine(to: CGPoint(x: s * 50, y: -18))
        p.addLine(to: CGPoint(x: s * 58, y: -30))
        p.addLine(to: CGPoint(x: s * 36, y: -30))
        p.closeSubpath()
    }
    return p
}

func drawEye(_ ctx: CGContext, at c: CGPoint, style: Eyes, look: CGPoint, left: Bool) {
    let shift = CGPoint(x: c.x + look.x * 4, y: c.y + look.y * 4)
    switch style {
    case .open(let amount) where amount < 0.3:
        stroke(ctx, 4) { $0.move(to: CGPoint(x: c.x - 9, y: c.y)); $0.addLine(to: CGPoint(x: c.x + 9, y: c.y)) }
    case .open(let amount):
        fill(ctx, ellipse(shift, 21, 26 * amount), theme.iris)
        if let pupil = theme.pupil { fill(ctx, ellipse(CGPoint(x: shift.x, y: shift.y - 1), 11, 14 * amount), pupil) }
        fill(ctx, ellipse(CGPoint(x: shift.x - 3, y: shift.y + 5 * amount), 8, 8 * amount), cream)
        fill(ctx, ellipse(CGPoint(x: shift.x + 4, y: shift.y - 5 * amount), 4, 4 * amount), cream)
    case .happy:
        stroke(ctx, 4.5) {
            $0.move(to: CGPoint(x: c.x - 10, y: c.y - 3))
            $0.addQuadCurve(to: CGPoint(x: c.x + 10, y: c.y - 3), control: CGPoint(x: c.x, y: c.y + 12))
        }
    case .closed:
        stroke(ctx, 4.5) {
            $0.move(to: CGPoint(x: c.x - 10, y: c.y + 2))
            $0.addQuadCurve(to: CGPoint(x: c.x + 10, y: c.y + 2), control: CGPoint(x: c.x, y: c.y - 9))
        }
    case .sad:
        fill(ctx, ellipse(CGPoint(x: shift.x, y: shift.y - 2), 19, 21), theme.iris)
        if let pupil = theme.pupil { fill(ctx, ellipse(CGPoint(x: shift.x, y: shift.y - 3), 10, 12), pupil) }
        fill(ctx, ellipse(CGPoint(x: shift.x - 3, y: shift.y + 2), 7, 7), cream)
        let s: CGFloat = left ? -1 : 1
        stroke(ctx, 3.5, outline) {
            $0.move(to: CGPoint(x: c.x - s * 2, y: c.y + 20))
            $0.addLine(to: CGPoint(x: c.x + s * 12, y: c.y + 15))
        }
    case .focused:
        fill(ctx, ellipse(CGPoint(x: shift.x, y: shift.y - 2), 19, 20), theme.iris)
        if let pupil = theme.pupil { fill(ctx, ellipse(CGPoint(x: shift.x, y: shift.y - 3), 10, 11), pupil) }
        fill(ctx, ellipse(CGPoint(x: shift.x - 3, y: shift.y + 2), 7, 7), cream)
        fill(ctx, ellipse(CGPoint(x: shift.x + 4, y: shift.y - 6), 3, 3), cream)
    }
}

func drawMouth(_ ctx: CGContext, _ mouth: Mouth) {
    switch mouth {
    case .smile:
        if theme.tongueOut {
            let t = CGMutablePath()
            t.addRoundedRect(in: CGRect(x: -5.5, y: -34, width: 11, height: 14), cornerWidth: 5.5, cornerHeight: 5.5)
            fill(ctx, t, tongue)
            stroke(ctx, 1.5, rgb(0xE06A80)) { $0.move(to: CGPoint(x: 0, y: -23)); $0.addLine(to: CGPoint(x: 0, y: -30)) }
        }
        stroke(ctx, 3.5) {
            $0.move(to: CGPoint(x: -10, y: -21))
            $0.addQuadCurve(to: CGPoint(x: 0, y: -18), control: CGPoint(x: -5, y: -27))
            $0.addQuadCurve(to: CGPoint(x: 10, y: -21), control: CGPoint(x: 5, y: -27))
        }
    case .open:
        let m = CGMutablePath()
        m.move(to: CGPoint(x: -10, y: -19))
        m.addQuadCurve(to: CGPoint(x: 10, y: -19), control: CGPoint(x: 0, y: -40))
        m.closeSubpath()
        fill(ctx, m, ink)
        fill(ctx, ellipse(CGPoint(x: 0, y: -29), 10, 7), tongue)
    case .frown:
        stroke(ctx, 3.5) {
            $0.move(to: CGPoint(x: -8, y: -27))
            $0.addQuadCurve(to: CGPoint(x: 8, y: -27), control: CGPoint(x: 0, y: -19))
        }
    case .oh:
        fill(ctx, ellipse(CGPoint(x: 0, y: -25), 9, 10), ink)
    case .flat:
        stroke(ctx, 3.5) { $0.move(to: CGPoint(x: -6, y: -23)); $0.addLine(to: CGPoint(x: 6, y: -23)) }
    }
}

func paw(_ c: CGPoint) -> CGPath { ellipse(c, 22, 18) }

// MARK: - Character

func drawWolf(_ ctx: CGContext, _ pose: Pose) {
    ctx.saveGState()
    // Scale the whole character about the ground point so jumps stay inside the cell.
    ctx.translateBy(x: 96, y: 18 + pose.y)
    ctx.scaleBy(x: 0.8, y: 0.8 * pose.squash)
    ctx.translateBy(x: -96, y: -18)

    let (tail, tailTip) = tailPath(pose.tail)
    silhouette(ctx, [(tail, fur)])
    ctx.saveGState(); ctx.addPath(tail); ctx.clip(); fill(ctx, tailTip, cream); ctx.restoreGState()

    let bodyX = 96 + pose.lean * 0.5
    let headCenter = CGPoint(x: 96 + pose.lean + pose.head.x, y: 120 + pose.head.y)
    var headT = CGAffineTransform(translationX: headCenter.x, y: headCenter.y).rotated(by: pose.headTilt)

    let left = earPath(left: true), right = earPath(left: false)
    let leftEar = rotated(left.outer, around: left.base, by: pose.ears)
    let rightEar = rotated(right.outer, around: right.base, by: -pose.ears - pose.earTwitch)
    let headParts = [leftEar, rightEar, cheekTufts(), ellipse(.zero, 120, 98)].compactMap { $0.copy(using: &headT) }

    let bodyParts: [(CGPath, CGColor)] = [
        (ellipse(CGPoint(x: 78, y: 26 + pose.leftFoot), 28, 18), furShade),
        (ellipse(CGPoint(x: 114, y: 26 + pose.rightFoot), 28, 18), furShade),
        (ellipse(CGPoint(x: bodyX, y: 56), 76, 64), fur),
    ]

    if let cloak = theme.cloak {
        // Night's Watch cloak behind the body, fur mantle across the shoulders, head on top.
        let flutter = -pose.lean * 0.6
        let cape = CGMutablePath()
        cape.move(to: CGPoint(x: bodyX - 34, y: 80))
        cape.addLine(to: CGPoint(x: bodyX + 34, y: 80))
        cape.addQuadCurve(to: CGPoint(x: bodyX + 46 + flutter, y: 24), control: CGPoint(x: bodyX + 46, y: 52))
        cape.addQuadCurve(to: CGPoint(x: bodyX - 46 + flutter, y: 24), control: CGPoint(x: bodyX + flutter, y: 16))
        cape.addQuadCurve(to: CGPoint(x: bodyX - 34, y: 80), control: CGPoint(x: bodyX - 46, y: 52))
        cape.closeSubpath()
        silhouette(ctx, [(cape, cloak.cape)])
        silhouette(ctx, bodyParts)
        fill(ctx, ellipse(CGPoint(x: bodyX, y: 50), 46, 40), cream)

        let mantle = CGMutablePath()
        mantle.move(to: CGPoint(x: bodyX - 46, y: 78))
        mantle.addQuadCurve(to: CGPoint(x: bodyX + 46, y: 78), control: CGPoint(x: bodyX, y: 94))
        let teeth = 8
        for i in 0...teeth {
            let x = bodyX + 46 - CGFloat(i) * 92 / CGFloat(teeth)
            let y: CGFloat = i % 2 == 0 ? 70 : 64
            mantle.addLine(to: CGPoint(x: x, y: y))
        }
        mantle.closeSubpath()
        silhouette(ctx, [(mantle, cloak.mantle)])
        silhouette(ctx, headParts.map { ($0, fur) })
        let clasp = ellipse(CGPoint(x: bodyX + 30, y: 72), 11, 11)
        silhouette(ctx, [(clasp, cloak.clasp)])
    } else {
        silhouette(ctx, bodyParts + headParts.map { ($0, fur) })
        fill(ctx, ellipse(CGPoint(x: bodyX, y: 50), 46, 40), cream)
    }

    // Face, drawn in head space.
    ctx.saveGState()
    ctx.concatenate(headT)
    fill(ctx, rotated(left.inner, around: left.base, by: pose.ears), earPink)
    fill(ctx, rotated(right.inner, around: right.base, by: -pose.ears - pose.earTwitch), earPink)
    if let markColor = theme.mark {
        let mark = CGMutablePath()
        mark.move(to: CGPoint(x: 0, y: 44)); mark.addLine(to: CGPoint(x: 9, y: 30))
        mark.addLine(to: CGPoint(x: 0, y: 22)); mark.addLine(to: CGPoint(x: -9, y: 30)); mark.closeSubpath()
        fill(ctx, mark, markColor)
    }
    let muzzleShift = CGPoint(x: pose.look.x * 3, y: pose.look.y * 2)
    fill(ctx, ellipse(CGPoint(x: muzzleShift.x, y: -20 + muzzleShift.y), 66, 42), cream)
    fill(ctx, ellipse(CGPoint(x: -40, y: -10), 18, 10), blush)
    fill(ctx, ellipse(CGPoint(x: 40, y: -10), 18, 10), blush)
    drawEye(ctx, at: CGPoint(x: -26 + pose.look.x * 3, y: 6 + pose.look.y * 3), style: pose.eyes, look: pose.look, left: true)
    drawEye(ctx, at: CGPoint(x: 26 + pose.look.x * 3, y: 6 + pose.look.y * 3), style: pose.eyes, look: pose.look, left: false)
    ctx.saveGState()
    ctx.translateBy(x: muzzleShift.x, y: muzzleShift.y)
    let nose = CGMutablePath()
    nose.move(to: CGPoint(x: -8, y: -9))
    nose.addQuadCurve(to: CGPoint(x: 8, y: -9), control: CGPoint(x: 0, y: -5))
    nose.addQuadCurve(to: CGPoint(x: 0, y: -18), control: CGPoint(x: 6, y: -16))
    nose.addQuadCurve(to: CGPoint(x: -8, y: -9), control: CGPoint(x: -6, y: -16))
    fill(ctx, nose, ink)
    fill(ctx, ellipse(CGPoint(x: -2, y: -10), 4, 2.5), rgb(0xFFFFFF, 0.7))
    drawMouth(ctx, pose.mouth)
    ctx.restoreGState()
    if pose.tear {
        let t = CGMutablePath()
        t.move(to: CGPoint(x: -32, y: -4))
        t.addQuadCurve(to: CGPoint(x: -32, y: -24), control: CGPoint(x: -42, y: -18))
        t.addQuadCurve(to: CGPoint(x: -32, y: -4), control: CGPoint(x: -22, y: -18))
        fill(ctx, t, tearBlue)
    }
    ctx.restoreGState()

    // Front layer: laptop and paws.
    if pose.laptop {
        let lid = CGPath(roundedRect: CGRect(x: 62, y: 22, width: 68, height: 46), cornerWidth: 8, cornerHeight: 8, transform: nil)
        silhouette(ctx, [(lid, laptopBody)])
        fill(ctx, ellipse(CGPoint(x: 96, y: 45), 12, 10), fur)
        for dx: CGFloat in [-7, -2.5, 2.5, 7] { fill(ctx, ellipse(CGPoint(x: 96 + dx, y: 53 + (abs(dx) > 5 ? -2 : 0)), 4, 4), fur) }
        fill(ctx, CGPath(rect: CGRect(x: 62, y: 22, width: 68, height: 4), transform: nil), laptopEdge)
        silhouette(ctx, [(paw(CGPoint(x: 76, y: 70 + max(0, pose.typing) * 6)), fur),
                         (paw(CGPoint(x: 116, y: 70 + max(0, -pose.typing) * 6)), fur)])
    } else if let lift = pose.cup {
        let low = CGPoint(x: bodyX + 2, y: 56)
        let high = CGPoint(x: headCenter.x + 14, y: headCenter.y - 32)
        let c = CGPoint(x: low.x + (high.x - low.x) * lift, y: low.y + (high.y - low.y) * lift)
        var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: 0.6 * lift)
        // A tapered glass, wider at the rim, with the water level tilting less than the glass.
        let glass = CGMutablePath()
        glass.move(to: CGPoint(x: -13, y: -20))
        glass.addLine(to: CGPoint(x: 13, y: -20))
        glass.addLine(to: CGPoint(x: 17, y: 22))
        glass.addLine(to: CGPoint(x: -17, y: 22))
        glass.closeSubpath()
        silhouette(ctx, [(glass.copy(using: &t) ?? glass, glassTint)])
        ctx.saveGState()
        ctx.concatenate(t)
        ctx.addPath(glass); ctx.clip()
        fill(ctx, CGPath(rect: CGRect(x: -30, y: -30, width: 60, height: 36 - 14 * lift), transform: nil), water)
        fill(ctx, CGPath(rect: CGRect(x: -9, y: -14, width: 4, height: 30), transform: nil), rgb(0xFFFFFF, 0.75))
        ctx.restoreGState()
        silhouette(ctx, [(paw(CGPoint(x: -17, y: -6).applying(t)), fur), (paw(CGPoint(x: 17, y: -8).applying(t)), fur)])
    } else if pose.reach == nil {
        var paws: [(CGPath, CGColor)] = []
        paws.append((paw(CGPoint(x: bodyX - 20, y: pose.askPaw ? 86 : 50)), fur))
        if pose.chinPaw {
            paws.append((paw(CGPoint(x: headCenter.x + 18, y: headCenter.y - 44)), fur))
        } else if pose.wave == nil {
            paws.append((paw(CGPoint(x: bodyX + 20, y: 50)), fur))
        }
        silhouette(ctx, paws)
    }
    if let wave = pose.wave {
        let shoulder = CGPoint(x: bodyX + 30, y: 66)
        let hand = CGPoint(x: shoulder.x + cos(wave) * 44, y: shoulder.y + sin(wave) * 44)
        let arm = CGMutablePath()
        arm.move(to: shoulder); arm.addLine(to: hand)
        let armShape = arm.copy(strokingWithWidth: 18, lineCap: .round, lineJoin: .round, miterLimit: 1)
        silhouette(ctx, [(armShape, fur), (paw(hand), fur)])
    }
    if let reach = pose.reach {
        // Elbows bend out around the big head so the arms stay visible.
        func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * reach, y: a.y + (b.y - a.y) * reach) }
        var arms: [(CGPath, CGColor)] = []
        for s: CGFloat in [-1, 1] {
            let shoulder = CGPoint(x: bodyX + s * 30, y: 68)
            let elbow = mix(CGPoint(x: bodyX + s * 58, y: 58), CGPoint(x: headCenter.x + s * 80, y: headCenter.y - 2))
            let hand = mix(CGPoint(x: bodyX + s * 80, y: 50), CGPoint(x: headCenter.x + s * 62, y: headCenter.y + 70))
            let arm = CGMutablePath()
            arm.move(to: shoulder)
            arm.addQuadCurve(to: hand, control: elbow)
            arms.append((arm.copy(strokingWithWidth: 17, lineCap: .round, lineJoin: .round, miterLimit: 1), fur))
            arms.append((paw(hand), fur))
        }
        silhouette(ctx, arms)
    }
    if pose.sparkle {
        for (c, r) in [(CGPoint(x: headCenter.x + 64, y: headCenter.y + 26), CGFloat(10)),
                       (CGPoint(x: headCenter.x + 50, y: headCenter.y + 48), CGFloat(6))] {
            let star = CGMutablePath()
            star.move(to: CGPoint(x: c.x, y: c.y + r))
            star.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
            star.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
            star.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
            star.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
            fill(ctx, star, water)
        }
    }
    ctx.restoreGState()
}

// MARK: - Animation rows

func rowPoses(_ row: Int) -> [Pose] {
    func wag(_ i: Int, _ n: Int, _ amp: CGFloat = 0.12) -> CGFloat { sin(CGFloat(i) / CGFloat(n) * 2 * .pi) * amp }
    switch row {
    case 0: // idle: breathing, one blink
        return (0..<6).map { i in
            var p = Pose()
            p.y = [0, 1, 2, 2, 1, 0][i]
            p.squash = [1, 1.01, 1.02, 1.02, 1.01, 1][i]
            p.eyes = i == 3 ? .open(0.1) : .open(1)
            p.tail = wag(i, 6, 0.08)
            return p
        }
    case 1, 2: // drag right (row 2 is mirrored when composed)
        return (0..<8).map { i in
            var p = Pose()
            let phase = CGFloat(i) / 8 * 2 * .pi
            p.lean = 8
            p.head = CGPoint(x: 4, y: abs(sin(phase)) * 3)
            p.y = abs(sin(phase)) * 4
            p.look = CGPoint(x: 1, y: 0)
            p.ears = 0.22
            p.leftFoot = max(0, sin(phase)) * 8
            p.rightFoot = max(0, -sin(phase)) * 8
            p.tail = -0.25 + wag(i, 8, 0.15)
            p.mouth = .open
            return p
        }
    case 3: // waving
        return (0..<4).map { i in
            var p = Pose()
            p.wave = [0.25, 0.85, 0.5, 0.9][i]
            p.eyes = .happy
            p.mouth = .open
            p.headTilt = -0.05
            p.tail = wag(i, 4, 0.15)
            return p
        }
    case 4: // jumping
        return (0..<5).map { i in
            var p = Pose()
            p.y = [0, 18, 32, 14, 0][i]
            p.squash = [0.88, 1.06, 1, 1.04, 0.92][i]
            p.eyes = i == 0 || i == 4 ? .open(1) : .happy
            p.mouth = i == 0 || i == 4 ? .smile : .open
            p.ears = [0.1, -0.12, -0.15, -0.1, 0.1][i]
            p.leftFoot = [0, 4, 6, 4, 0][i]
            p.rightFoot = [0, 4, 6, 4, 0][i]
            p.tail = [0, 0.2, 0.3, 0.15, 0][i]
            return p
        }
    case 5: // failed
        return (0..<8).map { i in
            var p = Pose()
            p.y = -2
            p.squash = 0.97
            p.ears = 0.55
            p.eyes = .sad
            p.mouth = .frown
            p.head = CGPoint(x: [0, -3, 3, -3, 3, -2, 0, 0][i], y: -3)
            p.tear = i >= 2
            p.tail = -0.45
            return p
        }
    case 6: // waiting for input
        return (0..<6).map { i in
            var p = Pose()
            p.headTilt = [0.08, 0.11, 0.13, 0.11, 0.09, 0.07][i]
            p.look = CGPoint(x: 0.2, y: 0.6)
            p.mouth = .oh
            p.askPaw = true
            p.earTwitch = i == 2 || i == 3 ? 0.18 : 0
            p.tail = wag(i, 6, 0.18)
            return p
        }
    case 7: // working
        return (0..<6).map { i in
            var p = Pose()
            p.laptop = true
            p.typing = [1, -1, 1, -1, 1, -1][i]
            p.eyes = .focused
            p.look = CGPoint(x: 0, y: -0.7)
            p.mouth = .smile
            p.head = CGPoint(x: 0, y: -2)
            p.tail = wag(i, 6, 0.1)
            return p
        }
    case 8: // reviewing finished work
        return (0..<6).map { i in
            var p = Pose()
            p.headTilt = -0.1
            p.chinPaw = true
            p.eyes = i == 4 ? .open(0.1) : .open(0.85)
            p.look = CGPoint(x: -0.5, y: -0.4)
            p.mouth = i >= 3 ? .smile : .flat
            p.tail = wag(i, 6, 0.08)
            return p
        }
    case 11: // drinking water (ironpet extra row)
        return (0..<6).map { i in
            var p = Pose()
            p.cup = [0, 0.55, 1, 1, 0.45, 0][i]
            p.eyes = [.open(1), .open(1), .closed, .closed, .happy, .happy][i]
            p.mouth = i == 4 ? .open : .smile
            p.look = i < 2 ? CGPoint(x: 0.3, y: -0.5) : .zero
            p.head = CGPoint(x: 0, y: [0, 1, 4, 5, 2, 0][i])
            p.headTilt = [0, -0.03, -0.1, -0.12, -0.04, 0][i]
            p.sparkle = i == 5
            p.tail = wag(i, 6, 0.12)
            return p
        }
    case 12: // stretching (ironpet extra row)
        return (0..<8).map { i in
            var p = Pose()
            p.reach = [0.15, 0.6, 1, 1, 1, 1, 0.55, 0.1][i]
            p.squash = [1, 1.03, 1.07, 1.08, 1.06, 1.06, 1.02, 1][i]
            p.y = [0, 1, 3, 4, 3, 3, 1, 0][i]
            p.lean = [0, 0, 0, 0, -7, 7, 0, 0][i]
            p.headTilt = [0, 0, 0, 0, 0.1, -0.1, 0, 0][i]
            p.eyes = i >= 2 && i <= 5 ? .closed : .happy
            p.mouth = i == 2 || i == 3 ? .open : .smile
            p.ears = i >= 2 && i <= 5 ? -0.1 : 0
            p.tail = wag(i, 8, 0.1)
            return p
        }
    default:
        return []
    }
}

/// 16 look directions, clockwise from straight up.
func lookPose(_ index: Int) -> Pose {
    let angle = CGFloat(index) * 22.5 * .pi / 180
    let dir = CGPoint(x: sin(angle), y: cos(angle))
    var p = Pose()
    p.look = dir
    p.head = CGPoint(x: dir.x * 5, y: dir.y * 4)
    p.headTilt = -dir.x * 0.07
    p.ears = -dir.y * 0.06
    return p
}

// MARK: - Atlas

// Rows 0-10 follow the Codex v2 layout; rows 11-12 (drinking, stretching) are ironpet extras.
let cellW = 192, cellH = 208, cols = 8, rows = 13

// `--single out.png`: one idle pose at 5x, transparent, for the app icon.
if cliArgs.first == "--single", cliArgs.count > 1 {
    let scale = 5
    let single = CGContext(data: nil, width: cellW * scale, height: cellH * scale, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    single.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    drawWolf(single, Pose())
    try! NSBitmapImageRep(cgImage: single.makeImage()!).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: cliArgs[1]))
    print("wrote \(cliArgs[1])")
    exit(0)
}
let width = cellW * cols, height = cellH * rows
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(true)

func drawCell(row: Int, col: Int, mirrored: Bool = false, _ pose: Pose) {
    ctx.saveGState()
    ctx.translateBy(x: CGFloat(col * cellW), y: CGFloat(height - (row + 1) * cellH))
    ctx.clip(to: CGRect(x: 0, y: 0, width: cellW, height: cellH))
    if mirrored { ctx.translateBy(x: CGFloat(cellW), y: 0); ctx.scaleBy(x: -1, y: 1) }
    drawWolf(ctx, pose)
    ctx.restoreGState()
}

for row in 0..<9 {
    for (col, pose) in rowPoses(row).enumerated() { drawCell(row: row, col: col, mirrored: row == 2, pose) }
}
for i in 0..<16 { drawCell(row: 9 + i / 8, col: i % 8, lookPose(i)) }
for row in 11..<rows {
    for (col, pose) in rowPoses(row).enumerated() { drawCell(row: row, col: col, pose) }
}

let output = cliArgs.first
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ironpet/pet/spritesheet.png").path
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! FileManager.default.createDirectory(atPath: (output as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
