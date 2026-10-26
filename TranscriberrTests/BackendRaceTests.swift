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

/// LiteRT's own idle release: it waits for the transcription queue, and
/// hands the engine back once the queue lets it.
final class LiteRTIdleReleaseTests: XCTestCase {
    @MainActor
    func testIdleReleaseWaitsForTheQueue() async {
        let factory = BackendFactory(gemma: GemmaSettingsStore(), prompts: PromptStore(), apiKeys: APIKeyStore())
        let first = factory.backend(for: .gemmaLiteRT) as AnyObject
        var queueBusy = true
        factory.liteRTReleaseAllowed = { !queueBusy }

        await factory.releaseLiteRTIfQuiet()
        XCTAssertTrue(factory.backend(for: .gemmaLiteRT) as AnyObject === first, "kept while a job runs")

        queueBusy = false
        await factory.releaseLiteRTIfQuiet()
        XCTAssertFalse(factory.backend(for: .gemmaLiteRT) as AnyObject === first, "released once the queue is idle")
    }
}

/// The CPU engine's window is small (its buffers scale with it): the token
/// estimate that decides what may run there must never undercount.
final class LiteRTWindowTests: XCTestCase {
    func testEstimateOvercountsLatinAndCyrillic() {
        let english = String(repeating: "the meeting went well ", count: 100)   // ~500 tokens
        let ukrainian = String(repeating: "зустріч пройшла добре ", count: 100)   // ~600 tokens
        XCTAssertGreaterThanOrEqual(GemmaLiteRTBackend.estimatedTokens(english), english.count / 4)
        XCTAssertGreaterThanOrEqual(GemmaLiteRTBackend.estimatedTokens(ukrainian), ukrainian.count / 2)
    }

    func testAudioChunkFitsTheCPUWindow() {
        XCTAssertLessThan(GemmaLiteRTBackend.chunkTokens, GemmaLiteRTBackend.cpuWindow)
        XCTAssertLessThan(GemmaLiteRTBackend.cpuWindow, GemmaLiteRTBackend.gpuWindow)
    }
}
