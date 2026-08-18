import XCTest
import SwiftData
@testable import Transcriberr

/// The external read-only surface: seed an ON-DISK store the way the app
/// would, close it, then reopen through KBService the way the CLI/MCP
/// server does.
@MainActor
final class KBServiceTests: XCTestCase {
    var storeURL: URL!
    var recID: UUID!

    override func setUp() async throws {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kbtest_\(UUID().uuidString.prefix(6)).store")
        let schema = Schema(TranscriberrSchema.models)
        let config = ModelConfiguration("Transcriberr", schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: config)
        let repo = RecordingRepository(context: container.mainContext)

        let rec = Recording(title: "Standup Meeting", audioPath: "/tmp/a.wav",
                            createdAtMillis: 1_700_000_000_000, durationSeconds: 65)
        rec.sourceLanguage = "en"
        try repo.save(rec)
        recID = rec.id
        try repo.appendSegments([
            Segment(startSeconds: 0, endSeconds: 5, text: "Good morning everyone",
                    speaker: "ME", speakerName: "Yuri"),
            Segment(startSeconds: 5, endSeconds: 10, text: "Sprint review is tomorrow",
                    speaker: "SPEAKER_00", speakerName: "Kees"),
            Segment(startSeconds: 10, endSeconds: 15, text: "Deploy the new build",
                    speaker: "SPEAKER_00", speakerName: "Kees"),
        ], to: rec)
        try repo.replaceOutput(
            OutputDoc(presetId: "summary", title: "Summary", markdown: "- reviewed sprint"),
            for: rec)
        let folder = try repo.createFolder(named: "Work")
        try repo.move(rec, to: folder)
        try repo.addTag(named: "standup", to: rec)

        let other = Recording(title: "Trip Notes", audioPath: "/tmp/b.wav",
                              createdAtMillis: 1_710_000_000_000, durationSeconds: 30)
        try repo.save(other)
        try repo.appendSegments([
            Segment(startSeconds: 0, endSeconds: 3, text: "Pack the camera",
                    speaker: nil, speakerName: nil),
        ], to: other)
    }

    override func tearDown() async throws {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: storeURL.path + suffix))
        }
    }

    private func openKB() throws -> KBService {
        try KBService.openReadOnly(at: storeURL)
    }

    func testStoreNotFoundError() {
        XCTAssertThrowsError(
            try KBService.openReadOnly(at: URL(fileURLWithPath: "/tmp/nope_missing.store")))
    }

    func testListWithFilters() throws {
        let kb = try openKB()
        XCTAssertEqual(try kb.list().count, 2)
        XCTAssertEqual(try kb.list().first?.title, "Trip Notes", "newest first")

        let work = try kb.list(folder: "work")
        XCTAssertEqual(work.map(\.title), ["Standup Meeting"])
        XCTAssertEqual(work.first?.folder, "Work")
        XCTAssertEqual(work.first?.tags, ["standup"])
        XCTAssertEqual(work.first?.outputPresets, ["summary"])
        XCTAssertEqual(work.first?.segmentCount, 3)

        XCTAssertEqual(try kb.list(tag: "STANDUP").count, 1)
        // both seeded recordings predate now-7d
        XCTAssertEqual(try kb.list(since: Date()).count, 0)
        XCTAssertEqual(try kb.list(limit: 1).count, 1)
    }

    func testSearchFindsSegmentsAndTitles() throws {
        let kb = try openKB()
        let hits = try kb.search("sprint")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].recording.title, "Standup Meeting")
        XCTAssertEqual(hits[0].matches.count, 1)
        XCTAssertEqual(hits[0].matches[0].speakerName, "Kees")

        let titleHits = try kb.search("trip")
        XCTAssertEqual(titleHits.count, 1)
        XCTAssertTrue(titleHits[0].titleMatched)
    }

    func testTranscriptPaginationAndSlicing() throws {
        let kb = try openKB()
        let full = try kb.transcript(id: recID.uuidString)
        XCTAssertEqual(full.totalSegments, 3)
        XCTAssertFalse(full.truncated)

        let page = try kb.transcript(id: recID.uuidString, offset: 1, limit: 1)
        XCTAssertEqual(page.segments.map(\.text), ["Sprint review is tomorrow"])
        XCTAssertTrue(page.truncated)
        XCTAssertEqual(page.offset, 1)

        let sliced = try kb.transcript(id: recID.uuidString,
                                       startSeconds: 6, endSeconds: 12)
        XCTAssertEqual(sliced.segments.count, 2, "overlapping window")
    }

    func testResolvePrefixAndAmbiguity() throws {
        let kb = try openKB()
        let prefix = String(recID.uuidString.prefix(8)).lowercased()
        let t = try kb.transcript(id: prefix)
        XCTAssertEqual(t.recording.title, "Standup Meeting")

        XCTAssertThrowsError(try kb.transcript(id: "zz"))       // too short
        XCTAssertThrowsError(try kb.transcript(id: "ffffffff")) // no match
    }

    func testOutputs() throws {
        let kb = try openKB()
        let docs = try kb.outputs(id: recID.uuidString)
        XCTAssertEqual(docs.map(\.presetId), ["summary"])
        XCTAssertEqual(try kb.outputs(id: recID.uuidString, presetId: "minutes").count, 0)
    }

    func testFoldersTagsStats() throws {
        let kb = try openKB()
        XCTAssertEqual(try kb.folders().map(\.name), ["Work"])
        XCTAssertEqual(try kb.folders().first?.count, 1)
        XCTAssertEqual(try kb.tags().map(\.name), ["standup"])
        let stats = try kb.stats()
        XCTAssertEqual(stats.recordings, 2)
        XCTAssertEqual(stats.totalDurationSeconds, 95, accuracy: 0.01)
        XCTAssertEqual(stats.languages["en"], 1)
        XCTAssertEqual(stats.outputs, 1)
        XCTAssertNotNil(stats.oldest)
        XCTAssertGreaterThan(stats.storeSizeBytes, 0)
    }

    func testReadOnlyContainerRejectsWrites() throws {
        _ = try openKB()
        let schema = Schema(TranscriberrSchema.models)
        let config = ModelConfiguration("Transcriberr", schema: schema,
                                        url: storeURL, allowsSave: false)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)
        context.insert(Recording(title: "sneaky", audioPath: "/tmp/x.wav"))
        XCTAssertThrowsError(try context.save(), "read-only container must reject writes")
    }

    func testSinceParsing() {
        XCTAssertNotNil(KBService.parseSince("7d"))
        XCTAssertNotNil(KBService.parseSince("24h"))
        XCTAssertNotNil(KBService.parseSince("2026-01-01T00:00:00Z"))
        XCTAssertNil(KBService.parseSince("banana"))
        let sevenDays = KBService.parseSince("7d")!
        XCTAssertEqual(sevenDays.timeIntervalSinceNow, -7 * 86_400, accuracy: 5)
    }

    func testJSONEnvelopeStableAndVersioned() throws {
        let kb = try openKB()
        let rows = try kb.list()
        let a = try KBJSON.envelope("recordings", rows)
        let b = try KBJSON.envelope("recordings", rows)
        XCTAssertEqual(a, b, "sortedKeys must make encoding deterministic")
        XCTAssertTrue(a.contains("\"schemaVersion\""))
    }
}
