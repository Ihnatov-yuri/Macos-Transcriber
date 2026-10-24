import XCTest
@testable import Transcriberr

/// Saved people (4.5.0): the store, the matching rule, and which speakers a
/// match may rename. Embeddings are small synthetic vectors; the rule only
/// sees cosines.
final class PeopleTests: XCTestCase {
    var dir: URL!
    var store: PeopleStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("people-\(UUID().uuidString.prefix(6))")
        store = PeopleStore(url: dir.appendingPathComponent("people.json"))
        store.myVoice = { nil }   // never the real user's voice in a test
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func unit(_ v: [Float]) -> [Float] {
        let n = sqrt(v.map { $0 * $0 }.reduce(0, +)); return v.map { $0 / n }
    }
    private func print(_ v: [Float], count: Int = 4, seconds: Double = 20) -> Voiceprint {
        Voiceprint(seconds: seconds, embeddings: Array(repeating: unit(v), count: count))
    }
    private func person(_ name: String, _ v: [Float]) -> Person {
        Person(id: UUID(), name: name, created: Date(), updated: Date(), print: print(v), sources: 1)
    }

    // MARK: Store

    func testRememberAddsAndSameNameMerges() throws {
        let a = try store.remember(print([1, 0, 0, 0]), as: "  Kate ")
        XCTAssertEqual(a.name, "Kate")
        let b = try store.remember(print([0.9, 0.1, 0, 0], seconds: 12), as: "kate")
        XCTAssertEqual(b.id, a.id, "the same name, any case, is the same person")
        XCTAssertEqual(b.sources, 2)
        XCTAssertEqual(b.print.seconds, 32)
        XCTAssertEqual(b.print.embeddings.count, 8)
        XCTAssertEqual(store.load().count, 1)
        try store.remember(print([0, 1, 0, 0]), as: "Anna")
        XCTAssertEqual(store.load().map(\.name), ["Anna", "Kate"])
    }

    func testEmbeddingsAreCapped() throws {
        try store.remember(print([1, 0, 0, 0], count: 100), as: "Kate")
        let p = try store.remember(print([1, 0.2, 0, 0], count: 100), as: "Kate")
        XCTAssertEqual(p.print.embeddings.count, Person.maxEmbeddings)
        XCTAssertEqual(p.print.embeddings.last, unit([1, 0.2, 0, 0]), "the newest are kept")
    }

    func testRenameDeleteAndDeleteAll() throws {
        let k = try store.remember(print([1, 0, 0, 0]), as: "Kate")
        try store.remember(print([0, 1, 0, 0]), as: "Anna")
        try store.rename(k.id, to: "Katherine")
        XCTAssertEqual(Set(store.load().map(\.name)), ["Katherine", "Anna"])
        XCTAssertThrowsError(try store.rename(k.id, to: "  "))
        try store.delete(k.id)
        XCTAssertEqual(store.load().map(\.name), ["Anna"])
        try store.deleteAll()
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testDamagedFileIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertThrowsError(try store.remember(print([1, 0, 0, 0]), as: "Kate"))
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8), "not json")
    }

    func testFileIsPrivate() throws {
        try store.remember(print([1, 0, 0, 0]), as: "Kate")
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    // MARK: Matching

    func testAssignNamesAClearMatchOnly() {
        let kate = person("Kate", [1, 0, 0, 0]), anna = person("Anna", [0, 1, 0, 0])
        let clips: (([Float]) -> [[Float]]) = { v in Array(repeating: self.unit(v), count: 5) }
        let out = PeopleMatch.assign([
            "S1": clips([0.95, 0.2, 0, 0]),   // Kate
            "S2": clips([0.1, 0.9, 0.3, 0]),  // Anna
            "S3": clips([0, 0, 1, 0.2]),      // nobody saved
            "S4": clips([0.7, 0.7, 0, 0]),    // as close to both: never guessed
            "S5": Array(clips([1, 0, 0, 0]).prefix(2)),  // too little speech
        ], people: [kate, anna])
        XCTAssertEqual(out.mapValues(\.name), ["S1": "Kate", "S2": "Anna"])
    }

    func testAssignWithNobodySaved() {
        XCTAssertTrue(PeopleMatch.assign(["S1": Array(repeating: [1, 0], count: 5)], people: []).isEmpty)
    }

    func testRenamableSkipsTheUserAndHandTypedNames() {
        let people = [person("Kate", [1, 0, 0, 0])]
        let keys = PeopleMatch.renamable(names: [
            "S1": nil, "S2": "", "S3": "kate", "S4": "Yuri", "S5": "My boss", "TAGGED_1": "Kate",
        ], people: people, me: "Yuri")
        XCTAssertEqual(keys, ["S1", "S2", "S3"])
    }

    // MARK: Track record and candidates (5.0.0)

    func testAssessKeepsNearMissesTheRuleDoesNotName() {
        let kate = person("Kate", [1, 0, 0, 0]), anna = person("Anna", [0, 1, 0, 0])
        let clips: (([Float]) -> [[Float]]) = { v in Array(repeating: self.unit(v), count: 5) }
        let out = PeopleMatch.assess([
            "S1": clips([0.95, 0.2, 0, 0]),   // Kate, clear
            "S2": clips([0.45, 0, 0.89, 0]),  // 0.45 to Kate: near miss
            "S3": clips([0, 0, 1, 0.2]),      // nobody
            "S4": clips([0.7, 0.7, 0, 0]),    // both close: near miss, never named
        ], people: [kate, anna])
        XCTAssertEqual(out["S1"]?.accepted, true)
        XCTAssertEqual(out["S2"]?.person.name, "Kate")
        XCTAssertEqual(out["S2"]?.isNearMiss, true)
        XCTAssertEqual(out["S3"]?.isNearMiss, false)
        XCTAssertEqual(out["S4"]?.accepted, false)
        XCTAssertEqual(out["S4"]?.isNearMiss, true)
    }

    func testLogReplacesARecordingsEarlierEntries() throws {
        let kate = try store.remember(print([1, 0, 0, 0]), as: "Kate")
        let rec = UUID()
        let hit = PeopleMatch.Assessment(person: kate, score: 0.6, runnerUp: nil, accepted: true)
        let near = PeopleMatch.Assessment(person: kate, score: 0.45, runnerUp: nil, accepted: false)
        try store.log(["S1": hit, "S2": near], in: rec)
        try store.log(["S1": hit, "S2": near], in: rec)   // Find people again
        var p = try XCTUnwrap(store.load().first)
        XCTAssertEqual(p.matches?.count, 1, "a second pass over one recording does not count twice")
        XCTAssertEqual(p.candidates?.map(\.speaker), ["S2"])

        try store.resolve(try XCTUnwrap(p.candidates?.first), for: p.id, wasThem: false)
        try store.log(["S2": near], in: rec)
        p = try XCTUnwrap(store.load().first)
        XCTAssertEqual(p.candidates ?? [], [], "a speaker said to be someone else is not offered again")
        XCTAssertEqual(p.matches ?? [], [], "the re-run found no match this time")
    }

    func testLearningFromARecordingSettlesItsCandidates() throws {
        let kate = try store.remember(print([1, 0, 0, 0]), as: "Kate")
        let rec = UUID()
        try store.log(["S2": .init(person: kate, score: 0.35, runnerUp: nil, accepted: false)], in: rec)
        let p = try store.remember(print([1, 0, 0, 0]), as: "Kate", from: rec)
        XCTAssertEqual(p.learnedFrom, [rec])
        XCTAssertEqual(p.candidates ?? [], [])
        try store.log(["S2": .init(person: kate, score: 0.35, runnerUp: nil, accepted: false)], in: rec)
        XCTAssertEqual(store.load().first?.candidates ?? [], [], "a recording learned from is not asked about")
    }

    func testFilesWithoutTheNewFieldsStillLoad() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = Person(id: UUID(), name: "Kate", created: Date(), updated: Date(), print: print([1, 0, 0, 0]), sources: 1)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        for k in ["learnedFrom", "matches", "candidates", "dismissed"] { json.removeValue(forKey: k) }
        let file: [String: Any] = ["version": 1, "people": [json]]
        try JSONSerialization.data(withJSONObject: file).write(to: store.url)
        XCTAssertEqual(store.load().map(\.name), ["Kate"])
    }

    func testDeletingAPersonDeletesTheirBrief() throws {
        let kate = try store.remember(print([1, 0, 0, 0]), as: "Kate")
        let entry = PersonBriefStore.Entry(recordingId: UUID(), key: "k", built: Date(),
                                           brief: PersonBrief(commitments: [.init(text: "Send the deck")]))
        try store.briefs.save(entry, for: kate.id)
        XCTAssertEqual(store.briefs.entries(for: kate.id).count, 1)
        try store.delete(kate.id)
        XCTAssertTrue(store.briefs.entries(for: kate.id).isEmpty)
    }

    // MARK: Confidence

    func testTwoPeopleWhoseAveragesLookCloseAreStillToldApart() {
        // Lana and Iryna, 2026-10-23: centroids 0.54 alike, but each clip of
        // Lana's scored ~0.71 against her own voice and ~0.37 against Iryna's.
        var lana = person("Lana", [1, 0, 0, 0])
        lana.print = Voiceprint(seconds: 150, embeddings: Array(repeating: unit([1, 1, 0, 0]), count: 20)
                                + Array(repeating: unit([1, -1, 0, 0]), count: 20))
        lana.sources = 3
        let iryna = unit([0.8, 0, 1, 1])
        XCTAssertGreaterThan(VoiceActivity.cosine(lana.print.centroid, iryna), 0.45, "the averages look close")
        let c = PeopleConfidence.assess(lana, others: [(name: "Iryna", centroid: iryna)])
        XCTAssertNil(c.soundsLike, "their clips stand well apart, as the matcher sees them")
        XCTAssertEqual(c.factors.first { $0.kind == .distinct }?.grade, .good)
    }

    func testConfidenceGrowsWithTrainingAndWarnsOfACloseVoice() {
        var kate = person("Kate", [1, 0, 0, 0])
        kate.print = print([1, 0, 0, 0], count: 4, seconds: 15)
        let fresh = PeopleConfidence.assess(kate, others: [(name: "Anna", centroid: unit([0, 1, 0, 0]))])
        XCTAssertEqual(fresh.level, .learning)
        XCTAssertNil(fresh.factors.first { $0.kind == .matches }?.value, "no matches yet is not judged")
        XCTAssertNotNil(fresh.advice)

        kate.print = print([1, 0, 0, 0], count: 40, seconds: 150)
        kate.sources = 3
        kate.matches = (0..<5).map { _ in .init(recordingId: UUID(), speaker: "S1", score: 0.65, date: Date()) }
        let trained = PeopleConfidence.assess(kate, others: [(name: "Anna", centroid: unit([0, 1, 0, 0]))])
        XCTAssertEqual(trained.level, .strong)
        XCTAssertGreaterThan(trained.score, fresh.score)
        XCTAssertNil(trained.soundsLike)

        let twin = PeopleConfidence.assess(kate, others: [(name: "Anna", centroid: unit([0.95, 0.3, 0, 0]))])
        XCTAssertEqual(twin.soundsLike, "Anna")
        XCTAssertEqual(twin.level, .learning, "two voices that close are left unnamed, so never Strong")
        XCTAssertEqual(twin.heldBack?.contains("Anna"), true, "the page says why the level is lower than the number")
        XCTAssertNil(trained.heldBack)
    }

    // MARK: Learning

    func testCleanSpeechSkipsOverlapAndTrimsEdges() {
        let rate = Int(VoiceActivity.sampleRate)
        let samples = (0..<(rate * 20)).map { Float($0) }
        let regions: [DiarizationRunner.SpeakerSegment] = [
            .init(startSeconds: 0, endSeconds: 4, speakerId: "A"),
            .init(startSeconds: 3.5, endSeconds: 6, speakerId: "B"),   // overlaps A's first turn
            .init(startSeconds: 8, endSeconds: 12, speakerId: "A"),
        ]
        let speech = PeopleVoice.cleanSpeech(of: "A", regions: regions, samples: samples)
        XCTAssertEqual(speech.count, Int(3.5 * Double(rate)), "only 8.25-11.75 s")
        XCTAssertEqual(speech.first, Float(Int(8.25 * Double(rate))))
    }

    func testCleanSpeechTakesTheLongestStretchesFirst() {
        let rate = Int(VoiceActivity.sampleRate)
        let samples = [Float](repeating: 0, count: rate * 200)
        // Many 3 s turns, then one 50 s monologue near the end.
        var regions: [DiarizationRunner.SpeakerSegment] = (0..<30).map {
            .init(startSeconds: Double($0) * 4, endSeconds: Double($0) * 4 + 3, speakerId: "A")
        }
        regions.append(.init(startSeconds: 140, endSeconds: 190, speakerId: "A"))
        let speech = PeopleVoice.cleanSpeech(of: "A", regions: regions, samples: samples)
        let seconds = Double(speech.count) / Double(rate)
        XCTAssertEqual(seconds, PeopleVoice.maxLearnSeconds, accuracy: 3)
        // 49.5 s from the monologue, the rest from the short turns: before,
        // the first 60 s of short turns were taken and the monologue never.
        XCTAssertGreaterThan(seconds, 49.5)
    }

    func testSpeakingTimePerSpeaker() {
        let segs = [
            Segment(startSeconds: 0, endSeconds: 4, text: "a", speaker: "S1", speakerName: nil),
            Segment(startSeconds: 4, endSeconds: 5, text: "b", speaker: "S2", speakerName: nil),
            Segment(startSeconds: 5, endSeconds: 7.5, text: "c", speaker: "S1", speakerName: nil),
            Segment(startSeconds: 8, endSeconds: 9, text: "d", speaker: nil, speakerName: nil),
        ]
        XCTAssertEqual(PeopleVoice.speakingTime(segs), ["S1": 6.5, "S2": 1])
    }
}
