import CoreML
import XCTest
@testable import Transcriberr

/// Whisper's auto-detect called Gulf Arabic "Maltese" and wrote it in Latin
/// letters (2026-09-29); Parakeet v3 has no Arabic and could not outvote it.
final class ArabicLanguageTests: XCTestCase {

    func testMalteseGuessBecomesArabicWhenArabicIsPlausible() {
        XCTAssertEqual(WhisperBackend.resolveAutoLanguage(top: "mt", probs: ["mt": 0.6, "ar": 0.3]), "ar")
        XCTAssertEqual(WhisperBackend.resolveAutoLanguage(top: "ur", probs: ["ur": 0.5, "ar": 0.2]), "ar")
    }

    func testOtherVerdictsAreLeftAlone() {
        XCTAssertEqual(WhisperBackend.resolveAutoLanguage(top: "en", probs: ["en": 0.9, "ar": 0.01]), "en")
        XCTAssertEqual(WhisperBackend.resolveAutoLanguage(top: "mt", probs: ["mt": 0.95, "ar": 0.01]), "mt")
        XCTAssertEqual(WhisperBackend.resolveAutoLanguage(top: "ar", probs: ["ar": 0.9]), "ar")
    }

    func testArabicShare() {
        XCTAssertGreaterThan(EnsembleBackend.arabicShare("مرحبا بكم في المكالمة"), 0.9)
        XCTAssertEqual(EnsembleBackend.arabicShare("Hello there"), 0)
        XCTAssertEqual(EnsembleBackend.arabicShare("123 ..."), 0)
    }

    func testSelectedLanguagesAreTheOnlyCandidates() {
        let allowed = WhisperBackend.candidateCodes(from: ["English", "Arabic"])
        XCTAssertEqual(allowed, ["ar", "en"])
        // Whisper's own top pick (Maltese) is not selectable.
        XCTAssertEqual(WhisperBackend.pickAllowed(allowed, probs: ["mt": 0.7, "ar": 0.2, "en": 0.05]), "ar")
        XCTAssertEqual(WhisperBackend.pickAllowed(allowed, probs: ["en": 0.8, "ar": 0.1]), "en")
        XCTAssertTrue(WhisperBackend.candidateCodes(from: []).isEmpty)
    }

    /// 2026-10-01: an English meeting with English + Arabic selected. Whisper's
    /// top guess was Nynorsk; WhisperKit reported only that one probability,
    /// so English and Arabic both read 0 and Arabic won alphabetically. The
    /// probe's full distribution (measured on that meeting) picks English.
    func testFullDistributionPicksEnglishOverAnUnselectedTopGuess() {
        let probs = WhisperLanguageProbe.DistributionSampler.softmax(
            [("nn", log(0.53)), ("en", log(0.33)), ("ru", log(0.03)), ("ar", log(0.0004))])
        XCTAssertEqual(probs["nn"] ?? 0, 0.53 / 0.8904, accuracy: 1e-6)
        XCTAssertEqual(probs.values.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(WhisperBackend.pickAllowed(["ar", "en"], probs: probs), "en")
    }

    func testSoftmaxReadsLanguageLogitsOnly() throws {
        // Filtered logits: non-language tokens are -inf, as WhisperKit's
        // language filter leaves them.
        let logits = try MLMultiArray(shape: [1, 1, 6], dataType: .float32)
        for i in 0..<6 { logits[i] = NSNumber(value: -Float.infinity) }
        logits[3] = 2.0   // "en"
        logits[5] = 0.0   // "ar"
        let probs = WhisperLanguageProbe.DistributionSampler.softmax(
            logits: logits, over: [3: "en", 5: "ar", 9: "out-of-range"])
        XCTAssertEqual(Set(probs.keys), ["en", "ar"])
        XCTAssertEqual(probs["en"] ?? 0, exp(2) / (exp(2) + 1), accuracy: 1e-6)
    }

    func testOnlyOneWindowOfAudioIsPreDetected() {
        XCTAssertTrue(WhisperBackend.canPreDetect(sampleCount: 26 * 16_000))
        XCTAssertFalse(WhisperBackend.canPreDetect(sampleCount: 30 * 60 * 16_000))
    }
}
