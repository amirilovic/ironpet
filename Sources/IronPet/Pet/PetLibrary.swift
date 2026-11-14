import AppKit

/// One pet in the settings gallery: a valid sprite sheet and the name shown on its tile.
struct PetEntry: Identifiable, @unchecked Sendable {
    /// The sheet's standardized file path.
    let id: String
    let name: String
    let url: URL
    let atlas: Atlas
}

/// Where pets come from: the sheets bundled in the app, and the user's own folder `~/.ironpet/pets`.
enum PetLibrary {
    /// The user's pet library. New sheets dropped here join the gallery.
    static var folder: URL { Paths.root.appendingPathComponent("pets") }
    /// The six sheets `scripts/bundle.sh` generates into the app's Resources.
    static var bundledFolder: URL? { Bundle.main.resourceURL?.appendingPathComponent("pets") }
    /// The order of `tools/make_pet.swift`'s lineup.
    static let builtInNames = ["ghost", "mochi", "hamster", "panda", "bunny", "cat"]
    static let sheetExtensions: Set<String> = ["png", "webp"]

    /// "red-fox" becomes "Red fox".
    static func displayName(forStem stem: String) -> String {
        let words = stem.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
    }

    static func tildePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: Paths.home.path, with: "~", options: .anchored)
    }

    /// Sheet files in a folder, skipping hidden files and anything that is not a PNG or WebP.
    static func sheetFiles(in folder: URL?) -> [URL] {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { sheetExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Every pet to show: the bundled six, then the user's folder, then the current `pet.sprite` when it lives elsewhere.
    /// A sheet in the user's folder replaces a bundled pet of the same name. Files that are not valid atlases are skipped.
    static func entries(bundled: URL?, library: URL, current: String?) -> [PetEntry] {
        var byStem: [String: PetEntry] = [:]
        func add(_ url: URL) {
            let stem = url.deletingPathExtension().lastPathComponent
            guard !stem.isEmpty, let atlas = Atlas.load(url) else { return }
            byStem[stem.lowercased()] = PetEntry(id: standardized(url.path), name: displayName(forStem: stem), url: url, atlas: atlas)
        }
        sheetFiles(in: bundled).forEach(add)
        sheetFiles(in: library).forEach(add)
        let builtIn = builtInNames.compactMap { byStem.removeValue(forKey: $0) }
        var result = builtIn + byStem.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let current, !current.isEmpty, !result.contains(where: { $0.id == standardized(current) }) {
            let url = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
            if let atlas = Atlas.load(url) {
                result.append(PetEntry(id: standardized(current), name: displayName(forStem: url.deletingPathExtension().lastPathComponent),
                                       url: url, atlas: atlas))
            }
        }
        return result
    }

    /// The entry `pet.sprite` points at. Unset means the bundled Ghost.
    static func selectedID(in entries: [PetEntry], sprite: String?) -> String? {
        if let sprite, !sprite.isEmpty { return entries.first { $0.id == standardized(sprite) }?.id }
        return entries.first { $0.url.deletingPathExtension().lastPathComponent.lowercased() == "ghost" }?.id
    }

    /// Makes `entry` the pet. The name follows only while it is still a default name: one of the built-in pets, or the
    /// name of the pet being replaced. A name the user typed stays.
    static func select(_ entry: PetEntry, in config: inout Config) {
        let previous: String
        if let sprite = config.pet.sprite, !sprite.isEmpty {
            previous = displayName(forStem: ((sprite as NSString).lastPathComponent as NSString).deletingPathExtension)
        } else {
            previous = "Ghost"
        }
        let defaults = (builtInNames.map(displayName(forStem:)) + [previous]).map { $0.lowercased() }
        if defaults.contains(config.pet.name.lowercased()) { config.pet.name = entry.name }
        config.pet.sprite = tildePath(entry.url)
    }

    enum ImportError: LocalizedError {
        case notAnAtlas(String)
        var errorDescription: String? {
            switch self {
            case .notAnAtlas(let name): "\(name) isn't a sprite sheet in the expected layout."
            }
        }
    }

    /// Copies a sheet into the library folder under an unused name and returns the copy.
    static func importSheet(_ source: URL, into folder: URL) throws -> URL {
        guard Atlas.load(source) != nil else { throw ImportError.notAnAtlas(source.lastPathComponent) }
        if source.deletingLastPathComponent().resolvingSymlinksInPath() == folder.resolvingSymlinksInPath() { return source }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.lowercased()
        var target = folder.appendingPathComponent("\(stem).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(stem)-\(n).\(ext)")
            n += 1
        }
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }
}

/// Detects changes to the pet folder by comparing file names, sizes and dates. The gallery polls it every couple of
/// seconds while Settings is open, which also catches a sheet an agent rewrites in place.
struct PetFolderSignature: Equatable {
    let items: [String]

    init(folder: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        items = PetLibrary.sheetFiles(in: folder).map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return "\(url.lastPathComponent)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
    }
}

/// What plays on a gallery tile: a few of the pet's own rows, with the pet's own frame durations.
enum PetPreview {
    static let sequence: [(row: AtlasRow, passes: Int)] = [(.idle, 2), (.waving, 1), (.jumping, 1), (.running, 2)]

    /// The row and frame index showing `time` seconds into the loop. With Reduce Motion on, always idle frame 0.
    static func position(in atlas: Atlas, at time: Double, reduceMotion: Bool) -> (row: AtlasRow, frame: Int) {
        guard !reduceMotion else { return (.idle, 0) }
        let segments = sequence.filter { atlas.has($0.row) }
        let lengths = segments.map { Double($0.passes) * $0.row.durations.reduce(0, +) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return (.idle, 0) }
        var t = time.truncatingRemainder(dividingBy: total)
        if t < 0 { t += total }
        for (segment, length) in zip(segments, lengths) {
            guard t >= length else {
                let pass = segment.row.durations.reduce(0, +)
                t = t.truncatingRemainder(dividingBy: pass)
                var index = 0
                while index < segment.row.durations.count - 1, t >= segment.row.durations[index] {
                    t -= segment.row.durations[index]
                    index += 1
                }
                return (segment.row, index)
            }
            t -= length
        }
        return (.idle, 0)
    }

    static func frame(in atlas: Atlas, at time: Double, reduceMotion: Bool) -> CGImage? {
        let (row, index) = position(in: atlas, at: time, reduceMotion: reduceMotion)
        return atlas.frame(row, index)
    }
}

/// The message "Build a new pet" sends to the chat.
enum PetPrompt {
    /// "a red fox with a scarf" becomes "red-fox-with-a-scarf".
    static func kebab(_ description: String) -> String {
        var words = description.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        while words.count > 1, ["a", "an", "the"].contains(words[0]) { words.removeFirst() }
        let joined = words.joined(separator: "-")
        return String(joined.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-")).nonEmpty ?? "new-pet"
    }

    /// The reference generator inside the app bundle, or nil when running outside one.
    static var bundledGenerator: String? { Bundle.main.url(forResource: "make_pet", withExtension: "swift")?.path }

    /// The pet-building skill inside the app bundle, or nil when running outside one.
    static var bundledSkill: String? {
        Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "skills/ironpet-pets")?.path
    }

    /// Whether an agent on this Mac has the ironpet-pets skill, so the request can be the bare slash command.
    static var isSkillInstalled: Bool {
        SkillManager.standard.entries().first { $0.skill.name == "ironpet-pets" }?.status.isInstalledAnywhere ?? false
    }

    /// `skillInstalled`: send `/ironpet-pets <description>`. Otherwise the request names the bundled skill file and the paths.
    static func build(description: String, library: URL = PetLibrary.folder, generatorPath: String? = bundledGenerator,
                      skillPath: String? = bundledSkill, skillInstalled: Bool = false) -> String {
        let sheetExtensions = PetLibrary.sheetExtensions
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = kebab(description)
        // Never ask the agent to overwrite a sheet the user has, or to shadow a bundled pet.
        func taken(_ name: String) -> Bool {
            PetLibrary.builtInNames.contains(name) || sheetExtensions.contains { FileManager.default.fileExists(atPath: library.appendingPathComponent("\(name).\($0)").path) }
        }
        var name = base
        var n = 2
        while taken(name) { name = "\(base)-\(n)"; n += 1 }
        let output = library.appendingPathComponent("\(name).png")
        let shortOutput = PetLibrary.tildePath(output)
        // Installed, the skill runs from its name alone. The skill finds the output folder and the generator itself.
        if skillInstalled { return "/ironpet-pets \(description)" }
        let skill = skillPath.map { "the ironpet-pets skill at \($0)" } ?? "the ironpet-pets skill (skills/ironpet-pets/SKILL.md in the ironpet repository)"
        let generator = generatorPath ?? "tools/make_pet.swift in the ironpet repository"
        return """
        Create a new ironpet character: \(description)

        Read and follow \(skill). Write the sheet to \(shortOutput) (absolute path: \(output.path)). The reference generator is \(generator).
        """
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
