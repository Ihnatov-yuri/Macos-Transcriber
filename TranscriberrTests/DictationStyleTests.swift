import XCTest
@testable import Transcriberr

/// "Write as" rewrites a whole dictation with the text model. The guard
/// decides whether the model's reply may replace what the user said; the
/// tidy-up strips what models wrap around a reply. The rewrites below are
/// real Gemma 4 26B output from `transcriberrcli dictstyle all`.
@MainActor
final class DictationStyleTests: XCTestCase {

    private let draft = "so um hey Mark I wanted to let you know that the the report for Kaiko is going to be late uh we need another two days because the data from the client came in on Monday no Tuesday and it was incomplete so can you tell the team and also we should probably move the review meeting to Friday at 3 and I'll send the draft on Thursday evening thanks"

    private let ukDraft = "ну привіт Оксано слухай я хотів сказати що ми не встигаємо з презентацією для Blits бо дизайнер захворів тому давай перенесемо зустріч на середу а я тобі скину чернетку завтра ввечері і ще треба замовити переговорну на десять людей"

    // MARK: - Guard: real rewrites pass

    func testRealLetterIsAccepted() {
        let letter = """
        Dear Mark,

        I am writing to inform you that the report for Kaiko will be delayed. We require an additional two days to complete it, as the data received from the client on Tuesday was incomplete.

        Could you please inform the team regarding this delay? Additionally, I suggest that we reschedule the review meeting to Friday at 3:00 PM. I will send the draft to you on Thursday evening.

        Kind regards,
        """
        XCTAssertTrue(DictationStyle.accept(draft: draft, rewrite: letter))
    }

    func testRealBulletsAreAcceptedThoughMuchShorter() {
        let bullets = """
        - Kaiko report will be late
        - Need another two days
        - Client data arrived on Tuesday and was incomplete
        - Tell the team
        - Move review meeting to Friday at 3
        - Send draft on Thursday evening
        """
        XCTAssertTrue(DictationStyle.accept(draft: draft, rewrite: bullets))
    }

    func testRealUkrainianMessageIsAccepted() {
        let message = """
        Привіт, Оксано!

        Хочу повідомити, що ми не встигаємо підготувати презентацію для Blits, оскільки дизайнер захворів. Пропоную перенести нашу зустріч на середу. Я надішлю тобі чернетку завтра ввечері.

        Також потрібно замовити переговорну на десять осіб.
        """
        XCTAssertTrue(DictationStyle.accept(draft: ukDraft, rewrite: message))
    }

    func testShortDraftMayGrowIntoALetter() {
        // A one-line draft gains a greeting and a closing: well past 3×.
        let short = "tell Anna the invoice is paid"
        let letter = "Dear Anna,\n\nI would like to inform you that the invoice has been paid.\n\nKind regards,"
        XCTAssertTrue(DictationStyle.accept(draft: short, rewrite: letter))
    }

    // MARK: - Guard: what must never replace the user's words

    func testEmptyReplyIsRejected() {
        XCTAssertFalse(DictationStyle.accept(draft: draft, rewrite: "   \n"))
    }

    func testRefusalIsRejected() {
        XCTAssertFalse(DictationStyle.accept(
            draft: draft, rewrite: "I'm sorry, but I can't help with rewriting this message for Mark about Kaiko."))
    }

    func testTranslationIsRejected() {
        // The Ukrainian draft came back in English: the user's words are gone.
        let english = """
        Hi Oksana,

        I wanted to let you know that we won't make the presentation for Blits because the designer is ill. Let's move the meeting to Wednesday; I'll send you a draft tomorrow evening. We also need to book a meeting room for ten people.
        """
        XCTAssertFalse(DictationStyle.accept(draft: ukDraft, rewrite: english))
    }

    func testReplyAboutSomethingElseIsRejected() {
        let other = "Dear team,\n\nPlease find attached the quarterly figures. Revenue increased across all regions and the forecast remains unchanged.\n\nBest regards,"
        XCTAssertFalse(DictationStyle.accept(draft: draft, rewrite: other))
    }

    func testRunawayReplyIsRejected() {
        let runaway = String(repeating: "The Kaiko report will be late by two days. ", count: 40)
        XCTAssertFalse(DictationStyle.accept(draft: draft, rewrite: runaway))
    }

    // MARK: - Tidy

    func testTidyStripsPreambleLine() {
        XCTAssertEqual(DictationStyle.tidy("Here is the letter:\n\nDear Mark,\n\nThanks."), "Dear Mark,\n\nThanks.")
    }

    func testTidyStripsCodeFence() {
        XCTAssertEqual(DictationStyle.tidy("```\n- one\n- two\n```"), "- one\n- two")
    }

    func testTidyStripsWrappingQuotesOnly() {
        XCTAssertEqual(DictationStyle.tidy("\"Hi Mark, the report is late.\""), "Hi Mark, the report is late.")
        // Quotes inside the text are the user's: leave the whole thing alone.
        let quoted = "\"Done\", he said, \"tomorrow\""
        XCTAssertEqual(DictationStyle.tidy(quoted), quoted)
    }

    func testTidyKeepsAGreetingThatEndsInAColon() {
        // Only a short preamble that starts like one is dropped.
        XCTAssertEqual(DictationStyle.tidy("Agenda for Friday:\n- budget"), "Agenda for Friday:\n- budget")
    }

    // MARK: - Prompt

    func testEachStyleAsksForItsOwnForm() {
        XCTAssertTrue(DictationStyle.message.systemPrompt.contains("professional message"))
        XCTAssertTrue(DictationStyle.letter.systemPrompt.contains("formal closing"))
        XCTAssertTrue(DictationStyle.bullets.systemPrompt.contains("\"- \""))
        XCTAssertFalse(DictationStyle.off.systemPrompt.contains("Form:"))
        for style in DictationStyle.allCases {
            XCTAssertTrue(style.systemPrompt.contains("never translate"), "\(style)")
        }
    }

    func testUserPromptCarriesDraftAndVocabulary() {
        let u = DictationStyle.letter.userPrompt(draft: "hello", vocabulary: ["Kaiko", "Blits"])
        XCTAssertTrue(u.contains("Kaiko, Blits"))
        XCTAssertTrue(u.hasSuffix("DRAFT:\nhello"))
    }

    // MARK: - Long dictations (review finding: a cut-off reply passed the guard)

    func testDraftPastTheLimitIsNotRewritten() {
        XCTAssertTrue(DictationStyle.canRewrite(String(repeating: "a", count: DictationStyle.maxDraftCharacters)))
        XCTAssertFalse(DictationStyle.canRewrite(String(repeating: "a", count: DictationStyle.maxDraftCharacters + 1)))
    }

    func testTokenBudgetHoldsTheLongestUkrainianDraftWithRoom() {
        // Ukrainian runs about 2.5 characters a token; a letter adds a
        // greeting and a closing. The budget must never be what ends a reply.
        let longest = String(repeating: "а", count: DictationStyle.maxDraftCharacters)
        let needed = Int(Double(longest.count) / 2.5) + 150
        for style in DictationStyle.allCases where style != .off {
            XCTAssertGreaterThan(style.maxTokens(forDraft: longest), needed, "\(style)")
        }
    }

    func testTooLongFallsBackWithItsOwnNotice() {
        XCTAssertNotEqual(DictationController.fallbackNotice(.tooLong), DictationController.fallbackNotice(.failed))
    }

    // MARK: - Apologies (review finding: rejected as refusals)

    func testApologyTheSpeakerMadeIsNotARefusal() {
        XCTAssertTrue(DictationStyle.accept(
            draft: "sorry I can't make the standup tomorrow I'll send notes about the migration afterwards",
            rewrite: "I'm sorry, I can't make tomorrow's stand-up. I'll send notes about the migration afterwards."))
        XCTAssertTrue(DictationStyle.accept(
            draft: "unfortunately I cannot attend the workshop on Thursday",
            rewrite: "I cannot attend the workshop on Thursday, unfortunately."))
    }

    func testTidyKeepsADictatedTitleThatLooksLikeAPreamble() {
        let draft = "here's what we need for Friday the budget the venue and the speakers"
        let out = "Here's what we need for Friday:\n- Budget\n- Venue\n- Speakers"
        XCTAssertEqual(DictationStyle.tidy(out, draft: draft), out)
        // The same line the speaker did not say is the model's preamble.
        XCTAssertEqual(DictationStyle.tidy(out, draft: "budget venue speakers for friday"), "- Budget\n- Venue\n- Speakers")
    }

    // MARK: - Signature (Settings › My name)

    func testLetterIsSignedUnderABareClosing() {
        let letter = "Dear Mark,\n\nThe Kaiko report will be two days late.\n\nKind regards,"
        XCTAssertEqual(DictationStyle.signed(letter, name: "Yuri"), letter + "\nYuri")
        let uk = "Шановна Оксано,\n\nПропоную перенести зустріч на середу.\n\nЗ повагою,"
        XCTAssertEqual(DictationStyle.signed(uk, name: "Yuri"), uk + "\nYuri")
        // Dutch closings often go without a comma.
        let nl = "Beste Anna,\n\nDe factuur is betaald.\n\nMet vriendelijke groet"
        XCTAssertEqual(DictationStyle.signed(nl, name: "Yuri"), nl + "\nYuri")
    }

    func testLetterTheSpeakerSignedKeepsTheirName() {
        // Real output: the speaker dictated "best regards Pieter".
        let signed = "Dear Anna,\n\nI would like to inform you that the invoice for October has been paid.\n\nBest regards,\nPieter"
        XCTAssertEqual(DictationStyle.signed(signed, name: "Yuri"), signed)
        let mine = "Dear Anna,\n\nThe invoice is paid.\n\nKind regards,\nYuri"
        XCTAssertEqual(DictationStyle.signed(mine, name: "Yuri"), mine)
    }

    // Review findings for 5.9.1.

    func testShortNameInsideAWordDoesNotCountAsSigned() {
        let letter = "Dear Mark,\n\nI will finish it before the deadline, if time allows.\n\nKind regards,"
        XCTAssertEqual(DictationStyle.signed(letter, name: "Tim"), letter + "\nTim")
        let market = "Dear Anna,\n\nThe market report is attached.\n\nKind regards,"
        XCTAssertEqual(DictationStyle.signed(market, name: "Mark"), market + "\nMark")
    }

    func testSignOffsTheSpeakerMadeAreNeverSignedTwice() {
        let cases = [
            "Beste Anna,\n\nDe factuur is betaald.\n\nMet vriendelijke groet\nPieter",
            "Шановна Оксано,\n\nЗустріч у середу.\n\nЗ повагою\nОлена",
            "Beste Anna,\n\nDe factuur is betaald.\n\nGroetjes\nJoeri",
            "Dear Anna,\n\nThe invoice is paid.\n\nBest regards, Anna",
            "Dear Mark,\n\nThe invoice is paid.\n\nKind regards,\nAnna Smit\nHead of Sales",
            "Dear Mark,\n\nThe invoice is paid.\n\nKind regards,\nAnna\n+31 6 1234 5678",
            "Dear Mark,\n\nThe invoice is paid.\n\nKind regards,\nAnna\nKaiko BV",
        ]
        for letter in cases {
            XCTAssertEqual(DictationStyle.signed(letter, name: "Yuri"), letter, letter)
        }
    }

    func testExclaimedClosingIsSignedAndPlaceholdersAreFilled() {
        let thanks = "Hi Mark,\n\nThe invoice is paid.\n\nThanks!"
        XCTAssertEqual(DictationStyle.signed(thanks, name: "Yuri"), thanks + "\nYuri")
        XCTAssertEqual(DictationStyle.signed("Dear Anna,\n\nPaid.\n\nKind regards,\n[Your Name]", name: "Yuri"),
                       "Dear Anna,\n\nPaid.\n\nKind regards,\nYuri")
        XCTAssertEqual(DictationStyle.signed("Beste Anna,\n\nBetaald.\n\nMet vriendelijke groet\n[Uw naam]", name: "Yuri"),
                       "Beste Anna,\n\nBetaald.\n\nMet vriendelijke groet\nYuri")
    }

    func testNoNameOrNoClosingLeavesTheLetterAlone() {
        let letter = "Dear Mark,\n\nThe report is late.\n\nKind regards,"
        XCTAssertEqual(DictationStyle.signed(letter, name: nil), letter)
        XCTAssertEqual(DictationStyle.signed(letter, name: "  "), letter)
        let noClosing = "Dear Mark,\n\nThe report will be two days late because the data was incomplete."
        XCTAssertEqual(DictationStyle.signed(noClosing, name: "Yuri"), noClosing)
    }

    func testTheNameNeverGoesIntoThePrompt() {
        // Signed on the Mac afterwards: a cloud text engine never sees it.
        XCTAssertTrue(DictationStyle.letter.systemPrompt.contains("no name under it"))
        XCTAssertFalse(DictationStyle.letter.userPrompt(draft: "hello").contains("Yuri"))
    }

    // MARK: - Session lifecycle (review findings)

    func testQuietCancelKeepsWhatAStyledSessionCollected() {
        // A key combo while the hotkey is held: the words said before it
        // were pasted at the pauses when unstyled, so styled they must
        // still go out.
        XCTAssertTrue(DictationController.keepsStyledDraftOnCancel(quiet: true, style: .letter, hasDraft: true))
        // Cancel pressed on purpose throws it away; nothing collected, nothing to keep.
        XCTAssertFalse(DictationController.keepsStyledDraftOnCancel(quiet: false, style: .letter, hasDraft: true))
        XCTAssertFalse(DictationController.keepsStyledDraftOnCancel(quiet: true, style: .letter, hasDraft: false))
        XCTAssertFalse(DictationController.keepsStyledDraftOnCancel(quiet: true, style: .off, hasDraft: true))
    }

    func testAnEarlierSessionsRewriteDoesNotTakeTheNewerSessionsScreen() {
        // S1 is still being rewritten while S2 was started and stopped: S2
        // is recognizing, and S1's landing must leave its phase and notices.
        XCTAssertFalse(DictationController.ownsPhase(passageSession: 1, currentSession: 2, phase: .transcribing))
        XCTAssertTrue(DictationController.ownsPhase(passageSession: 2, currentSession: 2, phase: .transcribing))
        XCTAssertTrue(DictationController.ownsPhase(passageSession: 2, currentSession: 2, phase: .inserting))
        XCTAssertFalse(DictationController.ownsPhase(passageSession: 2, currentSession: 2, phase: .listening))
    }

    // MARK: - Where a style applies

    func testStyleIsOffForPasswordsAndVerbatimApps() {
        var secure = DictationContext()
        secure.isSecure = true
        XCTAssertEqual(DictationController.resolveStyle(.letter, mode: .clean, context: secure), .off)
        XCTAssertEqual(DictationController.resolveStyle(.bullets, mode: .verbatim, context: DictationContext()), .off)
    }

    func testStyleAppliesInChatComposersAndTextAreas() {
        var composer = DictationContext()
        composer.role = "AXTextField"   // how chat composers report themselves
        XCTAssertEqual(DictationController.resolveStyle(.message, mode: .smart, context: composer), .message)
        XCTAssertEqual(DictationController.resolveStyle(.letter, mode: .clean, context: DictationContext()), .letter)
        XCTAssertEqual(DictationController.resolveStyle(.off, mode: .smart, context: DictationContext()), .off)
    }

    func testFallbackNoticeSaysTheWordsWentInAsSpoken() {
        for why in [DictationController.RewriteFailure.modelMissing, .busy, .tooLong, .rejected, .failed] {
            XCTAssertFalse(DictationController.fallbackNotice(why).isEmpty)
        }
    }
}
