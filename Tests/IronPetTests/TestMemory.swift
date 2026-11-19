import Foundation
@testable import IronPet

/// Points Ghost's memory at one temp folder for the rest of the test run, so no test reads or writes `~/.ironpet/memory`. Every
/// suite that starts a chat turn or an agent session calls it in setUp; `ZMemoryIsolationTests` fails when one is missed.
enum TestMemory {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ironpet-test-memory-\(ProcessInfo.processInfo.processIdentifier)/memory")

    static func isolate() {
        FileMemoryStore.directory = directory
    }
}
