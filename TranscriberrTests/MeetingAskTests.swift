import XCTest
@testable import Transcriberr

/// "Ask your meetings" (MeetingAsk.swift). The model is stubbed.
final class MeetingAskTests: XCTestCase {
    private let a = UUID(), b = UUID()

    private func line(_ id: UUID, _ start: Double, _ text: String, speaker: String? = nil, title: String = "Weekly") -> MeetingAsk.Line {
        .init(recordingID: id, title: title, date: Date(timeIntervalSince1970: 1_790_000_000), start: start, speaker: speaker, text: text)
    }

    private struct Stub: MeetingAskModel {
        var plan = #"{"terms":["pricing","ціна"],"people":[],"after":null,"before":null}"#
        var reply = "The price is ten [1]."
        func answer(system: String, user: String, maxTokens: Int) async throws -> String {
            system.contains("keyword search") ? plan : reply
        }
    }

    func testPassagesStayInsideOneRecordingAndKeepTheirStart() {
        let long = String(repeating: "word ", count: 200)
        let p = MeetingAsk.passages([line(a, 0, long), line(a, 30, "next"), line(b, 5, "other")])
        XCTAssertEqual(p.filter { $0.recordingID == b }.map(\.text), ["other"])
        XCTAssertEqual(p.filter { $0.recordingID == a }.map(\.start).sorted(), [0, 30])
    }

    func testSpeakerIsNamedOncePerRun() {
        let p = MeetingAsk.passages([line(a, 0, "one", speaker: "Len"), line(a, 1, "two", speaker: "Len"), line(a, 2, "three", speaker: "Yuri")])
        XCTAssertEqual(p[0].text, "Len: one\ntwo\nYuri: three")
        XCTAssertEqual(p[0].speakers, ["Len", "Yuri"])
    }

    func testEndingsDontMatterInEitherLanguage() {
        let p = MeetingAsk.passages([line(a, 0, "We talked about the prices"), line(b, 0, "Обговорили кордонів на роботі")])
        XCTAssertEqual(MeetingAsk.rank(p, plan: .init(terms: ["pricing"])).map(\.recordingID), [a])
        XCTAssertEqual(MeetingAsk.rank(p, plan: .init(terms: ["кордони"])).map(\.recordingID), [b])
    }

    func testShortWordsMatchWhole() {
        let p = MeetingAsk.passages([line(a, 0, "the air was thin")])
        XCTAssertTrue(MeetingAsk.rank(p, plan: .init(terms: ["ai"])).isEmpty)
    }

    func testRareWordsOutrankCommonOnes() {
        var lines = (0..<9).map { _ in line(UUID(), 0, "meeting agenda review") }
        lines.append(line(a, 0, "meeting about the Kaiko contract"))
        let top = MeetingAsk.rank(MeetingAsk.passages(lines), plan: .init(terms: ["meeting", "kaiko"]))
        XCTAssertEqual(top.first?.recordingID, a)
    }

    func testOneRecordingCantTakeEveryPlace() {
        let many = (0..<20).map { line(a, Double($0) * 100, String(repeating: "budget ", count: 200)) }
        let top = MeetingAsk.rank(MeetingAsk.passages(many + [line(b, 0, "budget")]), plan: .init(terms: ["budget"]))
        XCTAssertEqual(top.filter { $0.recordingID == a }.count, MeetingAsk.perRecording)
        XCTAssertTrue(top.contains { $0.recordingID == b })
    }

    /// Found in the app: Kaiko "discussed" in a meeting that never says it.
    func testRareWordLimitsWhatIsRead() {
        var lines = (0..<60).map { _ in line(UUID(), 0, "talk about the discussion and the project") }
        lines.append(line(a, 0, "the Kaiko discussion"))
        let plan = MeetingAsk.parsePlan(#"{"terms":["discussion","project"]}"#, question: "When did we discuss Kaiko?")
        XCTAssertEqual(MeetingAsk.rank(MeetingAsk.passages(lines), plan: plan).map(\.recordingID), [a])
    }

    func testNamedPersonSpeakingRanksFirst() {
        let p = MeetingAsk.passages([line(a, 0, "the budget", speaker: "Len"), line(b, 0, "the budget", speaker: "Iryna Turchak")])
        XCTAssertEqual(MeetingAsk.rank(p, plan: .init(terms: ["budget"], people: ["Iryna"])).first?.recordingID, b)
    }

    func testPlanSurvivesProseAndGarbage() {
        XCTAssertEqual(MeetingAsk.parsePlan("not json", question: "What about Kaiko pricing?").terms, ["kaiko", "pricing"])
        let plan = MeetingAsk.parsePlan("Sure!\n{\"terms\":[\"x y\"],\"people\":[\"Len\"],\"after\":\"2026-10-01\",\"before\":\"nonsense\"}", question: "Len?")
        XCTAssertTrue(plan.terms.contains("x y"))
        XCTAssertEqual(plan.people, ["Len"])
        XCTAssertNotNil(plan.after)
        XCTAssertNil(plan.before)
    }

    /// Seen on the real model: a long plan hit the token limit.
    func testPlanCutOffStillGivesItsTerms() {
        let plan = MeetingAsk.parsePlan(#"{"terms": ["кордони", "межі", "приват"#, question: "x")
        XCTAssertTrue(plan.terms.contains("кордони"))
        XCTAssertTrue(plan.terms.contains("межі"))
    }

    func testPersonWithoutATopicStillFindsWhatTheySaid() {
        let p = MeetingAsk.passages([line(a, 0, "something else", speaker: "Len"), line(b, 0, "unrelated", speaker: "Rado")])
        XCTAssertEqual(MeetingAsk.rank(p, plan: .init(people: ["Len"])).map(\.recordingID), [a])
    }

    func testCitationsAreRenumberedAndBadOnesRemoved() {
        let p = MeetingAsk.passages([line(a, 0, "one"), line(b, 0, "two")])
        let answer = MeetingAsk.parseAnswer("First [2, 9]. Second [1] and [2].", question: "q", passages: p)
        XCTAssertEqual(answer.text, "First[1]. Second[2] and[1].")
        XCTAssertEqual(answer.cited.map(\.passage), [p[1], p[0]])
        XCTAssertTrue(answer.found)
    }

    func testAnswerWithoutCitationsIsNotAnAnswer() {
        let p = MeetingAsk.passages([line(a, 0, "one")])
        for reply in ["The sky is blue.", "NOT_FOUND", "", "Only a bad one [7]."] {
            let answer = MeetingAsk.parseAnswer(reply, question: "q", passages: p)
            XCTAssertFalse(answer.found, reply)
            XCTAssertEqual(answer.nearby.count, 1, reply)
        }
    }

    func testNoPassageMeansTheModelIsNotAskedToAnswer() async throws {
        let answer = try await MeetingAsk.ask("zebra?", lines: [line(a, 0, "budget")], me: "Yuri",
                                              model: Stub(plan: "{}", reply: "invented [1]"))
        XCTAssertFalse(answer.found)
        XCTAssertTrue(answer.nearby.isEmpty)
    }

    func testDatesFilterThenWiden() async throws {
        let old = line(a, 0, "the pricing")
        let stub = Stub(plan: #"{"terms":["pricing"],"after":"2030-01-01"}"#)
        let answer = try await MeetingAsk.ask("pricing lately?", lines: [old], me: "Yuri", model: stub)
        XCTAssertTrue(answer.widened)
        XCTAssertTrue(answer.found)
    }

    func testCitationLinksAreParsed() {
        let text = MeetingAskPane.linked("Ten[1] and five[2]. Array [x] stays.")
        XCTAssertEqual(text.runs.compactMap(\.link).map(\.absoluteString), ["ask://1", "ask://2"])
        XCTAssertTrue(String(text.characters).hasSuffix("[x] stays."))
    }
}
