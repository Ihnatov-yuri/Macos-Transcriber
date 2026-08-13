import XCTest
@testable import Transcriberr

/// The ship gate: every release must pass this suite first. It covers the
/// pure-logic core that every version has touched — text cleanup, echo
/// handling, merging, chunk windowing, and the echo canceller — with the
/// exact regressions we shipped fixes for as permanent test cases.
final class CoreLogicTests: XCTestCase {

    // MARK: - TextDestutter

    func testStutterRunsCollapse() {
        XCTAssertEqual(
            TextDestutter.collapseLine("For for for for person came."),
            "For person came.")
    }

    func testPhraseEchoCollapses() {
        XCTAssertEqual(
            TextDestutter.collapseLine("So the next the next conversation begins."),
            "So the next conversation begins.")
    }

    func testDeliberateRepeatsSurvive() {
        XCTAssertEqual(
            TextDestutter.collapseLine("Thank you. Thank you."),
            "Thank you. Thank you.")
        XCTAssertEqual(
            TextDestutter.collapseLine("Yeah. Yeah. Thanks. Thanks."),
            "Yeah. Yeah. Thanks. Thanks.")
    }

    func testFillerPunctuationCarriesToBoundary() {
        // "Okay, um. Okay" must keep its sentence boundary — v1.6.1 regression.
        XCTAssertEqual(
            TextDestutter.collapseLine("Okay, um. Okay let's go."),
            "Okay. Okay let's go.")
    }

    func testUkrainianCapitalizationPreserved() {
        XCTAssertEqual(
            TextDestutter.collapseLine("Дякую дякую дякую за увагу."),
            "Дякую за увагу.")
    }

    // MARK: - Boundary echo trim (the "schedule" crawl)

    func testBoundaryCrawlTrimmed() {
        let out = TranscriptionRunner.trimBoundaryEcho(
            from: "schedule. No, that's okay.",
            afterTailOf: "Or would you prefer to schedule?")
        XCTAssertEqual(out, "No, that's okay.")
    }

    func testShortGenuineReplyNotEaten() {
        // "Yes." after "Yes?" must survive (single-token trims need 5+ letters).
        let out = TranscriptionRunner.trimBoundaryEcho(
            from: "Yes. I will.",
            afterTailOf: "Yes?")
        XCTAssertEqual(out, "Yes. I will.")
    }

    // MARK: - Sentence echo scrub

    func testEchoSentenceScrubbedFromMixedSegment() {
        let scrubbed = TranscriptionRunner.scrubEchoSentences(
            from: "Hello, how are you today? I saw your face when you got my invite on the first working day.",
            against: "I saw your face when you got my invite on the first working day. Sorry about that.")
        XCTAssertTrue(scrubbed.contains("Hello, how are you today?"))
        XCTAssertFalse(scrubbed.contains("invite"))
    }

    func testShortSentencesNotScrubbed() {
        let scrubbed = TranscriptionRunner.scrubEchoSentences(
            from: "Okay. Sure.", against: "Okay. Sure. Something longer here.")
        XCTAssertEqual(scrubbed, "Okay. Sure.")
    }

    // MARK: - nearDuplicate

    func testNearDuplicateCatchesLoops() {
        XCTAssertTrue(TranscriptionRunner.nearDuplicate(
            "and um describe what she thinks about it",
            "and describe what she thinks about it"))
        XCTAssertFalse(TranscriptionRunner.nearDuplicate(
            "the budget for next quarter",
            "we should hire two engineers"))
    }

    // MARK: - coalesceBySpeaker

    func testCoalesceMergesAdjacentSameSpeaker() {
        let segs = [
            RawSegment(startSeconds: 0, endSeconds: 5, text: "Hello.", speakerKey: "ME", speakerName: "Yuri"),
            RawSegment(startSeconds: 5, endSeconds: 9, text: "How are you?", speakerKey: "ME", speakerName: "Yuri"),
            RawSegment(startSeconds: 9, endSeconds: 14, text: "Fine.", speakerKey: "SPEAKER_01", speakerName: nil),
        ]
        let out = TranscriptionRunner.coalesceBySpeaker(segs)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].text, "Hello. How are you?")
    }

    // MARK: - ROVER merge

    func testRoverPrefersHigherConfidence() {
        let a = [ScoredWord(surface: "a", norm: "a", confidence: 0.9),
                 ScoredWord(surface: "wasp", norm: "wasp", confidence: 0.4)]
        let b = [ScoredWord(surface: "a", norm: "a", confidence: 0.9),
                 ScoredWord(surface: "OWASP", norm: "owasp", confidence: 0.8)]
        XCTAssertEqual(EnsembleBackend.roverMerge(a, b), "a OWASP")
    }

    func testRoverInsertionFloor() {
        let a = [ScoredWord(surface: "hello", norm: "hello", confidence: 0.9)]
        let b = [ScoredWord(surface: "hello", norm: "hello", confidence: 0.9),
                 ScoredWord(surface: "ghost", norm: "ghost", confidence: 0.2)]
        XCTAssertEqual(EnsembleBackend.roverMerge(a, b), "hello")
    }

    func testRoverJoinTrimsLeadingSpaceSurfaces() {
        // Parakeet surfaces used to carry the token's leading space,
        // doubling every separator in the merged text.
        let a = [ScoredWord(surface: " вони", norm: "вони", confidence: 0.9),
                 ScoredWord(surface: " зробили", norm: "зробили", confidence: 0.9)]
        let b = [ScoredWord(surface: "вони", norm: "вони", confidence: 0.5),
                 ScoredWord(surface: "зробили", norm: "зробили", confidence: 0.5)]
        XCTAssertEqual(EnsembleBackend.roverMerge(a, b), "вони зробили")
    }

    func testJoinSurfacesAttachesApostropheFragment() {
        XCTAssertEqual(
            EnsembleBackend.joinSurfaces(["Пам", "'ятаєш", "ми", "просили"]),
            "Пам'ятаєш ми просили")
    }

    func testRoverLanguagePriorProtectsStrongEngine() {
        // Whisper's correct Latin entity must survive Parakeet's
        // higher-raw-confidence Cyrillic misreading when the language prior
        // marks Parakeet weak (Ukrainian).
        let whisper = [ScoredWord(surface: "по", norm: "по", confidence: 0.9),
                       ScoredWord(surface: "NBE", norm: "nbe", confidence: 0.6)]
        let parakeet = [ScoredWord(surface: "по", norm: "по", confidence: 0.9),
                        ScoredWord(surface: "ДНБІ", norm: "днбі", confidence: 0.95)]
        XCTAssertEqual(
            EnsembleBackend.roverMerge(whisper, parakeet, priorA: 1, priorB: 0.5),
            "по NBE")
        // Without the prior the misreading wins — the regression this guards.
        XCTAssertEqual(EnsembleBackend.roverMerge(whisper, parakeet), "по ДНБІ")
    }

    func testVotePriorMapsEnginesAndLanguages() {
        XCTAssertEqual(EnsembleBackend.votePrior(for: .parakeet, languages: ["Ukrainian"]), 0.5)
        XCTAssertEqual(EnsembleBackend.votePrior(for: .whisper, languages: ["Ukrainian"]), 1)
        XCTAssertEqual(EnsembleBackend.votePrior(for: .parakeet, languages: ["English"]), 1)
        XCTAssertEqual(EnsembleBackend.votePrior(for: .parakeetV2, languages: ["Ukrainian"]), 0.5)
        XCTAssertEqual(EnsembleBackend.votePrior(for: .parakeetV2, languages: ["English"]), 1)
        // Multi-language / auto runs carry no prior.
        XCTAssertEqual(EnsembleBackend.votePrior(for: .parakeet, languages: []), 1)
    }

    // MARK: - PostProcessor windowing

    func testWindowsRespectMaxAndSplitOversized() {
        let long = String(repeating: "word ", count: 1200)   // ~6000 chars, no punctuation
        let ws = PostProcessor.windows(long, maxChars: 2600)
        XCTAssertGreaterThan(ws.count, 1)
        XCTAssertTrue(ws.allSatisfy { $0.count <= 2600 })
    }

    // MARK: - NoiseSuppressor

    func testNoiseSuppressorSafeOnSilenceAndFinite() {
        let out = NoiseSuppressor.process(samples: [Float](repeating: 0, count: 1000), sampleRate: 16_000)
        XCTAssertEqual(out.count, 1000)
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
    }

    // MARK: - EchoCanceller (synthetic ground truth)

    func testEchoCancellerRemovesEchoPreservesSpeech() {
        // far side: pseudo-speech noise for 8s; user speaks 8-12s; echo = far
        // at 30%, 60ms delay.
        let sr = 16_000
        var rng: UInt64 = 42
        func rand() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: rng >> 12) % 1000) / 1000.0 * 0.3
        }
        let n = sr * 12
        var sys = [Float](repeating: 0, count: n)
        var mic = [Float](repeating: 0, count: n)
        // Smoothed white noise — persistent excitation, the signal class
        // NLMS provably identifies (periodic signals correlate ambiguously).
        var sSm: Float = 0
        for i in 0..<(sr * 8) { sSm = 0.7 * sSm + 0.3 * rand(); sys[i] = sSm }
        var uSm: Float = 0
        for i in (sr * 8)..<n { uSm = 0.7 * uSm + 0.3 * rand(); mic[i] = uSm }   // user
        let d = 960
        for i in 0..<(n - d) { mic[i + d] += 0.3 * sys[i] }                // echo
        let cleaned = EchoCanceller.cancel(mic: mic, ref: sys)
        func energy(_ x: [Float], _ a: Int, _ b: Int) -> Double {
            var e = 0.0
            for i in (a * sr)..<(b * sr) { e += Double(x[i] * x[i]) }
            return e
        }
        let echoBefore = energy(mic, 1, 8), echoAfter = energy(cleaned, 1, 8)
        let userBefore = energy(mic, 8, 12), userAfter = energy(cleaned, 8, 12)
        XCTAssertLessThan(echoAfter, echoBefore * 0.5, "echo region should lose ≥3 dB")
        XCTAssertGreaterThan(userAfter, userBefore * 0.5, "user speech must survive")
    }

    func testEchoCancellerDoesNoHarmWithoutEcho() {
        let sr = 16_000
        let n = sr * 5
        var mic = [Float](repeating: 0, count: n)
        var sys = [Float](repeating: 0, count: n)
        for i in 0..<n {
            mic[i] = sin(Float(i) * 0.07) * 0.2
            sys[i] = sin(Float(i) * 0.013) * 0.2   // uncorrelated
        }
        let cleaned = EchoCanceller.cancel(mic: mic, ref: sys)
        // guard should return the original when nothing cancels
        XCTAssertEqual(cleaned, mic)
    }
}
