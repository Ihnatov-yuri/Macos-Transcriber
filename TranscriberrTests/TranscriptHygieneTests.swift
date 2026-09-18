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
        XCTAssertNil(TranscriptHygiene.phantomResolution("Звичайне речення тут", "Звичайне речення там"))
    }

    func testWhisperRejectReasons() {
        XCTAssertEqual(WhisperBackend.rejectReason(
            text: "Якийсь текст", avgLogprob: -1.3, noSpeechProb: 0.8, ukrainian: true), "no speech")
        XCTAssertEqual(WhisperBackend.rejectReason(
            text: "Дякую за перегляд!", avgLogprob: -0.3, noSpeechProb: 0.4, ukrainian: true), "phantom line")
        // A confident, clearly voiced "Дякую." is kept.
        XCTAssertNil(WhisperBackend.rejectReason(
            text: "Дякую.", avgLogprob: -0.2, noSpeechProb: 0.05, ukrainian: true))
        XCTAssertNil(WhisperBackend.rejectReason(
            text: "Вони щорічно проводять конференцію", avgLogprob: -0.7, noSpeechProb: 0.3, ukrainian: true))
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

    func testNonEnglishRunReplacesEnglishOnlyEngine() {
        let uk: Set<String> = ["Ukrainian"]
        var pair = EnsembleBackend.resolvePair(.parakeet, .parakeetV2, languages: uk)
        XCTAssertEqual(pair.0, .whisper); XCTAssertEqual(pair.1, .parakeet)
        pair = EnsembleBackend.resolvePair(.parakeetV2, .whisper, languages: uk)
        XCTAssertEqual(pair.0, .whisper); XCTAssertEqual(pair.1, .parakeet)
        pair = EnsembleBackend.resolvePair(.parakeet, .parakeetV2, languages: ["English"])
        XCTAssertEqual(pair.0, .parakeet); XCTAssertEqual(pair.1, .parakeetV2)
    }
}
