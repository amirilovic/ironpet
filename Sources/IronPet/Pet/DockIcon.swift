import AppKit

/// The Dock and ⌘-Tab icon while the app runs: the chosen pet's idle frame. Only `NSApp.applicationIconImage` changes.
/// The app bundle and the Finder icon stay as they are.
enum DockIcon {
    static let pixels = 1024
    /// Share of each edge left empty so the pet does not touch the icon border.
    static let padding = 0.10

    /// The idle frame (row 0, column 0) scaled to fit a square canvas with padding, on a transparent background.
    /// Nil when the sheet has no idle frame or the frame is fully transparent.
    static func render(_ atlas: Atlas) -> NSImage? {
        guard let frame = atlas.frame(.idle, 0), frame.width > 0, frame.height > 0,
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let side = Double(pixels) * (1 - 2 * padding)
        let scale = min(side / Double(frame.width), side / Double(frame.height))
        let size = CGSize(width: Double(frame.width) * scale, height: Double(frame.height) * scale)
        context.interpolationQuality = .high
        context.draw(frame, in: CGRect(x: (Double(pixels) - size.width) / 2, y: (Double(pixels) - size.height) / 2,
                                       width: size.width, height: size.height))
        guard let image = context.makeImage(), hasVisiblePixels(context) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: pixels / 2, height: pixels / 2))
    }

    /// The icon for `pet.sprite`. An explicit path must load as an atlas. Unset means the default pet, as in `Atlas.loadDefault`.
    static func image(forSprite sprite: String?) -> NSImage? {
        let atlas: Atlas?
        if let sprite, !sprite.isEmpty {
            atlas = Atlas.load(URL(fileURLWithPath: (sprite as NSString).expandingTildeInPath))
        } else {
            atlas = Atlas.loadDefault(sprite: nil)
        }
        return atlas.flatMap(render)
    }

    private static func hasVisiblePixels(_ context: CGContext) -> Bool {
        guard let data = context.data else { return false }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        for row in 0..<context.height {
            let line = bytes + row * context.bytesPerRow
            for column in 0..<context.width where line[column * 4 + 3] != 0 { return true }
        }
        return false
    }
}

/// Applies the icon when the pet changes. `set` is `NSApp.applicationIconImage` in the app; nil restores the default icon.
@MainActor
final class DockIconController {
    private let load: (String?) -> NSImage?
    private let set: (NSImage?) -> Void
    private var applied: String??

    init(load: @escaping (String?) -> NSImage? = DockIcon.image(forSprite:),
         set: @escaping (NSImage?) -> Void = { NSApp.applicationIconImage = $0 }) {
        self.load = load
        self.set = set
    }

    /// Renders and sets the icon for `sprite`. The same value as last time does nothing.
    func update(sprite: String?) {
        let key = sprite?.isEmpty == true ? nil : sprite
        if let applied, applied == key { return }
        applied = .some(key)
        set(load(key))
    }
}
