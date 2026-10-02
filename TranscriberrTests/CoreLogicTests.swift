import XCTest
import AppKit
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

    func testCommaSeparatedAnswersSurvive() {
        // A yes/no said twice with a comma is an answer, not a stutter —
        // the same pair the seam trim keeps.
        XCTAssertEqual(TextDestutter.collapseLine("Так, так, я пам'ятаю."), "Так, так, я пам'ятаю.")
        XCTAssertEqual(TextDestutter.collapseLine("Ні, ні, не треба."), "Ні, ні, не треба.")
        XCTAssertEqual(TextDestutter.collapseLine("Nee, nee, dat klopt niet."), "Nee, nee, dat klopt niet.")
        // Without the comma, or three times over, it still collapses.
        XCTAssertEqual(TextDestutter.collapseLine("І так так далі."), "І так далі.")
        XCTAssertEqual(TextDestutter.collapseLine("Так, так, так, так."), "Так, так.")
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

    /// The guard is for context-echo LINES. With diarization off, a chunk is
    /// ONE segment covering 28 seconds, and two chunks of a repetitive
    /// stretch overlap easily enough to cross the threshold — which used to
    /// delete half a minute of real transcript on a log warning.
    func testNearDuplicateLeavesWholeChunksAlone() {
        let words = (1...40).map { "item\($0)" }.joined(separator: " ")
        XCTAssertFalse(
            TranscriptionRunner.nearDuplicate(words, words),
            "a whole-chunk-sized segment must never be dropped as a near-duplicate")
    }

    // MARK: - Hotkey modifier sides

    /// Left/right twins share a device-independent flag, so the twin used to
    /// mask the hotkey's release and hold mode ran to its watchdog.
    func testModifierIsDownSeparatesLeftAndRightTwins() {
        let leftCommandKey: UInt16 = 55
        let rightCommandKey: UInt16 = 54
        let leftBit: UInt64 = 0x08
        let rightBit: UInt64 = 0x10
        let shared = UInt64(NSEvent.ModifierFlags.command.rawValue)

        // Right ⌘ released while left ⌘ is still held: shared flag still set.
        let onlyLeft = shared | leftBit
        XCTAssertFalse(HotkeyMonitor.modifierIsDown(rawFlags: onlyLeft, keyCode: rightCommandKey))
        XCTAssertTrue(HotkeyMonitor.modifierIsDown(rawFlags: onlyLeft, keyCode: leftCommandKey))

        let both = shared | leftBit | rightBit
        XCTAssertTrue(HotkeyMonitor.modifierIsDown(rawFlags: both, keyCode: rightCommandKey))

        // A keyboard that reports no side bits at all still works.
        XCTAssertTrue(HotkeyMonitor.modifierIsDown(rawFlags: shared, keyCode: rightCommandKey))
        XCTAssertFalse(HotkeyMonitor.modifierIsDown(rawFlags: 0, keyCode: rightCommandKey))
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

    func testCoalesceKeepsUnlabeledChunksApart() {
        // Diarization failed: no speaker keys at all must not fold the
        // whole recording into one segment.
        let segs = [
            RawSegment(startSeconds: 0, endSeconds: 28, text: "One.", speakerKey: nil, speakerName: nil),
            RawSegment(startSeconds: 28, endSeconds: 56, text: "Two.", speakerKey: nil, speakerName: nil),
        ]
        XCTAssertEqual(TranscriptionRunner.coalesceBySpeaker(segs).count, 2)
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
            // Zero-mean: a 0.15 DC offset outweighed the noise ~17:1 in
            // power, and the filter cancelled a constant at ANY lag — the
            // test passed with the delay estimate forced wrong.
            return Float(Int64(bitPattern: rng >> 12) % 1000) / 1000.0 * 0.3 - 0.15
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

    /// Regression: a call whose first minute is silence — nobody has joined
    /// yet — used to poison the bulk-delay search, which only ever looked at
    /// the first 60 s. The junk lag parked the 64 ms tap window far from the
    /// real echo, ERLE went negative, the do-no-harm guard returned the raw
    /// mic, and the far side reached the ASR labelled as the user.
    func testEchoCancellerSurvivesSilentLeadIn() {
        let sr = 16_000
        var rng: UInt64 = 99
        func rand() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            // Zero-mean (see testEchoCancellerHandlesLargeDelay): with a DC
            // offset the test passed even with the delay estimate wrong.
            return Float(Int64(bitPattern: rng >> 12) % 1000) / 1000.0 * 0.3 - 0.15
        }
        let lead = sr * 70          // 70 s of nothing, longer than the search span
        let n = lead + sr * 30
        var sys = [Float](repeating: 0, count: n)
        var mic = [Float](repeating: 0, count: n)
        var sm: Float = 0
        for i in lead..<n { sm = 0.7 * sm + 0.3 * rand(); sys[i] = sm }
        let d = 400                 // 25 ms — the measured speaker→mic path
        for i in 0..<(n - d) { mic[i + d] = 0.35 * sys[i] }
        let cleaned = EchoCanceller.cancel(mic: mic, ref: sys)
        let before = mic.reduce(0.0) { $0 + Double($1 * $1) }
        let after = cleaned.reduce(0.0) { $0 + Double($1 * $1) }
        XCTAssertLessThan(after, before * 0.25, "echo after a silent lead-in should still lose ≥6 dB")
    }

    /// The correlation peak on speech is broad and lands late; the taps only
    /// reach forward from the estimate, so a short true delay must still fall
    /// inside the window.
    func testEchoCancellerHandlesShortDelay() {
        let sr = 16_000
        var rng: UInt64 = 11
        func rand() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            // Zero-mean (see testEchoCancellerHandlesLargeDelay): with a DC
            // offset the test passed even with the delay estimate wrong.
            return Float(Int64(bitPattern: rng >> 12) % 1000) / 1000.0 * 0.3 - 0.15
        }
        let n = sr * 10
        var sys = [Float](repeating: 0, count: n)
        var mic = [Float](repeating: 0, count: n)
        var sm: Float = 0
        for i in 0..<n { sm = 0.7 * sm + 0.3 * rand(); sys[i] = sm }
        let d = 64                  // 4 ms — headphones bleed / near field
        for i in 0..<(n - d) { mic[i + d] = 0.35 * sys[i] }
        let cleaned = EchoCanceller.cancel(mic: mic, ref: sys)
        let before = mic.reduce(0.0) { $0 + Double($1 * $1) }
        let after = cleaned.reduce(0.0) { $0 + Double($1 * $1) }
        XCTAssertLessThan(after, before * 0.25, "a 4 ms echo path should lose ≥6 dB")
    }

    /// The suppressor after the filter must silence echo-only stretches
    /// without eating the user when both talk at once — attenuation alone was
    /// not enough for ASR (Parakeet still transcribed the far side's whole
    /// half of a real call from a track 21 dB down, just garbled).
    ///
    /// NOTE the local zero-mean noise rather than the `rand()` helper the
    /// tests above use: that one returns [0, 0.3), so its "user" and "far
    /// side" share a large DC component and are strongly correlated — the
    /// filter can then genuinely predict the near end from the reference and
    /// cancels it, which no real pair of microphone and system-audio tracks
    /// ever does.
    func testEchoCancellerSilencesEchoAndSurvivesDoubletalk() {
        let sr = 16_000
        var rng: UInt64 = 5
        func noise() -> Float {          // zero-mean, ±0.15
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: rng >> 12) % 1000) / 1000.0 * 0.3 - 0.15
        }
        let n = sr * 20
        var sys = [Float](repeating: 0, count: n)
        var mic = [Float](repeating: 0, count: n)
        var sSm: Float = 0
        for i in 0..<n { sSm = 0.7 * sSm + 0.3 * noise(); sys[i] = sSm }   // far side throughout
        let d = 400
        for i in 0..<(n - d) { mic[i + d] = 0.5 * sys[i] }                 // echo throughout
        var uSm: Float = 0
        for i in (sr * 15)..<n { uSm = 0.7 * uSm + 0.3 * noise(); mic[i] += uSm }  // user talks over it
        let cleaned = EchoCanceller.cancel(mic: mic, ref: sys)
        func energy(_ x: [Float], _ a: Int, _ b: Int) -> Double {
            var e = 0.0
            for i in (a * sr)..<(b * sr) { e += Double(x[i] * x[i]) }
            return e
        }
        // Echo-only stretch, sampled after the filter has converged.
        let echoBefore = energy(mic, 10, 15), echoAfter = energy(cleaned, 10, 15)
        XCTAssertLessThan(echoAfter, echoBefore * 0.01, "echo-only should be gated to near silence")
        let bothBefore = energy(mic, 15, 20), bothAfter = energy(cleaned, 15, 20)
        XCTAssertGreaterThan(bothAfter, bothBefore * 0.1, "the user talking over the far side must survive")
    }

    /// The delay search tries several loud minutes, not just the loudest:
    /// they must be distinct (non-overlapping) and loudest first.
    func testLoudestWindowStartsAreDistinctAndOrdered() {
        let sr = 16_000
        var ref = [Float](repeating: 0.001, count: sr * 300)
        for i in (sr * 200)..<(sr * 260) { ref[i] = 0.5 }   // loudest minute
        for i in (sr * 20)..<(sr * 80) { ref[i] = 0.3 }     // second
        let starts = EchoCanceller.loudestWindowStarts(ref: ref, count: ref.count, span: sr * 60, k: 4)
        XCTAssertEqual(starts.first, sr * 200)
        XCTAssertTrue(starts.contains(sr * 20))
        for (i, a) in starts.enumerated() {
            for b in starts[(i + 1)...] { XCTAssertGreaterThanOrEqual(abs(a - b), sr * 60) }
        }
    }

    // MARK: - EchoGate (playback mix when the echo path is not cancellable)

    /// Bursty zero-mean noise: on for 0.4 s, off for 0.2 s — speech-like
    /// enough for 20 ms frame levels, with gaps for the tail to show.
    private func bursts(seconds: Int, seed: UInt64, amp: Float) -> [Float] {
        var rng = seed
        let sr = 16_000
        return (0..<(sr * seconds)).map { i in
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let on = (i % (sr * 6 / 10)) < sr * 4 / 10
            return on ? (Float(Int64(bitPattern: rng >> 12) % 1000) / 1000.0 - 0.5) * 2 * amp : 0
        }
    }

    /// Measured case: a Bluetooth speaker 124 ms away whose echo the linear
    /// filter could not follow. The gate must mute the echo-only stretches,
    /// leave the user alone untouched, and let the user through when they
    /// talk over the far side louder than its echo.
    func testEchoGateMutesEchoKeepsUser() {
        let sr = 16_000
        let n = sr * 40
        var ref = [Float](repeating: 0, count: n)
        let far = bursts(seconds: 20, seed: 3, amp: 0.3)
        for i in 0..<(sr * 20) { ref[i] = far[i] }                     // far side talks 0-20 s
        for i in (sr * 30)..<n { ref[i] = far[i - sr * 30] }           // and 30-40 s
        let d = 1984
        var mic = [Float](repeating: 0, count: n)
        // Echo with a level that wanders ±40% — what defeats a linear filter
        // and must not defeat the gate.
        for i in 0..<(n - d) {
            let wobble: Float = 1 + 0.4 * sin(Float(i) / Float(sr) * 1.3)
            mic[i + d] = 0.1 * wobble * ref[i]
        }
        let user = bursts(seconds: 10, seed: 8, amp: 0.25)
        for i in 0..<(sr * 8) { mic[sr * 21 + i] += user[i] }          // alone, 21-29 s
        for i in 0..<(sr * 5) { mic[sr * 34 + i] += user[i] }          // over the far side, 34-39 s

        // Gains decided on the real mixture, applied to each part on its own.
        let g = EchoGate.frameGains(mic: mic, ref: ref, delay: d)
        XCTAssertEqual(g.count, n / EchoGate.frame)
        var gatedMic = mic
        EchoGate.applyGains(g, to: &gatedMic)
        var userAlone = [Float](repeating: 0, count: n)
        for i in 0..<(sr * 8) { userAlone[sr * 21 + i] = user[i] }
        var userOverFar = [Float](repeating: 0, count: n)
        for i in 0..<(sr * 5) { userOverFar[sr * 34 + i] = user[i] }
        let aloneBefore = userAlone, overBefore = userOverFar
        EchoGate.applyGains(g, to: &userAlone)
        EchoGate.applyGains(g, to: &userOverFar)
        func energy(_ x: [Float], _ a: Int, _ b: Int) -> Double {
            var e = 0.0
            for i in a..<b { e += Double(x[i] * x[i]) }
            return e
        }
        XCTAssertLessThan(energy(gatedMic, sr * 2, sr * 20), energy(mic, sr * 2, sr * 20) * 0.01,
                          "echo-only stretches should lose ≥20 dB")
        XCTAssertGreaterThan(energy(userAlone, 0, n), energy(aloneBefore, 0, n) * 0.95, "the user alone must pass")
        XCTAssertGreaterThan(energy(userOverFar, 0, n), energy(overBefore, 0, n) * 0.8,
                             "the user talking over the far side must pass")
    }

    /// Quiet mic frames (soft speech, room tone) pass untouched while the
    /// far side is silent — there is no echo there to remove.
    func testEchoGateIsTransparentWithoutFarSide() {
        let loud = bursts(seconds: 5, seed: 4, amp: 0.2)
        let quiet = bursts(seconds: 5, seed: 6, amp: 0.002)
        for mic in [loud, quiet] {
            let ref = [Float](repeating: 0, count: mic.count)
            var out = mic
            EchoGate.apply(&out, ref: ref, delay: 1000)
            XCTAssertEqual(out, mic)
        }
    }

    /// Gain ramps between frame centres: continuous, no 20 ms steps, and
    /// samples past the last whole frame take its gain.
    func testEchoGateGainsRampBetweenFrames() {
        var x = [Float](repeating: 1, count: EchoGate.frame * 3 + 100)
        EchoGate.applyGains([0, 1, 1], to: &x)
        let half = EchoGate.frame / 2
        XCTAssertEqual(x[0], 0)
        XCTAssertEqual(x[half + EchoGate.frame / 2], 0.5, accuracy: 0.01)
        XCTAssertEqual(x[x.count - 1], 1)
        for i in 1..<x.count { XCTAssertLessThan(abs(x[i] - x[i - 1]), 0.01) }
    }

    /// When the canceller gives up, the playback mix must use the gated mic,
    /// not the raw one — the wiring this release exists for.
    func testPlaybackMixGatesMicOnlyWhenEchoKept() {
        let sr = 16_000
        let sys = bursts(seconds: 10, seed: 3, amp: 0.3)
        let d = 1984
        var mic = [Float](repeating: 0, count: sys.count)
        for i in 0..<(sys.count - d) { mic[i + d] = 0.1 * sys[i] }
        func echoEnergy(_ mix: [Float]) -> Double {
            var e = 0.0
            for i in (sr * 2)..<mix.count { let v = mix[i] - sys[i]; e += Double(v * v) }
            return e
        }
        let kept = MeetingMixRebuilder.playbackMix(cleanedMic: mic, outcome: .echoKept, echoDelay: d, sys: sys)
        let cancelled = MeetingMixRebuilder.playbackMix(cleanedMic: mic, outcome: .cancelled, echoDelay: d, sys: sys)
        XCTAssertLessThan(echoEnergy(kept), echoEnergy(cancelled) * 0.01)
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
