import XCTest
@testable import Transcriberr

/// Backend fixes that need no model: speaker numbering shared by Parakeet
/// and LiteRT Gemma, and the Gemini thinking budget.
final class BackendRaceTests: XCTestCase {

    // MARK: - Speaker numbering

    func testSpeakerNumberReadsTrailingDigits() {
        // FluidAudio's offline diarizer names clusters "S1", "S2"…
        XCTAssertEqual(SpeakerHint.number(fromKey: "S1"), 1)
        XCTAssertEqual(SpeakerHint.number(fromKey: "S12"), 12)
        XCTAssertEqual(SpeakerHint.number(fromKey: "SPEAKER_03"), 3)
    }

    func testSpeakerNumberFallbackIsStable() {
        let n = SpeakerHint.number(fromKey: "GUEST")
        XCTAssertEqual(n, SpeakerHint.number(fromKey: "GUEST"))
        XCTAssertTrue((10..<100).contains(n))
    }

    /// The hints must show the diarizer's own number: the runner parses
    /// "Speaker N" back to SPEAKER_0N, and an off-by-one (or every turn
    /// read as "Speaker 1") breaks the match with the diarizer's clusters.
    func testLiteRTHintsKeepDiarizerNumbers() {
        let msg = GemmaLiteRTBackend.userMessage(
            languages: ["English"], translateTo: nil, diarize: true,
            previousContext: nil,
            speakerHints: [
                SpeakerHint(startSeconds: 0, endSeconds: 2, speakerKey: "S1"),
                SpeakerHint(startSeconds: 2, endSeconds: 4, speakerKey: "S2"),
            ])
        XCTAssertTrue(msg.contains("0.0–2.0s: Speaker 1\n"))
        XCTAssertTrue(msg.contains("2.0–4.0s: Speaker 2\n"))
    }

    // MARK: - Gemini

    func testGeminiThinkingBudget() {
        // 2.5 Pro cannot disable thinking; Flash can.
        XCTAssertEqual(GoogleGeminiBackend.minimalThinkingBudget(for: "gemini-2.5-pro"), 128)
        XCTAssertEqual(GoogleGeminiBackend.minimalThinkingBudget(for: "gemini-2.5-flash"), 0)
    }
}
