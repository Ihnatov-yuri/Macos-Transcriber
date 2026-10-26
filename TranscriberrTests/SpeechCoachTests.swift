import XCTest
@testable import Transcriberr

/// The You page (5.0.0): what is measured, how goals are judged, and how
/// the text model's answer is read. The numbers must not depend on it.
final class SpeechCoachTests: XCTestCase {
    private func line(_ a: Double, _ b: Double, _ who: String, _ text: String) -> SpeechLine {
        SpeechLine(start: a, end: b, speaker: who, text: text)
    }

    func testMeasureTalkTurnsInterruptionsAndQuestions() throws {
        let lines = [
            line(0, 30, "Yuri", "So the plan is simple and I think we should start now with the first part of it?"),
            line(31, 50, "Yuri", "Um, you know, maybe next week."),
            line(49, 60, "Anna", "Can I add something here please, I have a point"),   // starts inside Yuri's turn: Anna cuts in
            line(59, 70, "Yuri", "Sure, go on, what is it?"),                           // inside Anna's: Yuri cuts in
            line(70, 100, "Kate", "Some long words from Kate that go on for quite a while here"),
        ]
        let m = try XCTUnwrap(SpeechMeasure.measure(lines, name: "yuri", recordingId: UUID(), title: "t", date: Date()))
        XCTAssertEqual(m.talkSeconds, 30 + 19 + 11, accuracy: 0.001)
        XCTAssertEqual(m.spanSeconds, 100, accuracy: 0.001)
        XCTAssertEqual(m.words, 30)
        XCTAssertEqual(m.meetingWords, 30 + 10 + 13)
        XCTAssertEqual(m.participants, 1, "only Yuri said 25 words")
        XCTAssertEqual(m.turns, 2, "0-50 is one turn over a 1 s gap")
        XCTAssertEqual(m.longestTurn, 49, accuracy: 0.001, "a turn ends where Anna starts")
        XCTAssertEqual(m.interruptions, 1, "Yuri's tight line starts inside Anna's")
        XCTAssertEqual(m.interrupted, 0, "Anna started inside a 19 s line: too loose to tell")
        XCTAssertEqual(m.paceWords, 6, "only the 11 s line is tight")
        XCTAssertEqual(m.questions, 2)
        XCTAssertEqual(m.language, "en")
        XCTAssertEqual(m.fillers, 2, "um, you know")
        XCTAssertEqual(m.hedges, 2, "I think, maybe")
        XCTAssertEqual(m.value(.talkShare) ?? 0, 100 * 30.0 / 53, accuracy: 0.01, "share of the words")
        XCTAssertNil(SpeechMeasure.measure(lines, name: "Nobody", recordingId: UUID(), title: "", date: Date()))
    }

    func testLexiconIsWholeWordAndKnowsUkrainian() {
        XCTAssertEqual(SpeechLexicon.count(["um"], in: "Umbrella, um, UM."), 2)
        XCTAssertEqual(SpeechLexicon.count(["you know"], in: "you know what you know"), 2)
        XCTAssertEqual(SpeechLexicon.language(of: "Ну, я думаю, що це можливо зробити до пʼятниці"), "uk")
        XCTAssertEqual(SpeechLexicon.count(SpeechLexicon.hedges["uk"]!, in: "Ну, я думаю, що це можливо"), 2)
        XCTAssertNil(SpeechLexicon.language(of: "ok"), "too little to tell")
    }

    private func meeting(_ day: Double, share: Double, lang: String? = "en", fillers: Int = 0) -> MeetingSpeech {
        // 140 words a minute: `share` percent of a 10-minute, 1,400-word 1:1.
        MeetingSpeech(recordingId: UUID(), title: "m", date: Date(timeIntervalSince1970: day * 86_400), language: lang,
                      participants: 2, talkSeconds: share * 6, spanSeconds: 600, words: Int(share * 14),
                      meetingWords: 1400, paceWords: Int(share * 14), paceSeconds: share * 6,
                      turns: 5, longestTurn: 40, interruptions: 0, interrupted: 0, questions: 3,
                      fillers: fillers, hedges: 0, others: ["Anna": 1400 - share * 14])
    }

    func testGoalIsReachedInThreeOfFourAndStaleAfterSix() {
        // Two people: a share of 50 is 100 (fair), 70 is 140.
        let goal = SpeechGoal(id: UUID(), metric: .talkShare, language: nil, lowerIsBetter: true, target: 110, baseline: 140,
                              title: "t", why: "w", tips: [], created: Date(timeIntervalSince1970: 0),
                              revised: Date(timeIntervalSince1970: 0))
        let reached = [meeting(1, share: 50), meeting(2, share: 60), meeting(3, share: 52), meeting(4, share: 54)]
        let v = GoalJudge.judge(goal, meetings: reached, now: Date(timeIntervalSince1970: 5 * 86_400))
        XCTAssertEqual(v.hits, 3)
        XCTAssertTrue(v.achieved)
        let stuck = (1...6).map { meeting(Double($0), share: 70) }
        XCTAssertTrue(GoalJudge.judge(goal, meetings: stuck, now: Date(timeIntervalSince1970: 7 * 86_400)).stale)
        XCTAssertFalse(GoalJudge.judge(goal, meetings: Array(stuck.prefix(2)), now: Date(timeIntervalSince1970: 3 * 86_400)).stale)
        XCTAssertTrue(GoalJudge.judge(goal, meetings: Array(stuck.prefix(1)), now: Date(timeIntervalSince1970: 30 * 86_400)).stale,
                      "three weeks without reaching it")
        let before = [meeting(-1, share: 50)]
        XCTAssertEqual(GoalJudge.judge(goal, meetings: before).values, [], "meetings before the goal do not count")
    }

    func testTargetsMoveTowardsTheIdealInSteps() {
        XCTAssertEqual(SpeechTargets.nextTarget(average: 80, ideal: 55, lowerIsBetter: true), 67.5, accuracy: 0.001)
        XCTAssertEqual(SpeechTargets.nextTarget(average: 58, ideal: 55, lowerIsBetter: true), 55, accuracy: 0.001)
        XCTAssertEqual(SpeechTargets.nextTarget(average: 0, ideal: 1.5, lowerIsBetter: false), 0.45, accuracy: 0.001,
                       "from zero the step is a tenth of the ideal, at most three")
        XCTAssertEqual(SpeechTargets.nextTarget(average: 10, ideal: 2, lowerIsBetter: true), 7, accuracy: 0.001,
                       "never more than three steps at once")
    }

    func testGapsRankTheWorstAndRespectFairShare() {
        let ms = (1...5).map { meeting(Double($0), share: 80, fillers: 40) }
        let gaps = SpeechTargets.gaps(ms)
        XCTAssertEqual(gaps.first?.metric, .fillers)
        XCTAssertEqual(gaps.first?.language, "en")
        let share = gaps.first { $0.metric == .talkShare }
        XCTAssertEqual(share?.lowerIsBetter, true)
        XCTAssertEqual(share?.average ?? 0, 160, accuracy: 0.001, "80% of a 1:1 is 160% of a fair share")
        XCTAssertEqual(share?.ideal ?? 0, 110, accuracy: 0.001)
    }

    func testCoachReplyIsReadOnlyForKnownGaps() {
        let raw = """
        GOAL: talkShare | Leave room | You talk a lot.
        GOAL: madeUp | Invented | nope
        TIP: talkShare | Ask "what do you think?" after your point.
        TIP: talkShare | Second tip
        TIP: talkShare | Third tip is dropped
        NOTE: You often start with the conclusion, which is clear.
        """
        let r = SpeechCoach.parse(raw, codes: ["talkShare", "fillers-en"])
        XCTAssertEqual(r.goals.map(\.code), ["talkShare"])
        XCTAssertEqual(r.tips["talkShare"]?.count, 2)
        XCTAssertEqual(r.notes.count, 1)
        XCTAssertEqual(SpeechCoach.parse("NOTE: talkShare | You open with the conclusion.", codes: ["talkShare"]).notes,
                       ["You open with the conclusion."], "a leading gap code is dropped (seen from Gemma 4)")
    }

    func testGoalsComeFromGapsWithOrWithoutTheModel() {
        let gaps = SpeechTargets.gaps((1...5).map { meeting(Double($0), share: 80, fillers: 40) })
        let none = SpeechCoach.goals(from: gaps, reply: nil, want: 2, taken: [], now: Date())
        XCTAssertEqual(none.count, 2)
        XCTAssertEqual(none.first?.metric, .fillers)
        XCTAssertFalse(none.first?.tips.isEmpty ?? true, "plain wording when the model is unavailable")
        let reply = SpeechCoach.parse("GOAL: talkShare | Leave room | Because.", codes: Set(gaps.map(SpeechCoach.code)))
        let picked = SpeechCoach.goals(from: gaps, reply: reply, want: 1, taken: [], now: Date())
        XCTAssertEqual(picked.first?.metric, .talkShare, "the model chooses which gap")
        XCTAssertEqual(picked.first?.title, "Leave room")
        XCTAssertEqual(picked.first?.target, gaps.first { $0.metric == .talkShare }?.target, "but never the number")
        XCTAssertTrue(SpeechCoach.goals(from: gaps, reply: nil, want: 2, taken: Set(gaps.map(SpeechCoach.code)), now: Date()).isEmpty)
    }

    func testCoachStoreRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coach-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CoachStore(url: url)
        var s = store.load()
        XCTAssertTrue(s.goals.isEmpty)
        s.goals = SpeechCoach.goals(from: SpeechTargets.gaps((1...5).map { meeting(Double($0), share: 80) }),
                                    reply: nil, want: 1, taken: [], now: Date())
        try store.save(s)
        XCTAssertEqual(store.load().goals, s.goals)
    }
}

extension SpeechCoachTests {
    func testPaddedMicLinesDoNotSlowPaceOrFakeInterruptions() throws {
        // A split-track meeting: the mic line runs 0-60 s across the call's
        // speech, as the user's library shows (10-60 s mic lines).
        let words = Array(repeating: "word", count: 70).joined(separator: " ")
        var lines = [SpeechLine(start: 0, end: 60, speaker: "Me", text: words)]
        for i in 0..<5 {
            let t = Double(i) * 10 + 5
            lines.append(SpeechLine(start: t, end: t + 4, speaker: "Anna", text: "short reply from the call side here"))
            lines.append(SpeechLine(start: t + 70, end: t + 76, speaker: "Me", text: "and a tight answer of mine follows here now"))
        }
        let m = try XCTUnwrap(SpeechMeasure.measure(lines, name: "Me", recordingId: UUID(), title: "", date: Date()))
        XCTAssertEqual(m.interrupted, 0, "the call speaking inside a padded mic line is not cutting in")
        XCTAssertEqual(m.interruptions, 0)
        XCTAssertEqual(m.value(.pace) ?? 0, 90, accuracy: 0.5, "pace from the 6 s lines only: 9 words in 6 s")
    }

    func testHeadlineTrendAndSparklineShareTheSameMeetings() {
        let ms = (1...20).map { meeting(Double($0), share: $0 <= 10 ? 90 : 50) }
        let series = SpeechMeasure.series(.talkShare, over: ms)
        XCTAssertEqual(series.count, SpeechMeasure.window)
        XCTAssertEqual(SpeechMeasure.average(.talkShare, over: ms) ?? 0, 100, accuracy: 0.001,
                       "the newest ten only: 50% of a 1:1 is 100")
    }
}
