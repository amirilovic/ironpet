// Renders the ironpet app icon (1024x1024 PNG): the pet on a wintry rounded tile.
// Run: swift tools/make_wolf.swift ghost --single /tmp/pet.png && swift tools/make_icon.swift /tmp/pet.png <output.png>
// The input is one high-resolution 192x208-proportioned pet frame.
import AppKit

let args = CommandLine.arguments
let pet = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// macOS icon grid: 824pt tile centered in the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x1C2A3A))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [rgb(0x2E4A66), rgb(0x16222F)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Snowy ground and a few snowflakes.
ctx.setFillColor(rgb(0xE8F1F8))
ctx.fillEllipse(in: CGRect(x: 40, y: -330, width: 944, height: 600))
let flakes: [(CGFloat, CGFloat, CGFloat)] = [(210, 780, 14), (330, 860, 9), (800, 800, 12), (720, 880, 8), (880, 650, 10),
                                              (170, 600, 9), (600, 840, 7), (260, 470, 7), (840, 470, 8)]
ctx.setFillColor(rgb(0xFFFFFF, 0.85))
for (x, y, r) in flakes { ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)) }

// The pet, scaled up from its 192x208 cell.
ctx.interpolationQuality = .high
let scale: CGFloat = 4.1
let petRect = CGRect(x: 512 - 96 * scale, y: 128, width: 192 * scale, height: 208 * scale)
ctx.draw(pet, in: petRect)
ctx.restoreGState()

ctx.addPath(tilePath)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.12))
ctx.setLineWidth(4)
ctx.strokePath()

try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
