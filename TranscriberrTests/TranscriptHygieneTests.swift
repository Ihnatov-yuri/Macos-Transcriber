import XCTest
@testable import Transcriberr

/// Guards for the Whisper-anchored Super run: phantom lines on silence,
/// chunk-seam repeats, fragment joins and the word vote's surface choice.
final class TranscriptHygieneTests: XCTestCase {

    // MARK: - Phantoms

    func testPhantomOnlyRecognisesStockLines() {
        XCTAssertTrue(TranscriptHygiene.isPhantomOnly("Дякую."))
        XCTAssertTrue(TranscriptHygiene.isPhantomOnly("Дякую за перегляд!"))
        XCTAssertTrue(TranscriptHygiene.isPhantomOnly("Дякую. Дякую."))
        XCTAssertTrue(TranscriptHygiene.isPhantomOnly("Угу, угу, угу, угу"))
        XCTAssertTrue(TranscriptHygiene.isPhantomOnly("Thank you."))
    }

    func testPhantomOnlyLeavesRealSpeechAlone() {
        XCTAssertFalse(TranscriptHygiene.isPhantomOnly(""))
        XCTAssertFalse(TranscriptHygiene.isPhantomOnly("Дякую, що знайшла час сьогодні."))
        XCTAssertFalse(TranscriptHygiene.isPhantomOnly("Логіку, шукає логіку."))
    }

    func testPhantomResolution() {
        // The logged pairs: Whisper "дякую" vs Parakeet "" / "100".
        XCTAssertEqual(TranscriptHygiene.phantomResolution("Дякую.", ""), "")
        XCTAssertEqual(TranscriptHygiene.phantomResolution("100", "Дякую за перегляд!"), "")
        // Stray residue on the quiet track.
        XCTAssertEqual(TranscriptHygiene.phantomResolution("Дякую.", "Не треба"), "")
        // Whisper gave up on quiet speech the other engine caught.
        XCTAssertEqual(TranscriptHygiene.phantomResolution("Дякую.", "Логіку шукає, логіку"), "Логіку шукає, логіку")
        // Both engines heard it, or the other echoes it → a person said it.
        XCTAssertNil(TranscriptHygiene.phantomResolution("Дякую.", "дякую"))
        XCTAssertNil(TranscriptHygiene.phantomResolution("Дякую.", "дякую тобі дуже"))
        XCTAssertNil(TranscriptHygiene.phantomResolution("", ""))
        // Two engines, two short real words: not a phantom, merge as usual.
        XCTAssertNil(TranscriptHygiene.phantomResolution("Okay.", "Right."))
        XCTAssertNil(TranscriptHygiene.phantomResolution("Угу.", "Так, так"))
        // …but a backchannel loop against total silence still is.
        XCTAssertEqual(TranscriptHygiene.phantomResolution("Угу, угу, угу, угу", "100"), "")
        XCTAssertNil(TranscriptHygiene.phantomResolution("Звичайне речення тут", "Звичайне речення там"))
    }

    func testWhisperRejectReasons() {
        XCTAssertEqual(WhisperBackend.rejectReason(
            text: "Якийсь текст", avgLogprob: -1.3, noSpeechProb: 0.8, chunkSeconds: 26), "no speech")
        XCTAssertEqual(WhisperBackend.rejectReason(
            text: "Дякую.", avgLogprob: -0.3, noSpeechProb: 0.4, chunkSeconds: 26), "phantom line")
        // The same scores on a 2-second dictation are just a short utterance.
        XCTAssertNil(WhisperBackend.rejectReason(
            text: "Дякую.", avgLogprob: -0.7, noSpeechProb: 0.4, chunkSeconds: 2))
        // Mixed-language speech is never dropped for its letters.
        XCTAssertNil(WhisperBackend.rejectReason(
            text: "абвгд ыэъё абвгд абвгд", avgLogprob: -0.6, noSpeechProb: 0.1, chunkSeconds: 26))
        // A confident, clearly voiced "Дякую." is kept.
        XCTAssertNil(WhisperBackend.rejectReason(
            text: "Дякую.", avgLogprob: -0.2, noSpeechProb: 0.05, chunkSeconds: 26))
        XCTAssertNil(WhisperBackend.rejectReason(
            text: "Вони щорічно проводять конференцію", avgLogprob: -0.7, noSpeechProb: 0.3, chunkSeconds: 26))
    }

    func testScriptDriftShare() {
        XCTAssertEqual(TranscriptHygiene.nonUkrainianCyrillicShare("Вони щорічно проводять конференцію для партнерів"), 0)
        XCTAssertGreaterThan(TranscriptHygiene.nonUkrainianCyrillicShare("абвгд ыэъё абвгд абвгд"), 0.04)
    }

    // MARK: - Seams

    func testSeamTrimRemovesRecapWord() {
        XCTAssertEqual(
            TranscriptHygiene.trimSeamRepeat(previous: "і ми ж маємо всіх дивувати.", next: "дивувати. І от затримують"),
            "І от затримують")
        XCTAssertEqual(
            TranscriptHygiene.trimSeamRepeat(previous: "я в них місяць вибивав цю зустріч", next: "зустріч приїхав туди один день"),
            "приїхав туди один день")
        XCTAssertEqual(
            TranscriptHygiene.trimSeamRepeat(previous: "яка займає пост-делівері.", next: "Пост-делівері, а це був один"),
            "а це був один")
    }

    func testSeamTrimKeepsGenuineShortRepeatsAndUnrelatedText() {
        XCTAssertEqual(TranscriptHygiene.trimSeamRepeat(previous: "ну так", next: "так я думаю"), "так я думаю")
        XCTAssertEqual(TranscriptHygiene.trimSeamRepeat(previous: "перше речення", next: "зовсім інше речення"), "зовсім інше речення")
        XCTAssertEqual(TranscriptHygiene.trimSeamRepeat(previous: "дивувати", next: "дивувати"), "дивувати")
    }

    // MARK: - Joins and the vote

    func testJoinSurfacesAttachesHyphenAndClockFragments() {
        XCTAssertEqual(EnsembleBackend.joinSurfaces(["більш", "-менш", "о", "10", ":00"]), "більш-менш о 10:00")
        // A free-standing dash is punctuation.
        XCTAssertEqual(EnsembleBackend.joinSurfaces(["так", "-", "ні"]), "так - ні")
    }

    func testRoverKeepsTrustedEngineSurfaceOnAgreement() {
        // Same words, different casing/punctuation: the higher-prior engine's
        // surface wins even where the other is more confident.
        let whisper = [ScoredWord(surface: "і", norm: "і", confidence: 0.5),
                       ScoredWord(surface: "вони", norm: "вони", confidence: 0.5),
                       ScoredWord(surface: "проводять,", norm: "проводять", confidence: 0.5)]
        let parakeet = [ScoredWord(surface: "І", norm: "і", confidence: 0.99),
                        ScoredWord(surface: "Вони", norm: "вони", confidence: 0.99),
                        ScoredWord(surface: "проводять.", norm: "проводять", confidence: 0.99)]
        XCTAssertEqual(EnsembleBackend.roverMerge(whisper, parakeet, priorA: 1, priorB: 0.5), "і вони проводять,")
    }

    func testRoverVocabularySettlesSubstitution() {
        let a = [ScoredWord(surface: "в", norm: "в", confidence: 0.9),
                 ScoredWord(surface: "Blitz", norm: "blitz", confidence: 0.9)]
        let b = [ScoredWord(surface: "в", norm: "в", confidence: 0.9),
                 ScoredWord(surface: "Blits", norm: "blits", confidence: 0.3)]
        XCTAssertEqual(EnsembleBackend.roverMerge(a, b, priorA: 1, priorB: 0.5, vocabulary: ["blits"]), "в Blits")
    }

    func testRoverDropsWeakEngineLoneInsertions() {
        func w(_ t: String, _ c: Float = 0.9) -> ScoredWord {
            ScoredWord(surface: t, norm: t.lowercased(), confidence: c)
        }
        let whisper = ["воно", "ж", "продається", "як", "практично"].map { w($0) }
        let debris = ["воно", "ж", "продається", "воно", "пода", "як", "практично"].map { w($0) }
        XCTAssertEqual(EnsembleBackend.roverMerge(whisper, debris, priorA: 1, priorB: 0.5),
                       "воно ж продається як практично")
        // A phrase the strong engine skipped (3+ words) is kept.
        let phrase = ["воно", "ж", "продається", "дуже", "добре", "всюди", "як", "практично"].map { w($0) }
        XCTAssertEqual(EnsembleBackend.roverMerge(whisper, phrase, priorA: 1, priorB: 0.5),
                       "воно ж продається дуже добре всюди як практично")
        // Equal priors: single insertions above the floor still survive.
        XCTAssertEqual(EnsembleBackend.roverMerge(whisper, debris), "воно ж продається воно пода як практично")
    }

    func testRoverKeepsTrustedEnginesLatinWords() {
        func w(_ t: String, _ c: Float) -> ScoredWord {
            ScoredWord(surface: t, norm: t.lowercased().filter { $0.isLetter || $0.isNumber }, confidence: c)
        }
        // Whisper unsure of its English, Parakeet very sure of its guess.
        let whisper = [w("щоб", 0.9), w("doesn't", 0.3), w("make", 0.3), w("цікаво", 0.9)]
        let parakeet = [w("що", 0.9), w("Долин", 0.99), w("місяць", 0.99), w("цікаво", 0.9)]
        XCTAssertEqual(EnsembleBackend.roverMerge(whisper, parakeet, priorA: 1, priorB: 0.5),
                       "щоб doesn't make цікаво")
    }

    func testPeakWindowRMSMeasuresTheGivenRange() {
        // 10 s: silent, then a loud burst in the last second.
        var samples = [Float](repeating: 0, count: 10 * 16_000)
        for i in 9 * 16_000..<(10 * 16_000) { samples[i] = 0.5 }
        XCTAssertLessThan(WhisperBackend.peakWindowRMS(samples, from: 0, to: 8) ?? 1, 0.001)
        XCTAssertGreaterThan(WhisperBackend.peakWindowRMS(samples, from: 9, to: 10) ?? 0, 0.4)
        // Whole buffer: the burst dominates — a tail phantom would survive
        // a chunk-wide measurement, which is why the range matters.
        XCTAssertGreaterThan(WhisperBackend.peakWindowRMS(samples) ?? 0, 0.4)
        // A sub-window range is widened around its midpoint, NOT silently
        // replaced by the whole buffer (which would inherit the burst).
        XCTAssertLessThan(WhisperBackend.peakWindowRMS(samples, from: 4.0, to: 4.1) ?? 1, 0.001)
        // Past the end of the audio = Whisper's zero padding, not silence.
        XCTAssertNil(WhisperBackend.peakWindowRMS(samples, from: 11.5, to: 11.6))
        XCTAssertNil(WhisperBackend.peakWindowRMS(samples, from: 29.5, to: 29.6))
        // Unusable range → whole buffer, never a false verdict.
        XCTAssertGreaterThan(WhisperBackend.peakWindowRMS(samples, from: 5, to: 5) ?? 0, 0.4)
    }

    func testSubtitleSignOffIsAlwaysRejected() {
        XCTAssertEqual(WhisperBackend.rejectReason(
            text: "Дякую за перегляд!", avgLogprob: -0.05, noSpeechProb: 0, chunkSeconds: 26), "subtitle sign-off")
        XCTAssertEqual(WhisperBackend.rejectReason(
            text: "Дякую за перегляд! Дякую за перегляд!", avgLogprob: -0.05, noSpeechProb: 0, chunkSeconds: 2),
            "subtitle sign-off")
        XCTAssertNil(WhisperBackend.rejectReason(
            text: "Дякую.", avgLogprob: -0.05, noSpeechProb: 0, chunkSeconds: 26))
        XCTAssertFalse(TranscriptHygiene.isOutroOnly("Дякую за перегляд цього звіту, колеги"))
    }

    func testRoverEqualPriorsStillFollowConfidenceOnAgreedWords() {
        let a = [ScoredWord(surface: "hello", norm: "hello", confidence: 0.4)]
        let b = [ScoredWord(surface: "Hello,", norm: "hello", confidence: 0.9)]
        XCTAssertEqual(EnsembleBackend.roverMerge(a, b), "Hello,")
    }

    func testNonEnglishRunReplacesEnglishOnlyEngine() {
        let uk: Set<String> = ["Ukrainian"]
        var pair = EnsembleBackend.resolvePair(.parakeet, .parakeetV2, languages: uk)
        XCTAssertEqual(pair.0, .whisper); XCTAssertEqual(pair.1, .parakeet)
        pair = EnsembleBackend.resolvePair(.parakeetV2, .whisper, languages: uk)
        XCTAssertEqual(pair.0, .whisper); XCTAssertEqual(pair.1, .parakeet)
        pair = EnsembleBackend.resolvePair(.parakeet, .parakeetV2, languages: ["English"])
        XCTAssertEqual(pair.0, .parakeet); XCTAssertEqual(pair.1, .parakeetV2)
    }

    // MARK: - Vocabulary spellings

    /// A stand-in dictionary: the real one is the system spell checker.
    private func vocab(_ text: String, _ terms: [String] = ["KimKim", "WebRTC", "MasterCard", "Kim",
                                                          "Blits", "Blitsy", "Victor", "Нідерланди"],
                       words: Set<String> = ["Victoria", "Indian", "LinkedIn", "Нідерландах"]) -> String {
        TranscriptHygiene.applyVocabulary(text, terms: terms, isDictionaryWord: { words.contains($0) })
    }

    func testJoinsSplitTerms() {
        XCTAssertEqual(vocab("I worked at Kim Kim for years."), "I worked at KimKim for years.")
        XCTAssertEqual(vocab("we use Web RTC, and master card."), "we use WebRTC, and MasterCard.")
        // Both engines' forms kept side by side by the vote: one copy.
        XCTAssertEqual(vocab("at Kim Kim KimKim what I"), "at KimKim what I")
        // Punctuation between the parts is two words, not a split name.
        XCTAssertEqual(vocab("Kim, Kim, listen"), "Kim, Kim, listen")
    }

    func testRespellsNearMissOfCoinedTerm() {
        XCTAssertEqual(vocab("at KymKym and Kinkim"), "at KimKim and KimKim")
    }

    func testLeavesWordsNamesAndInflectionsAlone() {
        // Differs from a term only in its ending: read as a form of it.
        XCTAssertEqual(vocab("the Blitzy team"), "the Blitzy team")
        // Real words and other people's names.
        XCTAssertEqual(vocab("Victoria and an Indian team on LinkedIn"),
                       "Victoria and an Indian team on LinkedIn")
        // The term's own case ending and possessive.
        XCTAssertEqual(vocab("живу в Нідерландах"), "живу в Нідерландах")
        XCTAssertEqual(vocab("MasterCard's rules"), "MasterCard's rules")
        // Lowercase words are never respelled.
        XCTAssertEqual(vocab("kimkom went"), "kimkom went")
    }

    // MARK: - One-engine duplicates in the vote

    private func w(_ s: String, _ c: Float = 0.9) -> ScoredWord {
        ScoredWord(surface: s, norm: s.lowercased().filter { $0.isLetter || $0.isNumber }, confidence: c)
    }

    func testVoteDropsStuttersAndSplitPieces() {
        // Parakeet keeps the stutter Whisper cleaned up.
        XCTAssertEqual(EnsembleBackend.roverMerge(["I", "was", "sure"].map { w($0) },
                                                  ["I", "was", "I", "was", "sure"].map { w($0) }),
                       "I was sure")
        // One engine's split of the other's word.
        XCTAssertEqual(EnsembleBackend.roverMerge(["cheaper", "LLM"].map { w($0) },
                                                  ["cheaper", "lm", "LLM"].map { w($0) }),
                       "cheaper LLM")
        XCTAssertEqual(EnsembleBackend.roverMerge(["that", "ROI"].map { w($0) },
                                                  ["that", "R", "ROI"].map { w($0) }),
                       "that ROI")
    }

    func testVoteKeepsRealOneEngineWords() {
        XCTAssertEqual(EnsembleBackend.roverMerge(["for", "interrupting"].map { w($0) },
                                                  ["Sorry", "for", "interrupting"].map { w($0) }),
                       "Sorry for interrupting")
        XCTAssertEqual(EnsembleBackend.roverMerge(["one", "side"].map { w($0) },
                                                  ["on", "one", "side"].map { w($0) }),
                       "on one side")
    }

    // MARK: - Echo by timing

    private func timed(_ text: String, from start: Double, step: Double = 0.4) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { k, t in
            TimedWord(word: w(String(t)), start: start + Double(k) * step, end: start + Double(k) * step + step * 0.8)
        }
    }

    func testEchoRunIsDroppedFromMic() {
        let far = timed("how would you measure that ROI for a random project", from: 10)
        // The mic heard the far side again (garbled: "power" for "that"), then
        // the user answered.
        let mic = timed("how would you measure power ROI for a random project", from: 10.05)
            + timed("good question it can become expensive", from: 16)
        let kept = EnsembleBackend.echoFiltered(mic, farSide: far).map(\.word.surface).joined(separator: " ")
        XCTAssertEqual(kept, "good question it can become expensive")
    }

    func testEchoFilterKeepsSimultaneousShortReplies() {
        // Both said "yes okay" at once: two matches is not an echo run.
        let far = timed("yes okay so the next question", from: 5)
        let mic = timed("yes okay", from: 5.1)
        XCTAssertEqual(EnsembleBackend.echoFiltered(mic, farSide: far).count, 2)
        // Same words, said two seconds later, are the user's own.
        let later = timed("how would you measure", from: 13)
        let far2 = timed("how would you measure", from: 10)
        XCTAssertEqual(EnsembleBackend.echoFiltered(later, farSide: far2).count, 4)
    }
}
