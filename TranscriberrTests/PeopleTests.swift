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
        let p = try store.remember(print([0, 1, 0, 0], count: 100), as: "Kate")
        XCTAssertEqual(p.print.embeddings.count, Person.maxEmbeddings)
        XCTAssertEqual(p.print.embeddings.last, unit([0, 1, 0, 0]), "the newest are kept")
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
