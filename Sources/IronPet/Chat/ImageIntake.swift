import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Turns pasted or dropped images into PNG files in the screenshots folder, so they attach
/// exactly like a screenshot capture.
enum ImageIntake {
    enum PasteAction: Equatable {
        /// Let the text field handle the paste.
        case text
        /// Image files copied in Finder.
        case files([URL])
        /// Raw image data on the pasteboard (screenshot to clipboard, copied image).
        case data
    }

    static let maxSide = 4096
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp"]

    /// Image files win over their file name (Finder also puts the name on the pasteboard as text).
    /// Any other text wins over image data, so rich text copied from a browser still pastes as text.
    static func decide(_ pasteboard: NSPasteboard) -> PasteAction {
        let files = imageFiles(on: pasteboard)
        if !files.isEmpty { return .files(files) }
        if pasteboard.string(forType: .string) != nil { return .text }
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) { return .data }
        return .text
    }

    static func imageFiles(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(isImageFile)
    }

    static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Saves what the pasteboard holds as PNG copies. Originals are untouched.
    static func importPaste(_ pasteboard: NSPasteboard, into directory: URL = ScreenCapture.directory) -> [URL] {
        switch decide(pasteboard) {
        case .text: return []
        case .files(let files): return save(files, into: directory)
        case .data:
            guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
            return savePNG(from: source, into: directory).map { [$0] } ?? []
        }
    }

    static func save(_ files: [URL], into directory: URL = ScreenCapture.directory) -> [URL] {
        files.filter(isImageFile).compactMap { file in
            CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { savePNG(from: $0, into: directory) }
        }
    }

    private static func savePNG(from source: CGImageSource, into directory: URL) -> URL? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        // The thumbnail call downscales only when the image is larger than maxSide, but it also
        // never upscales, so it is safe for every size.
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ScreenCapture.prune(in: directory, keep: ScreenCapture.keep - 1)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var file = directory.appendingPathComponent("screen-\(stamp).png")
        var n = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = directory.appendingPathComponent("screen-\(stamp)-\(n).png")
            n += 1
        }
        guard let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? file : nil
    }
}

/// Files attached with the + button or dropped on the chat. Images become PNG copies like a screenshot;
/// any other file is copied under `screenshots/attachments/`, which the agent can already read
/// (that folder is passed with `--add-dir`), so attaching never widens what the agent can see.
enum FileIntake {
    static let directory = ScreenCapture.directory.appendingPathComponent("attachments")
    static let keepFolders = 40

    static func attach(_ urls: [URL], into directory: URL = directory) -> [URL] {
        urls.flatMap { url -> [URL] in
            if ImageIntake.isImageFile(url) { return ImageIntake.save([url]) }
            return copy(url, into: directory).map { [$0] } ?? []
        }
    }

    static func copy(_ file: URL, into directory: URL = directory) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        // One folder per attachment keeps the original file name, which the agent sees in the prompt.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = directory.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(6))")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: target)
            prune(directory)
            return target
        } catch {
            NSLog("ironpet: could not attach \(file.path): \(error)")
            return nil
        }
    }

    /// Folder names start with a timestamp, so sorting by name is oldest first.
    static func prune(_ directory: URL = directory, keep: Int = keepFolders) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for old in folders.sorted(by: { $0.path > $1.path }).dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
