import XCTest
@testable import Transcriberr

final class TranscriptCorrectionTests: XCTestCase {

    func testMultiWordSwapIsFound() {
        let c = TranscriptCorrection.change(from: "Klaar met post en el.", to: "Klaar met PostNL.")
        XCTAssertEqual(c, .init(old: "post en el", new: "PostNL"))
    }

    func testSingleWordSwap() {
        let c = TranscriptCorrection.change(from: "We talked to Kaykoh today", to: "We talked to Kaiko today")
        XCTAssertEqual(c, .init(old: "Kaykoh", new: "Kaiko"))
    }

    func testCaseOnlySwap() {
        let c = TranscriptCorrection.change(from: "send it to postnl now", to: "send it to PostNL now")
        XCTAssertEqual(c, .init(old: "postnl", new: "PostNL"))
    }

    func testPunctuationOnlyEditIsNoSwap() {
        XCTAssertNil(TranscriptCorrection.change(from: "yes we can", to: "Yes, we can."))
    }

    func testNameCapitalMidSentenceIsASwap() {
        let c = TranscriptCorrection.change(from: "we met kaiko today", to: "we met Kaiko today")
        XCTAssertEqual(c, .init(old: "kaiko", new: "Kaiko"))
    }

    func testRewriteIsNoSwap() {
        XCTAssertNil(TranscriptCorrection.change(
            from: "so the plan for next week is the launch of the new site",
            to: "next week we launch the new website, and then the shop and the app follow"))
    }

    func testDeletionIsNoSwap() {
        XCTAssertNil(TranscriptCorrection.change(from: "so um we start", to: "so we start"))
    }

    func testRangesAreWholeWords() {
        let text = "Kaiko and kaiko, but not Kaikos or preKaiko."
        XCTAssertEqual(TranscriptCorrection.ranges(of: "kaiko", in: text).count, 2)
    }

    func testReplacingKeepsSentenceCapital() {
        let out = TranscriptCorrection.replacing("the bliss", with: "the blits", in: "The bliss team met. Ask the bliss team.")
        XCTAssertEqual(out, "The blits team met. Ask the blits team.")
    }

    func testReplacingUsesExactSpellingForNames() {
        let out = TranscriptCorrection.replacing("post en el", with: "PostNL", in: "Post en el belt. Bel post en el.")
        XCTAssertEqual(out, "PostNL belt. Bel PostNL.")
    }

    /// Review of 5.8.0: the punctuation the user typed is part of the word.
    func testTypedPunctuationIsKept() {
        XCTAssertEqual(TranscriptCorrection.change(from: "written in see sharp now", to: "written in C# now"),
                       .init(old: "see sharp", new: "C#"))
        XCTAssertEqual(TranscriptCorrection.change(from: "the us market", to: "the U.S. market"),
                       .init(old: "us", new: "U.S."))
        // The comma the old word stood before is not part of the new one.
        XCTAssertEqual(TranscriptCorrection.change(from: "ask Kaykoh, then", to: "ask Kaiko, then"),
                       .init(old: "Kaykoh", new: "Kaiko"))
    }

    /// Review of 5.8.0: "can" is not inside "can't", "сім" not inside "сім'я".
    func testApostropheIsInsideAWord() {
        XCTAssertEqual(TranscriptCorrection.replacing("can", with: "Ken", in: "I can't, can I"), "I can't, Ken I")
        XCTAssertEqual(TranscriptCorrection.ranges(of: "сім", in: "сім'я, сім’я і сім").count, 1)
        XCTAssertEqual(TranscriptCorrection.ranges(of: "don", in: "'don' said don't").count, 1)
    }

    func testCyrillicWords() {
        let c = TranscriptCorrection.change(from: "ми говорили з кайко вчора", to: "ми говорили з Kaiko вчора")
        XCTAssertEqual(c, .init(old: "кайко", new: "Kaiko"))
        XCTAssertEqual(TranscriptCorrection.replacing("кайко", with: "Kaiko", in: "Кайко і кайкова"), "Kaiko і кайкова")
    }
}
