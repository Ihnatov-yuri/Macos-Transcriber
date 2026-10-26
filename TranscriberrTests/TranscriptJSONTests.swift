import FluidAudio
import XCTest
@testable import Transcriberr

final class TranscriptJSONTests: XCTestCase {
    private func tok(_ token: String, _ start: Double, _ end: Double, _ conf: Float = 0.9) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: conf)
    }

    func testGroupsSubwordPiecesIntoTimedWords() throws {
        // "▁Goede" "morgen" "!" "▁Sanne" — two words, the second piece joins the first
        let timings = [tok("▁Goede", 0.08, 0.40), tok("morgen", 0.40, 0.72, 0.6), tok("!", 0.72, 0.80),
                       tok("▁Sanne", 1.04, 1.52)]
        let t = TranscriptJSON(text: "Goedemorgen! Sanne", confidence: 0.87, durationS: 1.6,
                               language: "nl", timings: timings)
        XCTAssertEqual(t.words, [
            .init(word: "Goedemorgen!", start: 0.08, end: 0.8, confidence: 0.6),
            .init(word: "Sanne", start: 1.04, end: 1.52, confidence: 0.9),
        ])
    }

    func testLeadingSpaceMarkerAlsoStartsAWord() {
        let t = TranscriptJSON(text: "ik zoek", confidence: 1, durationS: 1, language: nil,
                               timings: [tok(" ik", 0, 0.2), tok(" zo", 0.3, 0.5), tok("ek", 0.5, 0.7)])
        XCTAssertEqual(t.words.map(\.word), ["ik", "zoek"])
        XCTAssertEqual(t.words.last?.start, 0.3)
        XCTAssertEqual(t.words.last?.end, 0.7)
    }

    func testEncodesStableSnakeCaseJSONWithMillisecondTimes() throws {
        let t = TranscriptJSON(text: "fiets", confidence: 0.912_345, durationS: 0.987_654, language: "nl",
                               timings: [tok("▁fiets", 0.123_456, 0.654_321)])
        XCTAssertEqual(try t.encoded(), """
        {"confidence":0.912,"duration_s":0.988,"language":"nl","text":"fiets",\
        "words":[{"confidence":0.9,"end":0.654,"start":0.123,"word":"fiets"}]}
        """)
    }

    func testNoTimingsGivesNoWords() throws {
        let t = TranscriptJSON(text: "", confidence: 0, durationS: 0, language: nil, timings: [])
        XCTAssertTrue(t.words.isEmpty)
        XCTAssertTrue(try t.encoded().contains("\"words\":[]"))
    }
}
