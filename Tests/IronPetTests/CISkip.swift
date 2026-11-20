import XCTest

/// Real-window tests (drawn windows, rendered images, scroll views in a live panel) take too long on the CI runner and
/// need a display it does not have, so they run on a developer's Mac and skip on CI.
enum CISkip {
    static func unlessLocal() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "real-window test: runs locally, skipped on CI")
    }
}
