import XCTest
import SwiftData
@testable import Transcriberr

/// People review fixes: talk time as covered time, who named a speaker,
/// one speaker per person, names the user set left alone, merges keeping
/// done marks, a brief cache that survives a rename, and the microphone's
/// lines counted as the user.
@MainActor
final class PeopleFixTests: XCTestCase {
    var dir: URL!
    var store: PeopleStore!
    var container: ModelContainer!
    var repo: RecordingRepository!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("peoplefix-\(UUID().uuidString.prefix(6))")
        store = PeopleStore(url: dir.appendingPathComponent("people.json"))
        store.myVoice = { nil }   // never the real user's voice in a test
        container = try ModelContainer(for: Schema(TranscriberrSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        repo = RecordingRepository(context: container.mainContext)
        setenv("TRANSCRIBERR_BACKUP_ROOT", dir.appendingPathComponent("backups").path, 1)
        // Shared stores (unknown voices) read from here, never the real ones.
        setenv("TRANSCRIBERR_PEOPLE", dir.appendingPathComponent("people.json").path, 1)
    }

    override func tearDown() async throws {
        unsetenv("TRANSCRIBERR_BACKUP_ROOT")
        unsetenv("TRANSCRIBERR_PEOPLE")
        try? FileManager.default.removeItem(at: dir)
    }

    private func unit(_ v: [Float]) -> [Float] {
        let n = sqrt(v.map { $0 * $0 }.reduce(0, +)); return v.map { $0 / n }
    }
    private func print(_ v: [Float], count: Int = 4, seconds: Double = 20) -> Voiceprint {
        Voiceprint(seconds: seconds, embeddings: Array(repeating: unit(v), count: count))
    }
    private func person(_ name: String, _ v: [Float] = [1, 0, 0, 0]) -> Person {
        Person(id: UUID(), name: name, created: Date(), updated: Date(), print: print(v), sources: 1)
    }
    private func recording(_ title: String, _ segs: [(Double, Double, String, String?, String?)]) throws -> Recording {
        let rec = Recording(title: title, audioPath: "/tmp/\(title)-\(UUID().uuidString).wav")
        try repo.save(rec)
        try repo.appendSegments(segs.map {
            Segment(startSeconds: $0.0, endSeconds: $0.1, text: $0.2, speaker: $0.3, speakerName: $0.4)
        }, to: rec)
        return rec
    }
    private func words(_ n: Int) -> String { Array(repeating: "word", count: n).joined(separator: " ") }

    // MARK: Talk time (P1)

    func testUnionCountsOverlapOnce() {
        XCTAssertEqual(SpeechMeasure.unionSeconds([]), 0)
        XCTAssertEqual(SpeechMeasure.unionSeconds([(start: 0, end: 10), (start: 5, end: 12), (start: 20, end: 25)]), 17, accuracy: 0.001)
        XCTAssertEqual(SpeechMeasure.unionSeconds([(start: 20, end: 25), (start: 0, end: 30)]), 30, accuracy: 0.001,
                       "a line inside another adds nothing, in any order")
        XCTAssertEqual(SpeechMeasure.unionSeconds([(start: 3, end: 3), (start: 5, end: 4)]), 0, "empty and inverted lines are nothing")
    }

    func testAMeetingsTalkIsTheTimeItsLinesCoverAndCarriesWords() throws {
        _ = try recording("m", [(0, 10, "one two three", "S1", "Kate"),
                                (5, 12, "four five", "TAGGED_1", "Kate"),     // tagged over her own line
                                (20, 25, "six", "S1", "Kate"),
                                (25, 40, "not hers at all", "S2", "Anna")])
        let m = try XCTUnwrap(PersonMeetings.load("Kate", repository: repo).first)
        XCTAssertEqual(m.seconds, 17, accuracy: 0.001, "0-12 and 20-25, not 10 + 7 + 5")
        XCTAssertEqual(m.words, 6)
        XCTAssertEqual(m.lines, 3)
        XCTAssertEqual(PersonMeetings.talk(seconds: m.seconds, words: m.words), "~17 s · 6 words")
        XCTAssertEqual(PersonMeetings.talk(seconds: 125, words: 1), "~2 min · 1 word")
        XCTAssertEqual(PersonMeetings.talk([m, m]), "~34 s · 12 words")
    }

    func testMeasuredTalkCountsOverlappingLinesOnce() throws {
        let lines = [SpeechLine(start: 0, end: 20, speaker: "Kate", text: words(20)),
                     SpeechLine(start: 10, end: 30, speaker: "Kate", text: words(20)),
                     SpeechLine(start: 30, end: 40, speaker: "Anna", text: words(20))]
        let m = try XCTUnwrap(SpeechMeasure.measure(lines, name: "Kate", recordingId: UUID(), title: "t", date: Date()))
        XCTAssertEqual(m.talkSeconds, 30, accuracy: 0.001)
    }

    // MARK: Provenance (P3)

    func testProvenanceOfASpeaker() {
        var p = person("Kate")
        let rec = UUID()
        XCTAssertEqual(p.provenance(of: "S1", in: rec), .typed, "no record of a match: named by hand")
        XCTAssertEqual(p.provenance(of: "TAGGED_1", in: rec), .typed)
        p.invited = [Person.Hearing.key(rec, "S2")]
        XCTAssertEqual(p.provenance(of: "S2", in: rec), .invite)
        p.matches = [Person.Hearing(recordingId: rec, speaker: "S3", score: 0.61, date: Date())]
        XCTAssertEqual(p.provenance(of: "S3", in: rec), .auto(score: 0.61))
        p.autoNamed = [Person.Hearing.key(rec, "S4")]
        XCTAssertEqual(p.provenance(of: "S4", in: rec), .auto(score: nil), "named by a match that has aged out of the log")
        p.settled = [Person.Hearing.key(rec, "S3")]
        XCTAssertEqual(p.provenance(of: "S3", in: rec), .confirmed, "a Yes outranks the match")
        XCTAssertEqual(p.provenance(of: "S3", in: UUID()), .typed, "per recording")
        XCTAssertEqual(p.provenance(in: rec, keys: ["S2", "S4"]), .auto(score: nil), "a meeting reads as its strongest")
        XCTAssertEqual(p.provenance(in: rec, keys: ["S2", "S1"]), .typed)
        XCTAssertTrue(Provenance.confirmed.isConfirmed)
        XCTAssertTrue(Provenance.typed.isConfirmed)
        XCTAssertFalse(Provenance.auto(score: 0.6).isConfirmed)
        XCTAssertFalse(Provenance.invite.isConfirmed)
        XCTAssertEqual(Provenance.auto(score: 0.612).tag, "auto 0.61")
        XCTAssertNil(Provenance.typed.tag)
    }

    func testNamingProvenanceIsKeptAndMovesBetweenKinds() throws {
        let k = try store.remember(print([1, 0, 0, 0]), as: "Kate")
        let rec = UUID()
        let h = Person.Hearing.key(rec, "S1")
        try store.noteNamed([(hearing: h, person: k.id, invited: true)])
        var p = try XCTUnwrap(store.load().first)
        XCTAssertEqual(p.provenance(of: "S1", in: rec), .invite)
        try store.noteNamed([(hearing: h, person: k.id, invited: false)])
        p = try XCTUnwrap(store.load().first)
        XCTAssertEqual(p.provenance(of: "S1", in: rec), .auto(score: nil))
        XCTAssertEqual(p.invited, [], "named by voice now, not by the invite")
    }

    func testOldFilesWithoutProvenanceStillDecode() throws {
        let k = try store.remember(print([1, 0, 0, 0]), as: "Kate")
        let json = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(json.contains("autoNamed"), "nil optionals are not written: older files look the same")
        XCTAssertFalse(json.contains("invited"))
        XCTAssertEqual(store.load().first?.id, k.id)
        XCTAssertNil(store.load().first?.invited)
    }

    // MARK: Naming plan (P4, P5)

    private func hit(_ p: Person, _ score: Float, accepted: Bool = true) -> PeopleMatch.Assessment {
        PeopleMatch.Assessment(person: p, score: score, runnerUp: nil, accepted: accepted)
    }

    func testAMatchNeverRenamesASpeakerCarryingAnotherSavedName() {
        let kate = person("Kate")
        let plan = PeopleMatch.plan(["S1": hit(kate, 0.7), "S2": hit(kate, 0.6)],
                                    names: ["S1": "Anna", "S2": nil])
        XCTAssertNil(plan.rename["S1"], "the user's (or an earlier) Anna stays Anna")
        XCTAssertEqual(plan.found["S1"]?.accepted, false, "asked about on Kate's page instead")
        XCTAssertEqual(plan.found["S1"]?.isNearMiss, true)
        XCTAssertEqual(plan.rename["S2"], kate.id)
    }

    func testOneSpeakerPerPersonTheBestScoreWins() {
        let kate = person("Kate"), anna = person("Anna")
        let plan = PeopleMatch.plan(["S1": hit(kate, 0.6), "S2": hit(kate, 0.7), "S3": hit(anna, 0.65)],
                                    names: ["S1": nil, "S2": nil, "S3": nil])
        XCTAssertEqual(plan.rename, ["S2": kate.id, "S3": anna.id])
        XCTAssertEqual(plan.found["S1"]?.accepted, false)
        XCTAssertEqual(plan.found["S2"]?.accepted, true)
        let tie = PeopleMatch.plan(["S2": hit(kate, 0.6), "S1": hit(kate, 0.6)], names: [:])
        XCTAssertEqual(tie.rename, ["S1": kate.id], "a tie goes to the lower key, every time")
    }

    func testTheSpeakerAlreadyNamedKeepsThePerson() {
        let kate = person("Kate")
        let plan = PeopleMatch.plan(["S1": hit(kate, 0.6), "S2": hit(kate, 0.8)],
                                    names: ["S1": "Kate", "S2": nil])
        XCTAssertTrue(plan.rename.isEmpty, "a second Kate would fold two speakers into one")
        XCTAssertEqual(plan.found["S1"]?.accepted, true, "still a match in her track record")
        XCTAssertEqual(plan.found["S2"]?.accepted, false)
        // Hand-tagged lines are not a speaker: the diarized match takes the name.
        let tagged = PeopleMatch.plan(["S2": hit(kate, 0.8)], names: ["TAGGED_1": "Kate", "S2": nil])
        XCTAssertEqual(tagged.rename, ["S2": kate.id])
    }

    func testAMatchFixesTheCaseOfItsOwnName() {
        let kate = person("Kate")
        let plan = PeopleMatch.plan(["S1": hit(kate, 0.6)], names: ["S1": "kate"])
        XCTAssertEqual(plan.rename, ["S1": kate.id])
        let same = PeopleMatch.plan(["S1": hit(kate, 0.6)], names: ["S1": "Kate"])
        XCTAssertTrue(same.rename.isEmpty)
        let near = PeopleMatch.plan(["S1": hit(kate, 0.45, accepted: false)], names: ["S1": nil])
        XCTAssertTrue(near.rename.isEmpty, "a near miss names nobody")
        XCTAssertEqual(near.found["S1"]?.accepted, false)
    }

    // MARK: Merge (P8, U2)

    func testMergeKeepsDoneMarksAndBriefs() throws {
        let rec = UUID()
        let k = try store.remember(print([1, 0, 0, 0], count: 4), as: "Kate", from: UUID())
        var k2 = try store.remember(print([0.9, 0.1, 0, 0], count: 2), as: "Katherine", from: rec)
        let entry = PersonBriefStore.Entry(recordingId: rec, key: "k", built: Date(),
                                           brief: PersonBrief(commitments: [.init(text: "Send the deck")]))
        try store.briefs.save(entry, for: k2.id)
        let done = PersonBriefStore.itemKey(rec, "commitment", "Send the deck")
        try store.briefs.setClosed(done, true, for: k2.id)
        try store.noteNamed([(hearing: Person.Hearing.key(rec, "S1"), person: k2.id, invited: true)])
        k2 = try XCTUnwrap(store.load().first { $0.id == k2.id })
        try store.merge(k2.id, into: k.id)
        XCTAssertTrue(store.briefs.closed(for: k.id).contains(done), "done stays done after a merge")
        XCTAssertTrue(store.briefs.closed(for: k2.id).isEmpty)
        let moved = store.briefs.entries(for: k.id)
        XCTAssertEqual(moved.map(\.recordingId), [rec])
        XCTAssertEqual(moved.first?.key, "k", "kept: the key masks the name, so no re-read after a merge")
        XCTAssertTrue(store.briefs.entries(for: k2.id).isEmpty)
        let p = try XCTUnwrap(store.load().first)
        XCTAssertEqual(p.provenance(of: "S1", in: rec), .invite, "provenance joins too")
    }

    func testMergeOfDifferentVoicesNeedsForce() throws {
        let k = try store.remember(print([1, 0, 0, 0]), as: "Kate", from: UUID())
        let a = try store.remember(print([0, 1, 0, 0]), as: "Anna", from: UUID())
        XCTAssertThrowsError(try store.merge(a.id, into: k.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("sound"), error.localizedDescription)
        }
        XCTAssertEqual(store.load().count, 2)
        XCTAssertEqual(try store.merge(a.id, into: k.id, force: true), "Anna")
        let people = store.load()
        XCTAssertEqual(people.map(\.name), ["Kate"])
        XCTAssertEqual(people.first?.allSamples.count, 2)
    }

    // MARK: Improve keeps speakers (P9)

    func testAReplacedVoiceKeepsItsSpeakers() throws {
        let k = try store.remember(print([1, 0, 0, 0], count: 10), as: "Kate", from: UUID())
        let a = UUID()
        try store.replaceVoice(of: k.id, samples: [
            (recordingId: a, earlier: nil, date: Date(), print: print([0.95, 0.1, 0, 0], count: 10), speakers: "S1,TAGGED_1"),
            (recordingId: nil, earlier: nil, date: Date(), print: print([1, 0, 0, 0], count: 10), speakers: nil),
        ])
        let p = try XCTUnwrap(store.load().first)
        XCTAssertEqual(p.allSamples.first?.speakers, "S1,TAGGED_1")
        XCTAssertEqual(PeopleStore.rebuildSources(p).first?.speakers, "S1,TAGGED_1",
                       "a voice model switch rebuilds from the same speakers")
    }

    // MARK: Brief cache (U5)

    func testTheBriefCacheKeySurvivesARename() {
        let before = "[00:01] Anna: Kate, the deck?\n[00:05] Kate: Friday."
        let after = "[00:01] Anna: Kate, the deck?\n[00:05] Katie: Friday."
        XCTAssertEqual(PersonBriefBuilder.key(transcript: before, name: "Kate"),
                       PersonBriefBuilder.key(transcript: after, name: "Katie"))
        XCTAssertEqual(PersonBriefBuilder.key(transcript: before, name: "Kate"),
                       PersonBriefBuilder.key(transcript: before.replacingOccurrences(of: "] Kate:", with: "] kate:"), name: "Kate"),
                       "the label in any case")
        XCTAssertNotEqual(PersonBriefBuilder.key(transcript: before, name: "Kate"),
                          PersonBriefBuilder.key(transcript: before.replacingOccurrences(of: "Friday", with: "Monday"), name: "Kate"),
                          "what they said still counts")
        XCTAssertNotEqual(PersonBriefBuilder.key(transcript: before, name: "Kate"),
                          PersonBriefBuilder.key(transcript: before.replacingOccurrences(of: "Anna:", with: "Lana:"), name: "Kate"),
                          "so do the others, and their names")
        XCTAssertEqual(PersonBriefBuilder.anonymized(before, name: "Kate"),
                       "[00:01] Anna: Kate, the deck?\n[00:05] \u{1}: Friday.", "only their own label goes")
        XCTAssertNotEqual(PersonBriefBuilder.legacyKey(transcript: before, name: "Kate"),
                          PersonBriefBuilder.key(transcript: before, name: "Kate"))
        XCTAssertEqual(PersonBriefBuilder.legacyKey(transcript: before, name: "Kate"),
                       PersonBriefBuilder.legacyKey(transcript: before, name: "Kate"), "older caches still recognised")
    }

    // MARK: Done list (U3)

    func testDoneItemsAreListedForUndo() throws {
        let m = PersonMeeting(id: UUID(), title: "M", date: Date(), seconds: 60, lines: 2, firstLine: 0, keys: ["S1"], lastSaid: "")
        let e = PersonBriefStore.Entry(recordingId: m.id, key: "", built: Date(), brief: PersonBrief(
            commitments: [.init(text: "Send the deck"), .init(text: "Call Anna")], questions: [.init(text: "Who pays?")]))
        let id = UUID()
        try store.briefs.save(e, for: id)
        let open = PersonBriefView.combine(store.briefs.entries(for: id), meetings: [m])
        let deck = try XCTUnwrap(open.commitments.first)
        let question = try XCTUnwrap(open.questions.first)
        try store.briefs.setClosed(deck.id, true, for: id)
        try store.briefs.setClosed(question.id, true, for: id)
        var v = PersonBriefView.combine(store.briefs.entries(for: id), meetings: [m], closed: store.briefs.closed(for: id))
        XCTAssertEqual(v.closedRows.map(\.item.text), ["Send the deck", "Who pays?"])
        XCTAssertEqual(v.closedCount, 2)
        try store.briefs.setClosed(deck.id, false, for: id)   // Undo
        v = PersonBriefView.combine(store.briefs.entries(for: id), meetings: [m], closed: store.briefs.closed(for: id))
        XCTAssertEqual(v.commitments.map(\.item.text), ["Send the deck", "Call Anna"])
        XCTAssertEqual(v.closedRows.map(\.item.text), ["Who pays?"])
    }

    // MARK: The user on the microphone track (P6, P7)

    func testMicrophoneLinesAreTheUser() {
        func who(_ key: String?, _ name: String?, micIsThem: Bool = false, micAs: String? = "Yuri") -> String? {
            SpeechHistory.speaker(key: key, name: name, measuring: "Kate", micIsThem: micIsThem, micAs: micAs)
        }
        XCTAssertEqual(who("ME", "Me"), "Yuri", "an old mic line named Me is the user")
        XCTAssertEqual(who("ME", "Yura"), "Yuri", "so is one under an older name")
        XCTAssertEqual(who("ME", nil), "Yuri")
        XCTAssertEqual(who("ME", "kate"), "kate", "a mic line carrying their name stays theirs")
        XCTAssertEqual(who("S1", "Anna"), "Anna")
        XCTAssertEqual(who("S1", ""), "S1")
        XCTAssertNil(who(nil, nil))
        XCTAssertEqual(who("ME", "Me", micIsThem: true), "Kate", "the You page measures the mic as the user")
        XCTAssertEqual(who("ME", "Me", micAs: nil), "Me", "without micAs a line keeps its name")
    }

    func testInMeetingsWithYouCountsTheMicrophone() throws {
        // Recorded before the user set their name: the mic lines say "Me".
        _ = try recording("call", [(0, 30, words(60), "ME", "Me"), (30, 60, words(40), "S1", "Kate"),
                                   (60, 70, words(10), "S2", "Anna")])
        let speech = SpeechHistory.load("Kate", repository: repo, micAs: "Yuri").meetings
        XCTAssertEqual(speech.count, 1)
        let t = try XCTUnwrap(PersonPage.together(speech, me: "Yuri"))
        XCTAssertEqual(t.you, 60, accuracy: 0.001)
        XCTAssertEqual(t.them, 40, accuracy: 0.001)
        XCTAssertEqual(t.rest, 10, accuracy: 0.001)
        XCTAssertNil(PersonPage.together(SpeechHistory.load("Kate", repository: repo).meetings, me: "Yuri"),
                     "matched by the current name only, the meeting was missed")
    }

    func testMeetingsTogetherAreOnlyTheOnesWithTheUser() throws {
        let a = try recording("mic", [(0, 5, "hi", "ME", "Me"), (5, 9, "hello", "S1", "Kate")])
        let b = try recording("without", [(0, 5, "hi", "S1", "Kate"), (5, 9, "yo", "S2", "Anna")])
        let c = try recording("imported", [(0, 5, "hi", "S1", "yuri"), (5, 9, "hello", "S2", "Kate")])
        let kate = person("Kate")
        let data = PeopleOverviewData.load(people: [(id: kate.id, name: kate.name, centroid: kate.print.centroid)],
                                           me: "Yuri", repository: repo)
        XCTAssertEqual(data.withMe, [a.id, c.id])
        XCTAssertEqual(Set(data.meetings[kate.id]?.map(\.id) ?? []), [a.id, b.id, c.id])
    }

    // MARK: Row confidence cache (S1)

    func testRowConfidenceIsComputedOncePerChange() {
        let cache = ConfidenceCache()
        var kate = person("Kate"), anna = person("Anna", [0, 1, 0, 0])
        var computed = 0
        func value() -> VoiceConfidence {
            cache.value(for: kate, people: [kate, anna], mine: nil) {
                computed += 1
                return PeopleConfidence.assess(kate, others: [(name: anna.name, centroid: anna.print.centroid)])
            }
        }
        _ = value(); _ = value()
        XCTAssertEqual(computed, 1, "a keystroke in Search reuses it")
        anna.name = "Ann"
        _ = value()
        XCTAssertEqual(computed, 2, "another person renamed: their name is in the detail")
        kate.matches = [Person.Hearing(recordingId: UUID(), speaker: "S1", score: 0.6, date: Date())]
        _ = value()
        XCTAssertEqual(computed, 3, "a new match moves the track record")
        _ = value()
        XCTAssertEqual(computed, 3)
    }
}
