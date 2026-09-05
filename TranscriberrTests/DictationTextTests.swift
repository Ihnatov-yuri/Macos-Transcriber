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
            "First\nSecond\n\nThird")
    }

    func testSentenceStartsCapitalizedAfterSpokenTerminators() {
        // Verbatim from the end-to-end run: the recognizer left "second"
        // lowercase because it didn't know "new paragraph" was a command.
        XCTAssertEqual(
            DictationText.applyCommands("the lazy dog period new paragraph second passage question mark"),
            "the lazy dog.\n\nSecond passage?")
        XCTAssertEqual(
            DictationText.applyCommands("done period next one question mark and more"),
            "done. Next one? And more")
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

// MARK: - Context-aware additions (v3.1)

final class DictationContextTests: XCTestCase {

    func testScratchMidPassageDropsWhatCameBefore() {
        XCTAssertEqual(
            DictationText.applyCommands("Send the report scratch that send the invoice period"),
            "send the invoice.")
        XCTAssertTrue(DictationText.isScratchOnly("Scratch that."))
        XCTAssertTrue(DictationText.isScratchOnly("delete that"))
        XCTAssertFalse(DictationText.isScratchOnly("please scratch that idea"))
    }

    func testDutchGermanUkrainianCommands() {
        XCTAssertEqual(
            DictationText.applyCommands("Hallo allemaal komma tot morgen punt Nieuwe alinea Groeten"),
            "Hallo allemaal, tot morgen.\n\nGroeten")
        XCTAssertEqual(
            DictationText.applyCommands("Guten Tag komma bis morgen fragezeichen"),
            "Guten Tag, bis morgen?")
        XCTAssertEqual(
            DictationText.applyCommands("Привіт кома до завтра крапка новий рядок бувай"),
            "Привіт, до завтра.\nБувай")
        // Nouns stay nouns.
        XCTAssertEqual(DictationText.applyCommands("Dat is een punt van zorg."), "Dat is een punt van zorg.")
    }

    func testSelfCorrections() {
        XCTAssertEqual(
            DictationText.applySelfCorrections("Send it Monday, no, Tuesday."),
            "Send it Tuesday.")
        XCTAssertEqual(
            DictationText.applySelfCorrections("Call John, I mean Jane, tomorrow."),
            "Call Jane, tomorrow.")
        XCTAssertEqual(
            DictationText.applySelfCorrections("Stuur het maandag, nee, dinsdag."),
            "Stuur het dinsdag.")
        // No clause break before the cue → plain conversation, untouched.
        XCTAssertEqual(
            DictationText.applySelfCorrections("There is no way, sorry."),
            "There is no way, sorry.")
        XCTAssertEqual(
            DictationText.applySelfCorrections("No problem, I mean it."),
            "No problem, I mean it.")
    }

    func testAutoSpacingFromContext() {
        XCTAssertEqual(DictationText.forInsertion("hello there.", spacing: .auto, preceding: ""), "Hello there.")
        XCTAssertEqual(DictationText.forInsertion("hello there.", spacing: .auto, preceding: "Dear Kim,\n"), "Hello there.")
        XCTAssertEqual(DictationText.forInsertion("and more.", spacing: .auto, preceding: "Some text"), " and more.")
        XCTAssertEqual(DictationText.forInsertion("and more.", spacing: .auto, preceding: "Some text "), "and more.")
        XCTAssertEqual(DictationText.forInsertion("next one.", spacing: .auto, preceding: "Done."), " Next one.")
        XCTAssertEqual(DictationText.forInsertion(", really", spacing: .auto, preceding: "Yes"), ", really")
        // No context → previous default (trailing space).
        XCTAssertEqual(DictationText.forInsertion("hi.", spacing: .auto, preceding: nil), "hi. ")
    }

    func testAppRuleMatching() {
        let s = DictationSettings()
        let saved = s.appRules
        defer { s.appRules = saved }
        s.appRules = DictationSettings.defaultAppRules
        XCTAssertEqual(s.rule(for: "com.apple.Terminal")?.mode, .verbatim)
        XCTAssertEqual(s.rule(for: "com.jetbrains.intellij")?.mode, .verbatim)
        XCTAssertEqual(s.rule(for: "com.tinyspeck.slackmacgap")?.tone, .casual)
        XCTAssertNil(s.rule(for: "com.example.unknown"))
        XCTAssertNil(s.rule(for: nil))
    }

    func testContextToneAndLanguage() {
        var ctx = DictationContext()
        ctx.bundleId = "com.tinyspeck.slackmacgap"
        XCTAssertEqual(ctx.inferredTone, .casual)
        ctx.bundleId = "com.apple.mail"
        XCTAssertEqual(ctx.inferredTone, .formal)
        ctx.preceding = "Beste Kim, bedankt voor je bericht van gisteren over de nieuwe planning."
        XCTAssertEqual(ctx.contextLanguage, "Dutch")
        ctx.preceding = "ok"
        XCTAssertNil(ctx.contextLanguage)
    }

    func testSmartGuardRejectsDroppedTail() {
        // Verbatim from an end-to-end run: Gemma dropped the second sentence.
        XCTAssertFalse(DictationText.acceptPolished(
            raw: "This is a dictation test, the quick brown fox jumps over the lazy dog.\n\nSecond passage?",
            polished: "This is a dictation test: the quick brown fox jumps over the lazy dog.",
            minOverlap: 0.6))
        XCTAssertTrue(DictationText.acceptPolished(
            raw: "This is a dictation test, the quick brown fox jumps over the lazy dog.\n\nSecond passage?",
            polished: "This is a dictation test: the quick brown fox jumps over the lazy dog.\n\nSecond passage?",
            minOverlap: 0.6))
    }

    func testSmartGuardAllowsSelfCorrectionRewrite() {
        XCTAssertTrue(DictationText.acceptPolished(
            raw: "so we ship it monday no tuesday and tell the whole team about it",
            polished: "So we ship it Tuesday and tell the whole team about it.",
            minOverlap: 0.6))
    }
}

final class DictationBugHuntTests: XCTestCase {
    /// v3.1.2: "scratch that" only counts as a command outside verbatim mode;
    /// the phrase itself must still be recognized as a whole-passage command.
    func testScratchPhrasesInAllLanguages() {
        for phrase in ["scratch that", "Delete that.", "schrap dat", "видали це", "streich das"] {
            XCTAssertTrue(DictationText.isScratchOnly(phrase), phrase)
        }
        XCTAssertFalse(DictationText.isScratchOnly("scratch"))
        XCTAssertFalse(DictationText.isScratchOnly("that"))
    }

    func testSelfCorrectionKeepsSentenceCapital() {
        XCTAssertEqual(
            DictationText.applySelfCorrections("Monday, no, tuesday works."),
            "Tuesday works.")
    }

    func testCommandsNeverProduceDoubleSpacesOrLeadingSpace() {
        let out = DictationText.process("comma hello comma world period", options: .init())
        XCTAssertFalse(out.hasPrefix(" "))
        XCTAssertFalse(out.contains("  "))
        XCTAssertEqual(out, "comma hello, world.")   // raw was lowercase: no capital is invented
    }

    func testVocabularyWindowDoesNotSwallowPunctuation() {
        XCTAssertEqual(
            DictationText.canonicalizeVocabulary("Ask kim kim, then owasp.", terms: ["KimKim", "OWASP"]),
            "Ask KimKim, then OWASP.")
    }
}

final class VocabularyHarvesterTests: XCTestCase {
    func testCandidatesSkipSentenceInitialsButKeepRunsAndAcronyms() {
        XCTAssertEqual(
            VocabularyHarvester.candidates(in: "Yesterday we met KimKim at OWASP. Blits Insurance called. Then nothing."),
            ["KimKim", "OWASP", "Blits Insurance"])
        XCTAssertEqual(VocabularyHarvester.candidates(in: "Okay. Sure thing."), [])
    }

    func testHarvestRequiresRecurrenceAndRejectsOrdinaryWords() {
        let a = UUID(), b = UUID(), c = UUID()
        let items: [(recording: UUID, text: String)] = [
            (a, "We spoke with Kaiko about the Project. The project is late."),
            (b, "Kaiko sent the plan. Another Project meeting tomorrow."),
            (c, "Nothing about the project today. Kaiko again."),
        ]
        let terms = VocabularyHarvester.harvest(items, existingVocabulary: [])
        XCTAssertEqual(terms.map(\.spelling), ["Kaiko"])
        XCTAssertEqual(terms.first?.recordings, 3)
        // Already in the vocabulary → not suggested.
        XCTAssertTrue(VocabularyHarvester.harvest(items, existingVocabulary: ["kaiko"]).isEmpty)
    }

    func testHarvestRejectsContractionsFillersAndRepeats() {
        let a = UUID(), b = UUID()
        let items: [(recording: UUID, text: String)] = [
            (a, "So That's it. Uh I'm done, Kim KimKim said. Ask Дякую again and Дякую."),
            (b, "That's fine. Uh I'm here. Kim KimKim agreed. Дякую all."),
        ]
        XCTAssertTrue(VocabularyHarvester.harvest(items, existingVocabulary: []).isEmpty)
    }

    func testHarvestPrefersMostCommonSpelling() {
        let a = UUID(), b = UUID()
        let items: [(recording: UUID, text: String)] = [
            (a, "Ask Kimkim. Then Kimkim again and KimKim once."),
            (b, "Kimkim replied."),
        ]
        XCTAssertEqual(VocabularyHarvester.harvest(items, existingVocabulary: []).first?.spelling, "Kimkim")
    }
}
