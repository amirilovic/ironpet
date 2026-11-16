import Foundation
@testable import IronPet

/// lookback's recorded accessibility fixtures, its goldens, and the output lookback's own engine gave for each (`expected/`).
enum CaptureFixtures {
    static let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/capture")

    /// Fixture names that have a snapshot (`<name>.json`, no `-golden`), sorted.
    static var names: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") && !$0.hasSuffix("-golden.json") }.map { String($0.dropLast(5)) }.sorted()
    }

    static func data(_ relative: String) -> Data? { try? Data(contentsOf: directory.appendingPathComponent(relative)) }

    static func snapshot(_ name: String) -> CaptureSnapshot? {
        data("\(name).json").flatMap { try? JSONDecoder().decode(CaptureSnapshot.self, from: $0) }
    }

    /// The JSON value lookback produced for a fixture: an item, `{"refuse": ...}`, or null.
    static func expected(_ name: String) -> Any? {
        data("expected/\(name).json").flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
    }

    static func goldenContent(_ name: String) -> CaptureContent? {
        guard let data = data("\(name)-golden.json"),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let content = object["content"],
              let contentData = try? JSONSerialization.data(withJSONObject: content) else { return nil }
        return try? JSONDecoder().decode(CaptureContent.self, from: contentData)
    }

    static func canonical(_ item: CaptureItem) -> Any? {
        CaptureJSON.string(item).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
    }
}
