import AppKit
import XCTest
@testable import IronPet

/// Runs after the other suites (XCTest orders classes by name) and fails when any of them wrote to the real `~/.ironpet/memory`.
/// A suite that starts a chat turn or an agent session must call `TestMemory.isolate()` in its setUp.
final class ZMemoryIsolationTests: XCTestCase {
    private static var processStart: Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return .distantPast }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    func testNoTestWroteToTheRealMemoryFolder() throws {
        let real = Paths.root.appendingPathComponent("memory")
        let start = Self.processStart
        // The installed app may learn something while the tests run. Its notes never name a temp folder, which a test's always do.
        let appRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "dev.ironpet.app").isEmpty
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let markers = [temp, temp.replacingOccurrences(of: "/private/var/", with: "/var/")]
        var written: [String] = []
        let enumerator = FileManager.default.enumerator(at: real, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate, modified >= start else { continue }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if !appRunning || markers.contains(where: text.contains) { written.append(url.path) }
        }
        XCTAssertEqual(written, [], "tests wrote to the real memory folder")
    }
}
