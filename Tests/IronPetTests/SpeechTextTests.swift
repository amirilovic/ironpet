import XCTest
@testable import IronPet

final class SpeechTextTests: XCTestCase {
    func testReadsProseAndSkipsCodeAndTables() {
        let reply = """
        # Fixed it

        The **build** was failing because of `Package.swift`.

        ```swift
        let x = 1
        ```

        | File | Change |
        | --- | --- |
        | a.swift | edited |

        ---

        > Run the tests again.
        """
        let spoken = SpeechText.spokenBlocks(of: reply)
        XCTAssertEqual(spoken, ["Fixed it.", "The build was failing because of Package.swift.", "Run the tests again."])
    }

    func testListItemsGetAPause() {
        let spoken = SpeechText.spokenBlocks(of: "- add the test\n- run it!\n1. [x] done")
        XCTAssertEqual(spoken, ["add the test.", "run it!", "done."])
    }

    func testBareURLsAreDroppedButLinkTextIsKept() {
        let spoken = SpeechText.spokenBlocks(of: "See [the PR](https://github.com/a/b/pull/1) or https://example.com/x now.")
        XCTAssertEqual(spoken, ["See the PR or now."])
    }

    func testFirstChunkIsOneSentence() {
        let chunks = SpeechText.chunks(of: "First one. Second one. Third one.")
        XCTAssertEqual(chunks, ["First one.", "Second one. Third one."])
    }

    func testLaterChunksAreGroupedUpToTheChunkLength() {
        let sentence = "Then" + String(repeating: " word", count: 29) + "."
        let chunks = SpeechText.chunks(of: Array(repeating: sentence, count: 4).joined(separator: " "), limit: 10_000)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertTrue(chunks.dropFirst().allSatisfy { $0.count <= SpeechText.chunkCharacters })
    }

    func testStopsAtTheSentenceThatReachesTheLimit() {
        let reply = (1...50).map { "This is sentence number \($0)." }.joined(separator: " ")
        let spoken = SpeechText.chunks(of: reply, limit: 100).joined(separator: " ")
        XCTAssertTrue(spoken.hasSuffix("sentence number 4."), spoken)
        XCTAssertFalse(spoken.contains("number 5."))
    }

    func testARunOnSentenceIsCutAtAWord() {
        let reply = String(repeating: "longword ", count: 200)
        let chunks = SpeechText.chunks(of: reply, limit: 50)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertLessThanOrEqual(chunks[0].count, 51)
        XCTAssertTrue(chunks[0].hasSuffix("longword…"))
    }

    func testCodeOnlyReplyHasNothingToSay() {
        XCTAssertEqual(SpeechText.chunks(of: "```\nls -la\n```"), [])
        XCTAssertEqual(SpeechText.chunks(of: "   "), [])
    }
}
