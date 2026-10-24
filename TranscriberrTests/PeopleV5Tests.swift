import XCTest
import SwiftData
@testable import Transcriberr

/// People 5.0.0: voice samples, merge and rename, the stored file's other
/// models, and names carried through the library.
@MainActor
final class PeopleV5Tests: XCTestCase {
    var dir: URL!
    var store: PeopleStore!
    var container: ModelContainer!
    var repo: RecordingRepository!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("people5-\(UUID().uuidString.prefix(6))")
        store = PeopleStore(url: dir.appendingPathComponent("people.json"))
        store.myVoice = { nil }   // never the real user's voice in a test
        container = try ModelContainer(for: Schema(TranscriberrSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        repo = RecordingRepository(context: container.mainContext)
        setenv("TRANSCRIBERR_BACKUP_ROOT", dir.appendingPathComponent("backups").path, 1)
    }

    override func tearDown() async throws {
        unsetenv("TRANSCRIBERR_BACKUP_ROOT")
        try? FileManager.default.removeItem(at: dir)
    }

    private func unit(_ v: [Float]) -> [Float] {
        let n = sqrt(v.map { $0 * $0 }.reduce(0, +)); return v.map { $0 / n }
    }
    private func print(_ v: [Float], count: Int = 4, seconds: Double = 20) -> Voiceprint {
        Voiceprint(seconds: seconds, embeddings: Array(repeating: unit(v), count: count))
    }

    // MARK: Samples

    func testEachLearningIsASampleAndCanBeForgotten() throws {
        let a = UUID(), b = UUID()
        try store.remember(print([1, 0, 0, 0], count: 4, seconds: 20), as: "Kate", from: a)
        var p = try store.remember(print([0.9, 0.1, 0, 0], count: 3, seconds: 12), as: "Kate", from: b)
        XCTAssertEqual(p.allSamples.map(\.recordingId), [a, b])
        XCTAssertEqual(p.allSamples.map(\.count), [4, 3])
        try store.forget(sample: p.allSamples[0].id, of: p.id)
        p = try XCTUnwrap(store.load().first)
        XCTAssertEqual(p.print.embeddings.count, 3)
        XCTAssertEqual(p.print.seconds, 12, accuracy: 0.001)
        XCTAssertEqual(p.learnedFrom, [b], "the forgotten recording can be learned from again")
        XCTAssertEqual(p.triedFrom, [a], "a forgotten recording is not offered for learning again")
        XCTAssertThrowsError(try store.forget(sample: p.allSamples[0].id, of: p.id), "never the last sample")
    }

    func testTheCapKeepsEverySampleInProportion() throws {
        try store.remember(print([1, 0, 0, 0], count: 100, seconds: 100), as: "Kate", from: UUID())
        let p = try store.remember(print([1, 0.3, 0, 0], count: 100, seconds: 100), as: "Kate", from: UUID())
        XCTAssertEqual(p.print.embeddings.count, Person.maxEmbeddings)
        XCTAssertEqual(p.allSamples.map(\.count), [60, 60], "both microphones stay represented")
        XCTAssertEqual(p.allSamples.map(\.count).reduce(0, +), p.print.embeddings.count)
        XCTAssertEqual(p.print.seconds, 120, accuracy: 0.001)
        let small = try store.remember(print([1, 0, 0.3, 0], count: 4, seconds: 4), as: "Kate", from: UUID())
        XCTAssertEqual(small.allSamples.last?.count, 4, "a short sample is kept whole")
        XCTAssertEqual(small.print.embeddings.count, Person.maxEmbeddings)
        XCTAssertEqual(small.allSamples.map(\.count).reduce(0, +), small.print.embeddings.count)
    }

    func testANewPersonIsCappedToo() throws {
        let p = try store.remember(print([1, 0, 0, 0], count: 155, seconds: 232), as: "Maria")
        XCTAssertEqual(p.print.embeddings.count, Person.maxEmbeddings)
    }

    func testOlderFilesBecomeOneEarlierSample() {
        let p = Person(id: UUID(), name: "Kate", created: Date(), updated: Date(), print: print([1, 0, 0, 0]), sources: 2)
        XCTAssertEqual(p.allSamples.count, 1)
        XCTAssertEqual(p.allSamples.first?.earlier, true)
        XCTAssertEqual(p.allSamples.first?.id, Person.earlierSampleId(p.id), "stable, so it can be forgotten by id")
    }

    func testALegacyPersonKeepsTheirCutoffAfterTheFirstNewSample() throws {
        let trained = Date(timeIntervalSince1970: 1_000_000)
        var p = Person(id: UUID(), name: "Kate", created: trained, updated: trained, print: print([1, 0, 0, 0]), sources: 2)
        p.add(print([1, 0, 0, 0]), from: UUID(), now: Date())
        XCTAssertEqual(p.legacyCutoff, trained)
        XCTAssertEqual(p.allSamples.first?.earlier, true)
        XCTAssertEqual(p.allSamples.count, 2)
    }

    func testMergeKeepsAnEarlierSampleEarlier() throws {
        let legacy = Person(id: UUID(), name: "Old Kate", created: Date(), updated: Date(), print: print([1, 0, 0, 0]), sources: 1)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        struct File: Encodable { var version = 1; var people: [Person] }
        let k = Person(id: UUID(), name: "Kate", created: Date(), updated: Date(), print: print([1, 0, 0, 0]), sources: 1)
        try JSONEncoder().encode(File(people: [legacy, k])).write(to: store.url)
        try store.merge(legacy.id, into: k.id)
        let merged = try XCTUnwrap(store.load().first)
        XCTAssertEqual(merged.allSamples.filter { $0.earlier == true }.count, 2)
    }

    func testTheOddSampleIsTheOneUnlikeTheRest() throws {
        try store.remember(print([1, 0, 0, 0]), as: "Kate", from: UUID())
        try store.remember(print([0.95, 0.1, 0, 0]), as: "Kate", from: UUID())
        let p = try store.remember(print([0.6, 0, 0.8, 0]), as: "Kate", from: UUID())
        XCTAssertEqual(p.oddSample, p.allSamples.last?.id, "accepted (0.6) but the least like the rest")
    }

    func testAddByIdNeverRecreatesADeletedPerson() throws {
        let k = try store.remember(print([1, 0, 0, 0]), as: "Kate")
        try store.delete(k.id)
        XCTAssertThrowsError(try store.add(print([1, 0, 0, 0]), to: k.id, from: UUID()))
        XCTAssertTrue(store.load().isEmpty)
    }

    // MARK: One person, for sure

    func testADifferentVoiceIsNeverAddedToAPerson() throws {
        let k = try store.remember(print([1, 0, 0, 0]), as: "Kate", from: UUID())
        XCTAssertThrowsError(try store.remember(print([0.3, 1, 0, 0]), as: "Kate", from: UUID())) { e in
            guard case PeopleStore.PeopleError.notSamePerson = e else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try store.add(print([0, 0, 1, 0]), to: k.id, from: UUID()))
        let after = try XCTUnwrap(store.load().first)
        XCTAssertEqual(after.print.embeddings.count, 4, "the voice is untouched")
        XCTAssertEqual(after.sources, 1)
    }

    func testASampleCloserToSomeoneElseIsRefused() throws {
        let kate = try store.remember(print([1, 0, 0, 0]), as: "Kate")
        try store.remember(print([0.6, 0.8, 0, 0]), as: "Anna")
        // 0.66 like Kate, but 0.93 like Anna: not Kate's, however close.
        XCTAssertThrowsError(try store.add(print([0.5, 0.75, 0, 0]), to: kate.id, from: UUID())) { e in
            XCTAssertTrue(e.localizedDescription.contains("Anna"), e.localizedDescription)
        }
    }

    func testTheUserIsNeverFiledUnderSomeoneElse() throws {
        store.myVoice = { [0, 0, 1, 0] }
        let kate = try store.remember(print([0.7, 0, 0.7, 0]), as: "Kate")
        XCTAssertThrowsError(try store.add(print([0.2, 0, 0.98, 0]), to: kate.id, from: UUID()),
                             "0.83 like Kate but 0.98 like the user: refused")
    }

    func testMergeRefusesTwoDifferentVoices() throws {
        let k = try store.remember(print([1, 0, 0, 0]), as: "Kate")
        let a = try store.remember(print([0, 1, 0, 0]), as: "Anna")
        XCTAssertThrowsError(try store.merge(a.id, into: k.id))
        XCTAssertEqual(store.load().count, 2, "nobody merged, nobody lost")
    }

    func testANewPersonNeedsRecordingsThatAgree() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let r = VoiceGate.consistent([
            (a, print([1, 0, 0, 0])), (b, print([0.95, 0.2, 0, 0])), (c, print([0.9, 0, 0.3, 0])),
            (d, print([0, 0, 0, 1])),                       // someone else, under the same name
        ], others: [])
        XCTAssertEqual(Set(r.kept), [a, b, c])
        XCTAssertEqual(r.rejected, [d])
        let none = VoiceGate.consistent([(a, print([1, 0, 0, 0])), (b, print([0, 1, 0, 0]))], others: [])
        XCTAssertTrue(none.kept.isEmpty, "two that disagree: neither is trusted")
        let lone = VoiceGate.consistent([(a, print([1, 0, 0, 0]))], others: [("Kate", unit([1, 0, 0, 0]))])
        XCTAssertTrue(lone.kept.isEmpty, "a single sample that sounds like someone saved")
    }

    func testAReplacedVoiceKeepsItsSourcesAndTheCap() throws {
        let k = try store.remember(print([1, 0, 0, 0], count: 10), as: "Kate", from: UUID())
        let a = UUID(), b = UUID()
        try store.replaceVoice(of: k.id, with: [
            (nil, nil, Date(), print([1, 0, 0, 0], count: 80, seconds: 30)),     // a reading
            (a, nil, Date(), print([0.95, 0.1, 0, 0], count: 80, seconds: 60)),
            (b, nil, Date(), print([0.95, 0, 0.1, 0], count: 80, seconds: 60)),
        ])
        let p = try XCTUnwrap(store.load().first)
        XCTAssertEqual(p.print.embeddings.count, Person.maxEmbeddings)
        XCTAssertEqual(p.allSamples.map(\.count), [40, 40, 40], "every source kept, in proportion")
        XCTAssertEqual(p.sources, 3)
        XCTAssertTrue(Set(p.learnedFrom ?? []).isSuperset(of: [a, b]))
    }

    // MARK: The file keeps everyone

    func testPeopleOfAnotherModelSurviveWrites() throws {
        let other = Person(id: UUID(), name: "Old", created: Date(), updated: Date(),
                           print: Voiceprint(model: "some_older_model", seconds: 10, embeddings: [unit([1, 0])]),
                           sources: 1)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        struct File: Encodable { var version = 1; var people: [Person] }
        try JSONEncoder().encode(File(people: [other])).write(to: store.url)
        XCTAssertTrue(store.load().isEmpty, "not comparable, so not shown or matched")
        try store.remember(print([1, 0, 0, 0]), as: "Kate")
        try store.log([:], in: UUID())
        let raw = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertTrue(raw.contains("some_older_model"), "a write must not drop people of another model")
    }

    // MARK: Rename, merge

    func testRenameRefusesATakenName() throws {
        let k = try store.remember(print([1, 0, 0, 0]), as: "Kate")
        try store.remember(print([0, 1, 0, 0]), as: "Anna")
        XCTAssertThrowsError(try store.rename(k.id, to: "anna"))
        XCTAssertEqual(try store.rename(k.id, to: "Katie"), "Kate")
    }

    func testMergeJoinsVoicesAndHistory() throws {
        let rec = UUID()
        let k = try store.remember(print([1, 0, 0, 0], count: 4), as: "Kate", from: UUID())
        let k2 = try store.remember(print([0.9, 0.1, 0, 0], count: 2), as: "Katherine", from: rec)
        try store.log(["S1": .init(person: k2, score: 0.6, runnerUp: nil, accepted: true)], in: UUID())
        try store.briefs.save(.init(recordingId: rec, key: "k", built: Date(), brief: PersonBrief()), for: k2.id)
        XCTAssertEqual(try store.merge(k2.id, into: k.id), "Katherine")
        let people = store.load()
        XCTAssertEqual(people.map(\.name), ["Kate"])
        let p = try XCTUnwrap(people.first)
        XCTAssertEqual(p.print.embeddings.count, 6)
        XCTAssertEqual(p.allSamples.count, 2)
        XCTAssertEqual(p.sources, 2)
        XCTAssertTrue(p.learnedFrom?.contains(rec) == true)
        XCTAssertEqual(p.matches?.count, 1)
        XCTAssertTrue(store.briefs.entries(for: k2.id).isEmpty)
    }

    func testAYesIsNotAskedAgain() throws {
        let k = try store.remember(print([1, 0, 0, 0]), as: "Kate")
        let rec = UUID()
        let near = PeopleMatch.Assessment(person: k, score: 0.35, runnerUp: nil, accepted: false)
        try store.log(["S2": near], in: rec)
        let h = try XCTUnwrap(store.load().first?.candidates?.first)
        try store.resolve(h, for: k.id, wasThem: true)
        try store.log(["S2": near], in: rec)
        XCTAssertEqual(store.load().first?.candidates ?? [], [])
    }

    // MARK: Library

    private func recording(_ title: String, _ segs: [(Double, Double, String, String?, String?)]) throws -> Recording {
        let rec = Recording(title: title, audioPath: "/tmp/\(title)-\(UUID().uuidString).wav")
        try repo.save(rec)
        try repo.appendSegments(segs.map {
            Segment(startSeconds: $0.0, endSeconds: $0.1, text: $0.2, speaker: $0.3, speakerName: $0.4)
        }, to: rec)
        return rec
    }

    func testRenameReachesEveryRecordingInAnyCase() throws {
        let a = try recording("a", [(0, 5, "hi", "S1", "Kate"), (5, 9, "yo", "S2", "Anna")])
        let b = try recording("b", [(0, 5, "hey", "S3", "kate")])
        try repo.setSpeakerName("Kate", for: "S1", in: a)   // the map a re-run applies names from
        let touched = try repo.renameSpeakerEverywhere("Kate", to: "Katie")
        XCTAssertEqual(Set(touched.map(\.id)), [a.id, b.id])
        XCTAssertEqual(a.segments.first { $0.speaker == "S1" }?.speakerName, "Katie")
        XCTAssertEqual(a.segments.first { $0.speaker == "S2" }?.speakerName, "Anna")
        XCTAssertEqual(b.segments.first?.speakerName, "Katie")
        XCTAssertEqual(repo.storedSpeakerNames(a)["S1"], "Katie")
    }

    func testRenameAlsoReachesVersionsOfRecordingsRunAgain() throws {
        let a = try recording("a", [(0, 5, "hi", "S1", "Kate")])
        try repo.snapshotVersion(of: a, engineId: "x", engineLabel: "X")
        // Re-run: the current transcript no longer names Kate.
        try repo.setSpeakerName("Someone", for: "S1", in: a)
        try repo.renameSpeakerEverywhere("Kate", to: "Katie")
        let json = try XCTUnwrap(a.versions.first?.segmentsJSON)
        XCTAssertTrue(json.contains("Katie"))
        XCTAssertFalse(json.contains("\"Kate\""))
    }

    func testSpeakersWithTheSameNameAreOnePerson() throws {
        // Lines tagged "Alex" first, the diarized speaker named Alex after:
        // two chips for one man, and his voice could not be learned as one.
        let r = try recording("m", [(0, 5, "hi", "ME", "Yuri"), (5, 9, "a", "SPEAKER_01", nil),
                                    (9, 12, "b", "TAGGED_1", "Alex"), (12, 15, "c", "SPEAKER_01", nil)])
        try repo.setSpeakerName("Alex", for: "SPEAKER_01", in: r)
        let keys = Set(r.segments.filter { $0.speakerName == "Alex" }.compactMap(\.speaker))
        XCTAssertEqual(keys, ["SPEAKER_01"], "the tagged lines joined the diarized speaker")
        XCTAssertEqual(r.segments.filter { $0.speakerName == "Alex" }.count, 3)
        XCTAssertEqual(r.segments.first { $0.speaker == "ME" }?.speakerName, "Yuri")
    }

    func testMeetingsOfAPersonNewestFirst() throws {
        let old = try recording("old", [(0, 10, "one", "S1", "Kate"), (10, 30, "two", "S2", "Anna")])
        old.createdAtMillis = 1_000
        _ = try recording("new", [(0, 4, "a", "S1", "kate"), (6, 8, "b", "S1", "Kate")])
        let m = PersonMeetings.load("Kate", repository: repo)
        XCTAssertEqual(m.map(\.title), ["new", "old"])
        XCTAssertEqual(m.first?.seconds ?? 0, 6, accuracy: 0.001)
        XCTAssertEqual(m.first?.lines, 2)
        XCTAssertEqual(m.first?.lastSaid, "b")
    }

    // MARK: Brief store

    func testClosedItemsAreCountedNotShown() throws {
        let m = PersonMeeting(id: UUID(), title: "M", date: Date(), seconds: 60, lines: 2, firstLine: 0, keys: ["S1"], lastSaid: "")
        let e = PersonBriefStore.Entry(recordingId: m.id, key: "", built: Date(), brief: PersonBrief(
            commitments: [.init(text: "Send the deck"), .init(text: "Call Anna")]))
        let id = UUID()
        try store.briefs.save(e, for: id)
        let first = PersonBriefView.combine(store.briefs.entries(for: id), meetings: [m])
        try store.briefs.setClosed(try XCTUnwrap(first.commitments.first).id, true, for: id)
        let v = PersonBriefView.combine(store.briefs.entries(for: id), meetings: [m], closed: store.briefs.closed(for: id))
        XCTAssertEqual(v.commitments.map(\.item.text), ["Call Anna"])
        XCTAssertEqual(v.closedCount, 1)
        XCTAssertEqual(first.commitments.map(\.id), PersonBriefView.combine([e], meetings: [m]).commitments.map(\.id),
                       "row ids are stable across combines")
        store.briefs.keep(only: [], for: id)
        XCTAssertTrue(store.briefs.entries(for: id).isEmpty, "a deleted recording's brief goes")
    }

    func testPartialBriefIsMarkedIncompleteAndTimeoutsRethrow() async throws {
        let transcript = (0..<400).map { "[00:\(String(format: "%02d", $0 % 60))] Kate: line \($0) " + String(repeating: "word ", count: 20) }
            .joined(separator: "\n")
        XCTAssertGreaterThan(MeetingBriefBuilder.sections(transcript).count, 1)
        struct Boom: Error {}
        var n = 0
        let r = try await PersonBriefBuilder.build(transcript: transcript, name: "Kate", lineStarts: []) { _, _, _ in
            n += 1
            if n == 1 { return "COMMIT: Send it" }
            throw Boom()
        }
        XCTAssertFalse(r.complete)
        XCTAssertEqual(r.brief.commitments.count, 1)
        n = 0
        do {
            _ = try await PersonBriefBuilder.build(transcript: transcript, name: "Kate", lineStarts: []) { _, _, _ in
                n += 1
                if n == 1 { return "COMMIT: Send it" }
                throw ASRError.chunkTimeout
            }
            XCTFail("a timeout after a good section still throws")
        } catch ASRError.chunkTimeout {}
    }

    func testBoundedTimesOutAndGivesWayToCancel() async throws {
        do {
            _ = try await PersonBriefBuilder.bounded(seconds: 0.1) { try await Task.sleep(nanoseconds: 5_000_000_000); return 1 }
            XCTFail("should time out")
        } catch ASRError.chunkTimeout {}
        let v = try await PersonBriefBuilder.bounded(seconds: 5) { 7 }
        XCTAssertEqual(v, 7)
        let t0 = Date()
        let task = Task { try await PersonBriefBuilder.bounded(seconds: 30) { try await Task.sleep(nanoseconds: 10_000_000_000); return 1 } }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled") } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2, "Stop ends the wait at once")
    }

    // MARK: - Speaker labels in a meeting

    func testSpeakerLabelDisplay() {
        XCTAssertEqual(SpeakerLabel.display(nil, key: "SPEAKER_01"), "Speaker 2")
        XCTAssertEqual(SpeakerLabel.display("SPEAKER_00", key: "SPEAKER_00"), "Speaker 1")
        XCTAssertEqual(SpeakerLabel.display("", key: "GUEST"), "Guest")
        XCTAssertEqual(SpeakerLabel.display(nil, key: TranscriptionRunner.micSpeakerKey), "You")
        XCTAssertEqual(SpeakerLabel.display("Lana", key: "SPEAKER_03"), "Lana")
    }

    func testSpeakerLabelPlaceholders() {
        XCTAssertTrue(SpeakerLabel.isPlaceholder("SPEAKER_02"))
        XCTAssertTrue(SpeakerLabel.isPlaceholder("GUEST"))
        XCTAssertTrue(SpeakerLabel.isPlaceholder(RecordingRepository.taggedKeyPrefix + "1"))
        XCTAssertFalse(SpeakerLabel.isPlaceholder("Sean"))
    }

    // MARK: - The same meeting learned twice

    func testLearningTheSameSpeakersAgainReplacesTheirSample() throws {
        let rec = UUID()
        let first = try store.remember(print([1, 0, 0, 0], seconds: 78), as: "Maria", from: rec, speakers: "S2")
        let again = try store.add(print([1, 0.05, 0, 0], seconds: 100), to: first.id, from: rec, speakers: "S2")
        XCTAssertEqual(again.allSamples.count, 1, "one meeting, one sample")
        XCTAssertEqual(again.print.seconds, 100, accuracy: 0.01)
        XCTAssertEqual(again.print.embeddings.count, 4)
        XCTAssertEqual(again.sources, 1)
        // Another speaker of the same recording is the same person split in two: kept beside it.
        let split = try store.add(print([1, 0.02, 0, 0], seconds: 30), to: first.id, from: rec, speakers: "S5")
        XCTAssertEqual(split.allSamples.count, 2)
        XCTAssertEqual(split.print.seconds, 130, accuracy: 0.01)
    }
}
