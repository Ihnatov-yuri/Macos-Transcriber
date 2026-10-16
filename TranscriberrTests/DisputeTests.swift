import XCTest
@testable import Transcriberr

final class DisputeTests: XCTestCase {
    private func w(_ s: String, _ c: Float = 0.9) -> ScoredWord {
        ScoredWord(surface: s, norm: TranscriptHygiene.wordKey(s), confidence: c)
    }

    func testVoteRecordsTheLosingReading() {
        let a = [w("we"), w("met"), w("Kaico", 0.4), w("today.")]
        let b = [w("we"), w("met"), w("Kaiko", 0.8), w("today.")]
        let r = EnsembleBackend.roverMergeDetailed(a, b)
        XCTAssertEqual(r.text, "we met Kaiko today.")
        XCTAssertEqual(r.disputes.count, 1)
        XCTAssertEqual(r.disputes[0].chosen, "Kaiko")
        XCTAssertEqual(r.disputes[0].alternative, "Kaico")
        XCTAssertEqual(r.disputes[0].before, "met")
        XCTAssertEqual(r.disputes[0].after, "today")
    }

    func testOnlyReadingsOfOneWordAreDisputes() {
        for (x, y) in [("kaico", "kaiko"), ("worked", "work"), ("hours", "manhours"), ("жовтні", "жовтня"),
                       ("ні", "не"), ("чомусь", "чимось")] {
            XCTAssertTrue(EnsembleBackend.readingsAlike(x, y), "\(x)/\(y)")
        }
        for (x, y) in [("for", "i"), ("of", "that"), ("kimkim", "what"), ("in", "within"), ("в", "впродовж"),
                       ("kind", "there"), ("29го", "двадцять")] {
            XCTAssertFalse(EnsembleBackend.readingsAlike(x, y), "\(x)/\(y)")
        }
        // A misaligned pair is still voted, just not offered.
        XCTAssertTrue(EnsembleBackend.roverMergeDetailed([w("for")], [w("I", 0.2)]).disputes.isEmpty)
    }

    func testAgreedWordsAreNotDisputes() {
        let a = [w("hello"), w("there")]
        XCTAssertTrue(EnsembleBackend.roverMergeDetailed(a, a).disputes.isEmpty)
    }

    func testDisputesStayInStepWhenInsertionsAreDropped() {
        // B's lone low-confidence insertion is dropped; the dispute after it
        // must still describe the right word.
        let a = [w("the"), w("plan"), w("is"), w("Blitz", 0.3)]
        let b = [w("the"), w("ghost", 0.2), w("plan"), w("is"), w("Blits", 0.9)]
        let r = EnsembleBackend.roverMergeDetailed(a, b)
        XCTAssertEqual(r.text, "the plan is Blits")
        XCTAssertEqual(r.disputes.map(\.chosen), ["Blits"])
        XCTAssertEqual(r.disputes[0].before, "is")
    }

    func testLearnedChoiceOutranksConfidence() {
        let a = [w("ask"), w("Kaico", 0.95)]
        let b = [w("ask"), w("Kaiko", 0.2)]
        XCTAssertEqual(EnsembleBackend.roverMerge(a, b), "ask Kaico")
        XCTAssertEqual(EnsembleBackend.roverMerge(a, b, learned: ["kaico>kaiko"]), "ask Kaiko")
        // And it is still offered as a dispute, so the user can flip it back.
        XCTAssertEqual(EnsembleBackend.roverMergeDetailed(a, b, learned: ["kaico>kaiko"]).disputes.first?.alternative, "Kaico")
    }

    func testHitFoundAfterTheTextMoved() {
        let d = WordDispute(chosen: "Kaico", alternative: "Kaiko", before: "met", after: "today", start: 0, end: 30)
        var claimed = Set<Int>()
        // Turn merging glued another sentence in front; the word is still found.
        let text = "Good morning. We met Kaico, today."
        let hits = DisputeIndex.hits(in: text, start: 12, end: 20, disputes: [d], claimed: &claimed)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(String(text[hits[0].range]), "Kaico")
        let picked = DisputeIndex.pick(hits[0], in: text)
        XCTAssertEqual(picked.text, "Good morning. We met Kaiko, today.")
        XCTAssertEqual(picked.flipped.chosen, "Kaiko")
        XCTAssertEqual(picked.flipped.alternative, "Kaico")
        // Flipped, it is found again and can be switched back.
        var c2 = Set<Int>()
        let again = DisputeIndex.hits(in: picked.text, start: 12, end: 20, disputes: [picked.flipped], claimed: &c2)
        XCTAssertEqual(again.count, 1)
    }

    func testNoHitWithoutNeighboursOrOutsideTheChunk() {
        let d = WordDispute(chosen: "plan", alternative: "plant", before: "the", after: "works", start: 0, end: 30)
        var claimed = Set<Int>()
        XCTAssertTrue(DisputeIndex.hits(in: "a plan here", start: 0, end: 10, disputes: [d], claimed: &claimed).isEmpty)
        XCTAssertTrue(DisputeIndex.hits(in: "the plan works", start: 60, end: 70, disputes: [d], claimed: &claimed).isEmpty)
        XCTAssertEqual(DisputeIndex.hits(in: "the plan works", start: 5, end: 9, disputes: [d], claimed: &claimed).count, 1)
        // Claimed: the same dispute is not shown twice.
        XCTAssertTrue(DisputeIndex.hits(in: "the plan works", start: 5, end: 9, disputes: [d], claimed: &claimed).isEmpty)
    }

    func testEncodeDecodeRoundTrip() {
        let d = [WordDispute(chosen: "a", alternative: "b", before: "", after: "c", start: 1, end: 2)]
        XCTAssertEqual(DisputeIndex.decode(DisputeIndex.encode(d)), d)
        XCTAssertNil(DisputeIndex.encode([]))
    }

    func testLearningStoresOnePairPerWordPair() {
        let defaults = UserDefaults(suiteName: "DisputeTests-\(UUID())")!
        DisputeLearning.record(loser: "Kaico", winner: "Kaiko,", defaults)
        XCTAssertEqual(DisputeLearning.pairs(defaults), ["kaico>kaiko"])
        // Clicking back undoes the rule; it does not learn the opposite.
        XCTAssertEqual(DisputeLearning.record(loser: "Kaiko", winner: "Kaico", defaults), .undone)
        XCTAssertTrue(DisputeLearning.pairs(defaults).isEmpty)
        // Ordinary words are not learned.
        XCTAssertEqual(DisputeLearning.record(loser: "their", winner: "there", learn: false, defaults), .ignored)
        // ...and clicking back from one leaves no rule either.
        XCTAssertEqual(DisputeLearning.record(loser: "there", winner: "their", learn: true, defaults), .undone)
        XCTAssertTrue(DisputeLearning.pairs(defaults).isEmpty)
        DisputeLearning.record(loser: "Blitz", winner: "Blits", defaults)
        DisputeLearning.record(loser: "Kaico", winner: "Kaiko", defaults)
        XCTAssertEqual(DisputeLearning.ordered(defaults), ["kaico>kaiko", "blitz>blits"])
        DisputeLearning.remove("blitz>blits", defaults)
        XCTAssertEqual(DisputeLearning.pairs(defaults), ["kaico>kaiko"])
    }

    func testOnlyNamesAndTermsJoinTheVocabulary() {
        XCTAssertTrue(DisputeLearning.isTerm("Kaiko", sentenceStart: false))
        XCTAssertFalse(DisputeLearning.isTerm("Kaiko", sentenceStart: true))
        XCTAssertTrue(DisputeLearning.isTerm("KimKim", sentenceStart: true))
        XCTAssertTrue(DisputeLearning.isTerm("LLMs4EU", sentenceStart: true))
        XCTAssertFalse(DisputeLearning.isTerm("plant", sentenceStart: false))
        XCTAssertFalse(DisputeLearning.isTerm("Ok", sentenceStart: false))
        let t = "Hi. Kaiko is here"
        let r = t.range(of: "Kaiko")!
        XCTAssertTrue(DisputeLearning.startsSentence(r, in: t))
        XCTAssertFalse(DisputeLearning.startsSentence(t.range(of: "is")!, in: t))
    }

    func testCleanViewShowsTheDisputeAndThePickEditsTheStoredText() {
        // The row shows the Clean style; the pick must edit the stored text.
        let raw = "we we met Kaico today."
        let shown = TranscriptStyle.clean.apply(raw)
        let d = WordDispute(chosen: "Kaico", alternative: "Kaiko", before: "met", after: "today", start: 0, end: 10)
        var c1 = Set<Int>(), c2 = Set<Int>()
        XCTAssertEqual(DisputeIndex.hits(in: shown, start: 0, end: 5, disputes: [d], claimed: &c1).count, 1)
        let hit = DisputeIndex.hits(in: raw, start: 0, end: 5, disputes: [d], claimed: &c2)[0]
        XCTAssertEqual(DisputeIndex.pick(hit, in: raw).text, "we we met Kaiko today.")
    }

    func testOneDisputePerWordAcrossSegments() {
        // Two segments say the same thing; the dispute shows in the first only.
        let d = WordDispute(chosen: "plan", alternative: "plant", before: "the", after: "works", start: 0, end: 30)
        let shown = DisputeIndex.locate(d: [d], in: [(0, 5, "the plan works"), (5, 10, "the plan works")])
        XCTAssertEqual(shown.map(\.0), [0])
    }

    func testForgettingALearnedTermTakesItFromTheListItWentInto() {
        let d = UserDefaults(suiteName: "DisputeTests-store-\(UUID())")!
        d.set("Kaiko, Blits", forKey: "prompt.vocabulary")
        let store = PromptStore(defaults: d)
        store.learnTerm("Kaiko", language: "Ukrainian")
        XCTAssertEqual(store.vocabularyByLanguage["Ukrainian"], "Kaiko")
        store.forgetLearnedTerm("Kaiko")
        XCTAssertEqual(store.vocabularyByLanguage["Ukrainian"], "")
        // The user's own global entry is untouched.
        XCTAssertEqual(store.vocabulary, "Kaiko, Blits")
        // A term the user typed was never learned: forgetting it does nothing.
        store.forgetLearnedTerm("Blits")
        XCTAssertEqual(store.vocabulary, "Kaiko, Blits")
    }

    func testClickingTheSecondCopyChangesTheSecondCopy() {
        let d1 = WordDispute(chosen: "Kaico", alternative: "Kaiko", before: "ask", after: "first", start: 0, end: 30)
        let d2 = WordDispute(chosen: "Kaico", alternative: "Kaiko", before: "ask", after: "again", start: 0, end: 30)
        let text = "ask Kaico first, then ask Kaico again"
        let hit = DisputeIndex.hit(1, disputes: [d1, d2], in: [(0, 10, text)], row: 0)
        XCTAssertNotNil(hit)
        XCTAssertEqual(DisputeIndex.pick(hit!, in: text).text, "ask Kaico first, then ask Kaiko again")
    }
}
