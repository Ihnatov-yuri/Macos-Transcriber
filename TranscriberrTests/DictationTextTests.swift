import XCTest
@testable import Transcriberr

/// The dictation text stages are deterministic and run on every passage —
/// each rule here guards a way they could mangle what the user said.
final class DictationTextTests: XCTestCase {

    // MARK: - Spoken commands

    func testPeriodAndParagraphCommands() {
        // Parakeet emits the command words with its own punctuation/casing.
        XCTAssertEqual(
            DictationText.applyCommands("Hello world period. New paragraph. Second line."),
            "Hello world.\n\nSecond line.")
    }

    func testCommaAndQuestionMark() {
        XCTAssertEqual(
            DictationText.applyCommands("Well comma, are you coming question mark"),
            "Well, are you coming?")
    }

    func testNewLineVersusNewParagraph() {
        XCTAssertEqual(
            DictationText.applyCommands("First new line second new paragraph third"),
            "First\nsecond\n\nthird")
    }

    func testNounPeriodIsNotACommand() {
        // "the period" / "a period of time" stay words.
        XCTAssertEqual(
            DictationText.applyCommands("During the period we saw growth."),
            "During the period we saw growth.")
        XCTAssertEqual(
            DictationText.applyCommands("It was a period of change."),
            "It was a period of change.")
        // Lowercase continuation after "period." means the noun.
        XCTAssertEqual(
            DictationText.applyCommands("Over that period. we lost."),
            "Over that period. we lost.")
    }

    func testCommandAtEndOfPassage() {
        XCTAssertEqual(DictationText.applyCommands("Send it now period"), "Send it now.")
        XCTAssertEqual(DictationText.applyCommands("Send it now period."), "Send it now.")
    }

    func testQuotes() {
        XCTAssertEqual(
            DictationText.applyCommands("She said open quote never close quote and left."),
            "She said “never” and left.")
    }

    func testLeadingPunctuationCommandIsDropped() {
        XCTAssertEqual(DictationText.applyCommands("Full stop. Hello there."), "Hello there.")
    }

    func testCapitalSurvivesDroppedFiller() {
        XCTAssertEqual(
            DictationText.process("Um so we ship on Monday.", options: .init(destutter: true, commands: true)),
            "So we ship on Monday.")
        // A passage the recognizer left lowercase stays lowercase.
        XCTAssertEqual(
            DictationText.process("and then we ship.", options: .init(destutter: true, commands: true)),
            "and then we ship.")
    }

    func testCommandsDisabledLeavesTextAlone() {
        let raw = "Hello world period new paragraph"
        XCTAssertEqual(DictationText.process(raw, options: .init(destutter: false, commands: false)), raw)
    }

    // MARK: - Vocabulary

    func testVocabularyCanonicalSpelling() {
        let terms = ["KimKim", "OWASP", "Blits Insurance"]
        XCTAssertEqual(
            DictationText.canonicalizeVocabulary("We met kim kim at owasp, then blits insurance.", terms: terms),
            "We met KimKim at OWASP, then Blits Insurance.")
    }

    func testVocabularyNeverFuzzyMatches() {
        XCTAssertEqual(
            DictationText.canonicalizeVocabulary("Kimkin and owas came.", terms: ["KimKim", "OWASP"]),
            "Kimkin and owas came.")
    }

    func testVocabularyKeepsAlreadyCanonicalMultiWord() {
        XCTAssertEqual(
            DictationText.canonicalizeVocabulary("Blits Insurance called.", terms: ["Blits Insurance"]),
            "Blits Insurance called.")
    }

    // MARK: - Full pipeline

    func testProcessRunsAllStages() {
        let out = DictationText.process(
            "Um so the the plan comma send it to kim kim period",
            options: .init(destutter: true, commands: true, vocabulary: ["KimKim"]))
        XCTAssertEqual(out, "So the plan, send it to KimKim.")
    }

    func testTidyCollapsesSpacesAndBlankLines() {
        XCTAssertEqual(DictationText.tidy("a  b .\n\n\n\nc"), "a b.\n\nc")
    }

    // MARK: - Joining and insertion

    func testJoinSpacingRules() {
        XCTAssertEqual(DictationText.join(existing: "", new: "Hi."), "Hi.")
        XCTAssertEqual(DictationText.join(existing: "Hi.", new: "There."), "Hi. There.")
        XCTAssertEqual(DictationText.join(existing: "Hi.\n", new: "There."), "Hi.\nThere.")
        XCTAssertEqual(DictationText.join(existing: "Hi", new: ", there."), "Hi, there.")
        XCTAssertEqual(DictationText.join(existing: "Hi.", new: "   "), "Hi.")
    }

    func testInsertionSpacing() {
        XCTAssertEqual(DictationText.forInsertion("Hi.", spacing: .trailingSpace), "Hi. ")
        XCTAssertEqual(DictationText.forInsertion("Hi.\n", spacing: .trailingSpace), "Hi.\n")
        XCTAssertEqual(DictationText.forInsertion("Hi.", spacing: .leadingSpace), " Hi.")
        XCTAssertEqual(DictationText.forInsertion("Hi.", spacing: .none), "Hi.")
    }

    // MARK: - Polish guard

    func testPolishGuardAcceptsCleanup() {
        let raw = "so um we should ship it on monday and tell the team"
        let polished = "So we should ship it on Monday and tell the team."
        XCTAssertTrue(DictationText.acceptPolished(raw: raw, polished: polished))
    }

    func testPolishGuardAcceptsQuestionPunctuation() {
        XCTAssertTrue(DictationText.acceptPolished(
            raw: "what is the capital of france",
            polished: "What is the capital of France?"))
    }

    func testPolishGuardRejectsAnswersAndMeta() {
        let raw = "what is the capital of france"
        XCTAssertFalse(DictationText.acceptPolished(raw: raw, polished: "The capital of France is Paris."))
        XCTAssertFalse(DictationText.acceptPolished(raw: raw, polished: "Here is the cleaned text: What is the capital of France?"))
        XCTAssertFalse(DictationText.acceptPolished(raw: raw, polished: ""))
        XCTAssertFalse(DictationText.acceptPolished(raw: "a fairly long passage about nothing in particular",
                                                    polished: "Nothing."))
    }

    // MARK: - Titles

    func testTitleFromFirstWords() {
        XCTAssertEqual(DictationText.title(for: "Send the invoice to Kim tomorrow morning, please."),
                       "Send the invoice to Kim tomorrow")
        XCTAssertEqual(DictationText.title(for: "   "), "Dictation")
    }

    // MARK: - Audio helpers

    func testSpeechGate() {
        let silence = [Float](repeating: 0.001, count: 16_000)
        XCTAssertFalse(DictationController.hasSpeech(silence))
        let speech = (0 ..< 16_000).map { Float(sin(Double($0) * 0.05)) * 0.3 }
        XCTAssertTrue(DictationController.hasSpeech(speech))
    }

    func testAutoGainBoostsQuietOnly() {
        let quiet = (0 ..< 1600).map { Float(sin(Double($0) * 0.1)) * 0.05 }
        let boosted = UtteranceCapture.applyGain(quiet, sensitivity: .auto)
        XCTAssertGreaterThan(boosted.map(abs).max()!, 0.5)
        let loud = quiet.map { $0 * 10 }
        XCTAssertEqual(UtteranceCapture.applyGain(loud, sensitivity: .auto), loud)
        let fixed = UtteranceCapture.applyGain(loud, sensitivity: .x4)
        XCTAssertLessThanOrEqual(fixed.map(abs).max()!, 1.0)
    }
}
