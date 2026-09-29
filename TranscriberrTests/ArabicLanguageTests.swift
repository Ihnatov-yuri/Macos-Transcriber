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
}
