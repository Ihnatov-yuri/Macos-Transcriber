import XCTest
@testable import Transcriberr

private actor Counter {
    var value = 0
    func bump() { value += 1 }
}

final class MeetingBriefTests: XCTestCase {

    private let transcript = """
    SPEAKER_01: Я з цим зіштовхнулася, працюючи в Мьюз, бо в Мьюз тисяча людей. Останнє, ми купили стартап, який робить хаускіпінг.
    Yuri: У мене було інтерв'ю з Logic Monitor. Я їздив з мастер-карда. І воно так добре вплелось, і так далі, і так було.
    """

    // MARK: - Parse

    func testParseToleratesMarkdownAndNoise() {
        let raw = """
        Here is the result:
        **TOPIC:** Коучингова розмова про продуктові обіцянки.
        - PEOPLE: Yuri — клієнт; SPEAKER_01 — коуч
        TERMS: Muse; Logic Monitor; housekeeping
        FIX: Мьюз => Muse
        FIX: хаускіпінг → housekeeping
        FIX: без стрілки
        Hope this helps!
        """
        let b = MeetingBriefBuilder.parse(raw)
        XCTAssertEqual(b.topic, "Коучингова розмова про продуктові обіцянки")
        XCTAssertEqual(b.people, ["Yuri — клієнт", "SPEAKER_01 — коуч"])
        XCTAssertEqual(b.terms, ["Muse", "Logic Monitor", "housekeeping"])
        XCTAssertEqual(b.fixes, [.init(from: "Мьюз", to: "Muse"), .init(from: "хаускіпінг", to: "housekeeping")])
    }

    func testParseDropsPlaceholders() {
        let b = MeetingBriefBuilder.parse("TOPIC: unknown\nPEOPLE: none\nTERMS: N/A")
        XCTAssertTrue(b.isEmpty)
        XCTAssertEqual(b.promptBlock, "")
    }

    func testAttestedKeepsOnlyNameLikeTermsPresentInTheText() {
        var b = MeetingBrief()
        b.people = ["Yuri — клієнт", "Катія"]
        b.terms = ["Logic Monitor", "стартап", "Agentbank", "GPT-7", "Мьюз"]
        let kept = MeetingBriefBuilder.attested(b, in: transcript)
        XCTAssertEqual(kept.people, ["Yuri — клієнт"])      // "Катія" is not in the text
        XCTAssertEqual(kept.terms, ["Logic Monitor", "Мьюз"]) // ordinary noun, vocabulary echo and invention dropped
    }

    func testParseStopsAtARepetitionLoop() {
        let raw = "TERMS: Muse\n" + Array(repeating: "FIX: чу => чу", count: 40).joined(separator: "\n") + "\nTERMS: Late"
        let b = MeetingBriefBuilder.parse(raw)
        XCTAssertEqual(b.terms, ["Muse"])
        XCTAssertLessThanOrEqual(b.fixes.count, 2)
    }

    // MARK: - Guards

    func testAcceptsSoundAlikeCrossScriptFixes() {
        let fixes: [MeetingBrief.Fix] = [
            .init(from: "Мьюз", to: "Muse"),
            .init(from: "хаускіпінг", to: "housekeeping"),
            .init(from: "мастер-карда", to: "MasterCard"),
        ]
        XCTAssertEqual(MeetingBriefBuilder.acceptedFixes(
            fixes, transcript: transcript, vocabulary: "MasterCard", terms: ["Muse", "housekeeping"]), fixes)
        // The same fixes with nothing attesting the replacements are refused.
        XCTAssertEqual(MeetingBriefBuilder.acceptedFixes(fixes, transcript: transcript, vocabulary: ""), [])
    }

    func testRejectsUnsafeFixes() {
        let fixes: [MeetingBrief.Fix] = [
            .init(from: "Кайко", to: "Kaiko"),              // not in the transcript
            .init(from: "Мьюз", to: "Mews PMS platform"),   // does not sound alike
            .init(from: "стартап", to: "компанія"),         // an ordinary word swapped for another
            .init(from: "так", to: "tak"),                  // too short a phonetic key
            .init(from: "Logic Monitor", to: "LogicMonitor Incorporated Company Ltd"),  // shape
        ]
        XCTAssertEqual(MeetingBriefBuilder.acceptedFixes(
            fixes, transcript: transcript, vocabulary: "",
            terms: ["Kaiko", "Mews PMS platform", "компанія", "tak", "Так"]), [])
    }

    func testNeverRewritesAnAuthoritativeSpelling() {
        let fixes: [MeetingBrief.Fix] = [.init(from: "Logic Monitor", to: "LogicMonitor")]
        XCTAssertEqual(MeetingBriefBuilder.acceptedFixes(
            fixes, transcript: transcript, vocabulary: "Kaiko, Logic Monitor"), [])
        XCTAssertEqual(MeetingBriefBuilder.acceptedFixes(
            fixes, transcript: transcript, vocabulary: "", terms: ["LogicMonitor"]), fixes)
    }

    func testRejectsFrequentLowercaseSameScriptWord() {
        let text = Array(repeating: "ну і так воно працює", count: 8).joined(separator: ". ")
        XCTAssertEqual(MeetingBriefBuilder.acceptedFixes(
            [.init(from: "працює", to: "працюе")], transcript: text, vocabulary: "", terms: ["працюе"]), [])
    }

    func testSentenceInitialCapitalIsNotAName() {
        let text = "Контроль тут важливий. Ми маємо контроль, і цей контроль працює. Панель Control відкрита."
        XCTAssertEqual(MeetingBriefBuilder.acceptedFixes(
            [.init(from: "Контроль", to: "Control")], transcript: text, vocabulary: ""), [])
    }

    func testDictionaryWordsAreLeftAlone() {
        let text = "Наш менеджер сказав, що manager вирішує. А хаускіпінг, тобто housekeeping, автоматизують."
        let fixes: [MeetingBrief.Fix] = [
            .init(from: "менеджер", to: "manager"),
            .init(from: "хаускіпінг", to: "housekeeping"),
        ]
        XCTAssertEqual(MeetingBriefBuilder.acceptedFixes(fixes, transcript: text, vocabulary: ""),
                       [.init(from: "хаускіпінг", to: "housekeeping")])
    }

    func testRejectsChainsEitherWayRound() {
        let text = "Ми були в Мьюз. Мьюз велика, а Muse теж."
        let first = MeetingBrief.Fix(from: "Мьюз", to: "Muse"), second = MeetingBrief.Fix(from: "Muse", to: "Mews")
        let terms = ["Muse", "Mews"]
        // Each is fine on its own…
        XCTAssertEqual(MeetingBriefBuilder.acceptedFixes([second], transcript: text, vocabulary: "", terms: terms), [second])
        // …but together "Мьюз" would end up "Mews", whichever comes first.
        XCTAssertEqual(MeetingBriefBuilder.acceptedFixes([first, second], transcript: text, vocabulary: "", terms: terms), [first])
        XCTAssertEqual(MeetingBriefBuilder.acceptedFixes([second, first], transcript: text, vocabulary: "", terms: terms), [second])
    }

    func testDiarizerLabelsAreNotPeople() {
        var b = MeetingBrief()
        b.people = ["SPEAKER_01", "Speaker 2 — коуч", "Yuri"]
        let text = "SPEAKER_01: привіт\nSpeaker 2: так\nYuri: добре"
        XCTAssertEqual(MeetingBriefBuilder.attested(b, in: text).people, ["Yuri"])
    }

    func testBuildStopsWhenCancelled() async {
        let long = Array(repeating: "Спікер: це речення звичайної довжини для перевірки роботи.", count: 2_000)
            .joined(separator: "\n")
        let calls = Counter()
        let task = Task {
            try await MeetingBriefBuilder.build(transcript: long, vocabulary: "") { _, _, _ in
                await calls.bump()
                withUnsafeCurrentTask { $0?.cancel() }
                return "TOPIC: x"
            }
        }
        _ = try? await task.value
        let n = await calls.value
        XCTAssertEqual(n, 1)
    }

    func testTopicKeepsAtMostTwoSubjects() {
        var a = MeetingBrief()
        for t in ["перша тема", "друга тема", "третя тема"] {
            var b = MeetingBrief(); b.topic = t
            MeetingBriefBuilder.merge(b, into: &a)
        }
        XCTAssertEqual(a.topic, "перша тема / друга тема")
    }

    // MARK: - Apply

    func testApplyReplacesWholeWordsOnly() {
        let out = MeetingBriefBuilder.apply(
            [.init(from: "Мьюз", to: "Muse")],
            to: "працюючи в Мьюз, бо в мьюз. А Мьюзикл — це інше.")
        XCTAssertEqual(out, "працюючи в Muse, бо в Muse. А Мьюзикл — це інше.")
    }

    func testApplyPrefersLongestMatchAndEscapesTemplate() {
        let out = MeetingBriefBuilder.apply(
            [.init(from: "Монітор", to: "Monitor"), .init(from: "Лоджик Монітор", to: "Logic$Monitor")],
            to: "інтерв'ю з Лоджик Монітор")
        XCTAssertEqual(out, "інтерв'ю з Logic$Monitor")
    }

    // MARK: - Budget

    func testSectionsSplitOnlyWhenOverBudget() {
        XCTAssertEqual(MeetingBriefBuilder.sections("коротко").count, 1)
        let long = Array(repeating: "Спікер: це речення звичайної довжини для перевірки.", count: 400)
            .joined(separator: "\n")
        let parts = MeetingBriefBuilder.sections(long, tokenBudget: 2_000)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { MeetingBriefBuilder.estimatedTokens($0) <= 2_100 })
        XCTAssertEqual(parts.joined(separator: "\n"), long)
    }

    func testBuildMergesSectionsAndSurvivesOneFailure() async throws {
        let long = Array(repeating: "Спікер: працюючи в Мьюз, або Muse, ми багато зробили цього року.", count: 2_000)
            .joined(separator: "\n")
        XCTAssertGreaterThan(MeetingBriefBuilder.sections(long).count, 1)
        var call = 0
        let brief = try await MeetingBriefBuilder.build(transcript: long, vocabulary: "") { _, _, _ in
            call += 1
            if call == 1 { throw NSError(domain: "t", code: 1) }
            return "TOPIC: Робота\nTERMS: Muse\nFIX: Мьюз => Muse"
        }
        XCTAssertTrue(brief.topic.hasPrefix("Робота"))
        XCTAssertEqual(brief.fixes, [.init(from: "Мьюз", to: "Muse")])
    }

    func testBuildThrowsWhenEverythingFails() async {
        do {
            _ = try await MeetingBriefBuilder.build(transcript: transcript, vocabulary: "") { _, _, _ in
                throw NSError(domain: "t", code: 1)
            }
            XCTFail("expected a throw")
        } catch {}
    }

    func testCacheKeyFollowsContent() {
        let a = MeetingBriefBuilder.cacheKey(transcript: "x", vocabulary: "v")
        XCTAssertEqual(a, MeetingBriefBuilder.cacheKey(transcript: "x", vocabulary: "v"))
        XCTAssertNotEqual(a, MeetingBriefBuilder.cacheKey(transcript: "y", vocabulary: "v"))
        XCTAssertNotEqual(a, MeetingBriefBuilder.cacheKey(transcript: "x", vocabulary: "w"))
    }
}
