import XCTest
@testable import IronPet

@MainActor
final class ScreenSectionTests: XCTestCase {
    func testSummaryMatchesTheStatusCounts() {
        let model = CaptureStatusModel()
        model.itemCount = 1595
        model.pendingCount = 2
        model.localOnlyCount = 1028
        XCTAssertEqual(ScreenSectionText.summary(items: model.itemCount, pending: model.pendingCount, localOnly: model.localOnlyCount),
                       "1595 items, 2 waiting, 1028 kept on this Mac")
    }

    func testSendLogRowsListNewestFirstFromASeededStore() {
        let store = CaptureStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        store.logSend(harness: "claude", model: "sonnet", items: [1, 2], bytes: 900, outcome: "ok", now: base)
        store.logSend(harness: "cursor", model: "auto", items: [3], bytes: 120, outcome: "failed", now: base.addingTimeInterval(60))
        let rows = ScreenSectionText.rows(store.sendLog())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].title.hasSuffix("cursor / auto"))
        XCTAssertEqual(rows[0].detail, "1 items, 120 bytes, failed")
        XCTAssertTrue(rows[1].title.hasSuffix("claude / sonnet"))
        XCTAssertEqual(rows[1].detail, "2 items, 900 bytes, ok")
    }

    func testScreenSectionComesAfterTranscriptsAndIsAlwaysListed() {
        let shown = IronPetSection.shown(chat: false, transcripts: true, automations: false)
        XCTAssertEqual(shown.firstIndex(of: .screen), shown.firstIndex(of: .transcripts)! + 1)
    }
}
