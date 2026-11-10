// Renders chosen atlas cells at 2x on a light background for review.
// Run: swift tools/preview_cells.swift atlas.png out.png row:col [row:col ...]
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
let atlas = NSImage(contentsOfFile: args[0])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let cells = args.dropFirst(2).map { $0.split(separator: ":").map { Int($0)! } }
let scale = 2, w = 192, h = 208
let ctx = CGContext(data: nil, width: w * scale * cells.count, height: h * scale, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(gray: 0.93, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
for (i, rc) in cells.enumerated() {
    let cell = atlas.cropping(to: CGRect(x: rc[1] * w, y: rc[0] * h, width: w, height: h))!
    ctx.draw(cell, in: CGRect(x: i * w * scale, y: 0, width: w * scale, height: h * scale))
}
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
