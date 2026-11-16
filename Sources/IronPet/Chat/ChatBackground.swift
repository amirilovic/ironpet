import AppKit
import ImageIO
import SwiftUI

/// The picture behind the chat transcript: a built-in gradient with an optional tiled doodle pattern, or an image the
/// user picked. Built-ins are drawn in code, so the app bundle carries no image files. The soft colours stay close to
/// the system window colour in brightness, which keeps text, links and code blocks as readable as on the plain
/// background.
enum ChatBackground {
    static let defaultID = "default"
    static let customID = "custom"

    enum Doodle: CaseIterable { case paw, ghost, star, bubble, leaf }

    struct BuiltIn: Identifiable {
        let id: String
        let name: String
        /// Top and bottom colours of the gradient, as hex, for light and dark mode.
        let light: (UInt32, UInt32)
        let dark: (UInt32, UInt32)
        /// Line colour of the doodles, as hex, for light and dark mode. Drawn at `inkOpacity` (120% of it in dark mode). Both are low enough that a link stays at 4.5:1 or better on a stroke.
        let lightInk: UInt32
        let darkInk: UInt32
        let inkOpacity: Double
        /// Empty for a plain gradient.
        let doodles: [Doodle]
    }

    static let builtIns: [BuiltIn] = [
        BuiltIn(id: "dusk", name: "Dusk", light: (0xF6F8FD, 0xEEF2FB), dark: (0x1F2233, 0x181D2B),
                lightInk: 0x000000, darkInk: 0xFFFFFF, inkOpacity: 0, doodles: []),
        BuiltIn(id: "paws", name: "Paws", light: (0xF2FAF5, 0xE9F6EF), dark: (0x1A2A24, 0x15221D),
                lightInk: 0x2F6B4F, darkInk: 0xA8E0C6, inkOpacity: 0.04, doodles: [.paw, .star]),
        BuiltIn(id: "ghosts", name: "Ghosts", light: (0xF8F4FD, 0xF1ECFB), dark: (0x25203A, 0x1C1830),
                lightInk: 0x5B4A8C, darkInk: 0xC9BDF2, inkOpacity: 0.035, doodles: [.ghost, .star, .bubble]),
        BuiltIn(id: "chatter", name: "Chatter", light: (0xFEF7EF, 0xFBEFE2), dark: (0x2E2420, 0x241C19),
                lightInk: 0x9A5B2E, darkInk: 0xF0C7A0, inkOpacity: 0.04, doodles: [.bubble, .star, .paw]),
        BuiltIn(id: "leaves", name: "Leaves", light: (0xF4F9EF, 0xEBF4E1), dark: (0x1E2818, 0x182012),
                lightInk: 0x4B7A2E, darkInk: 0xBEE3A0, inkOpacity: 0.04, doodles: [.leaf, .star]),
    ]

    static func builtIn(_ id: String) -> BuiltIn? { builtIns.first { $0.id == id } }

    /// Where imported images live, inside ironpet's own data folder.
    static let folder = Paths.root.appendingPathComponent("backgrounds")

    enum ImportError: LocalizedError {
        case notAnImage
        var errorDescription: String? { "That file is not an image ironpet can read." }
    }

    /// Copies `source` into `folder` under a fresh name and returns the file name. Moving or deleting the original
    /// afterwards does not affect the background. Removes the previously imported image.
    static func importImage(from source: URL, into folder: URL = ChatBackground.folder, replacing old: String? = nil) throws -> String {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(image) > 0 else {
            throw ImportError.notAnImage
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = source.pathExtension.lowercased()
        let keepsFormat = ["png", "jpg", "jpeg"].contains(ext)
        let name = "custom-\(UUID().uuidString.prefix(8))." + (keepsFormat ? ext : "png")
        let target = folder.appendingPathComponent(name)
        if keepsFormat {
            try FileManager.default.copyItem(at: source, to: target)
        } else {
            // Other formats are stored as PNG.
            guard let cg = CGImageSourceCreateImageAtIndex(image, 0, nil),
                  let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw ImportError.notAnImage }
            try data.write(to: target)
        }
        if let old, old != name { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
        return name
    }

    /// Decoded custom images, at most 2400 px on the long side, so a 40 MP photo does not sit in memory at full size.
    @MainActor private static var imageCache: [String: NSImage] = [:]

    @MainActor
    static func customImage(named name: String, in folder: URL = ChatBackground.folder) -> NSImage? {
        if let cached = imageCache[name] { return cached }
        let url = folder.appendingPathComponent(name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 2400]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        imageCache = [name: image]
        return image
    }
}

/// Draws the chosen background. `scale` shrinks the doodles for thumbnails.
struct ChatBackgroundView: View {
    let id: String
    var customFile: String?
    var scale: CGFloat = 1
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let builtIn = ChatBackground.builtIn(id) {
            BuiltInBackground(builtIn: builtIn, dark: scheme == .dark, scale: scale).equatable()
        } else if id == ChatBackground.customID, let file = customFile, let image = ChatBackground.customImage(named: file) {
            // Aspect-fill: the image covers the panel and the overflow is cropped.
            Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill() }.clipped()
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

private struct BuiltInBackground: View, Equatable {
    let builtIn: ChatBackground.BuiltIn
    let dark: Bool
    let scale: CGFloat

    static func == (a: Self, b: Self) -> Bool { a.builtIn.id == b.builtIn.id && a.dark == b.dark && a.scale == b.scale }

    private static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    var body: some View {
        let colors = dark ? builtIn.dark : builtIn.light
        let ink = Self.color(dark ? builtIn.darkInk : builtIn.lightInk).opacity(dark ? builtIn.inkOpacity * 1.2 : builtIn.inkOpacity)
        let doodles = builtIn.doodles
        // The canvas draws once per size or appearance change, not while the transcript scrolls over it.
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: [Self.color(colors.0), Self.color(colors.1)]),
                                               startPoint: .zero, endPoint: CGPoint(x: size.width * 0.4, y: size.height)))
            guard !doodles.isEmpty else { return }
            let cell = 78 * scale
            let rows = Int(size.height / cell) + 2
            let cols = Int(size.width / cell) + 2
            for row in -1..<rows {
                for col in -1..<cols {
                    // A staggered grid with a fixed pseudo-random kind, tilt and nudge per cell, so the pattern tiles.
                    let seed = (row &* 7 &+ col &* 13) & 0xFF
                    let kind = doodles[((row &* 3 &+ col &* 5) % doodles.count + doodles.count) % doodles.count]
                    let x = (CGFloat(col) + (row & 1 == 0 ? 0.25 : 0.75)) * cell + CGFloat(seed % 7 - 3) * scale
                    let y = (CGFloat(row) + 0.5) * cell + CGFloat(seed % 5 - 2) * scale
                    var layer = context
                    layer.translateBy(x: x, y: y)
                    layer.rotate(by: .degrees(Double(seed % 9 - 4) * 5))
                    layer.scaleBy(x: scale, y: scale)
                    layer.stroke(Self.path(kind), with: .color(ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// A doodle about 26 pt across, centered on the origin.
    private static func path(_ kind: ChatBackground.Doodle) -> Path {
        var p = Path()
        switch kind {
        case .paw:
            p.addEllipse(in: CGRect(x: -6, y: 1, width: 12, height: 9))
            for (x, y) in [(-9.0, -3.0), (-3.5, -8.0), (3.5, -8.0), (9.0, -3.0)] {
                p.addEllipse(in: CGRect(x: x - 2.4, y: y - 3, width: 4.8, height: 6))
            }
        case .ghost:
            p.move(to: CGPoint(x: -9, y: 10))
            p.addLine(to: CGPoint(x: -9, y: -2))
            p.addCurve(to: CGPoint(x: 9, y: -2), control1: CGPoint(x: -9, y: -16), control2: CGPoint(x: 9, y: -16))
            p.addLine(to: CGPoint(x: 9, y: 10))
            p.addLine(to: CGPoint(x: 4.5, y: 6))
            p.addLine(to: CGPoint(x: 0, y: 10))
            p.addLine(to: CGPoint(x: -4.5, y: 6))
            p.closeSubpath()
            p.addEllipse(in: CGRect(x: -5, y: -4, width: 2.4, height: 3))
            p.addEllipse(in: CGRect(x: 2.6, y: -4, width: 2.4, height: 3))
        case .star:
            for i in 0..<10 {
                let angle = Double(i) * .pi / 5 - .pi / 2
                let radius: CGFloat = i % 2 == 0 ? 10 : 4.2
                let point = CGPoint(x: radius * CGFloat(cos(angle)), y: radius * CGFloat(sin(angle)))
                if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
            }
            p.closeSubpath()
        case .bubble:
            p.addRoundedRect(in: CGRect(x: -11, y: -9, width: 22, height: 15), cornerSize: CGSize(width: 6, height: 6))
            p.move(to: CGPoint(x: -4, y: 6))
            p.addLine(to: CGPoint(x: -7, y: 11))
            p.addLine(to: CGPoint(x: 1, y: 6))
        case .leaf:
            p.move(to: CGPoint(x: -9, y: 9))
            p.addCurve(to: CGPoint(x: 9, y: -9), control1: CGPoint(x: -12, y: -6), control2: CGPoint(x: 0, y: -12))
            p.addCurve(to: CGPoint(x: -9, y: 9), control1: CGPoint(x: 12, y: 4), control2: CGPoint(x: 0, y: 12))
            p.move(to: CGPoint(x: -9, y: 9))
            p.addLine(to: CGPoint(x: 3, y: -3))
        }
        return p
    }
}

/// The chat panel's backdrop. Observes the config itself so a change in Settings shows at once without redrawing the
/// transcript above it.
struct ChatBackdrop: View {
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            ChatBackgroundView(id: store.config.chat.background, customFile: store.config.chat.customImage)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
