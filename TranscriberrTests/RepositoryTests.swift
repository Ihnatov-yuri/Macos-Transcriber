import XCTest
import SwiftData
import AVFoundation
@testable import Transcriberr

/// The "button press" layer: every destructive UI action routes through the
/// repository — these tests exercise them against an in-memory store.
@MainActor
final class RepositoryTests: XCTestCase {
    var container: ModelContainer!
    var repo: RecordingRepository!
    var tempFiles: [URL] = []

    override func setUp() async throws {
        let schema = Schema([Recording.self, Segment.self, OutputDoc.self,
                             PendingTask.self, TranscriptVersion.self])
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        repo = RecordingRepository(context: container.mainContext)
    }

    override func tearDown() async throws {
        for f in tempFiles { try? FileManager.default.removeItem(at: f) }
        tempFiles = []
    }

    private func makeWav(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString.prefix(6)).wav")
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                channels: 1, interleaved: false)!
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = sin(Float(i) * 0.1) * 0.1 }
        try f.write(from: buf)
        tempFiles.append(url)
        return url
    }

    private func makeRecording(title: String, seconds: Double,
                               segs: [(Double, Double, String, String?, String?)]) throws -> Recording {
        let wav = try makeWav(seconds: seconds)
        let rec = Recording(title: title, audioPath: wav.path, durationSeconds: seconds)
        try repo.save(rec)
        let segments = segs.map {
            Segment(startSeconds: $0.0, endSeconds: $0.1, text: $0.2, speaker: $0.3, speakerName: $0.4)
        }
        try repo.appendSegments(segments, to: rec)
        return rec
    }

    // MARK: - Speaker rename + merge (chip actions)

    func testSetSpeakerNamePersistsToMapAndSegments() throws {
        let rec = try makeRecording(title: "t", seconds: 1,
            segs: [(0, 1, "hello", "SPEAKER_01", nil)])
        try repo.setSpeakerName("Lana", for: "SPEAKER_01", in: rec)
        XCTAssertEqual(rec.segments.first?.speakerName, "Lana")
        XCTAssertEqual(repo.storedSpeakerNames(rec)["SPEAKER_01"], "Lana")
    }

    func testMergeSpeakersRelabelsAndCleansMap() throws {
        let rec = try makeRecording(title: "t", seconds: 1, segs: [
            (0, 1, "a", "SPEAKER_01", "Kees"),
            (1, 2, "b", "SPEAKER_02", nil),
        ])
        try repo.setSpeakerName("Kees", for: "SPEAKER_01", in: rec)
        try repo.mergeSpeakers("SPEAKER_02", into: "SPEAKER_01", in: rec)
        XCTAssertTrue(rec.segments.allSatisfy { $0.speaker == "SPEAKER_01" })
        XCTAssertTrue(rec.segments.allSatisfy { $0.speakerName == "Kees" })
        XCTAssertNil(repo.storedSpeakerNames(rec)["SPEAKER_02"])
    }

    // MARK: - Versions (snapshot / restore buttons)

    func testSnapshotDedupsAndRestores() async throws {
        let rec = try makeRecording(title: "t", seconds: 1,
            segs: [(0, 1, "original", "ME", "Yuri")])
        try repo.snapshotVersion(of: rec, engineId: "e1", engineLabel: "E1")
        // Two presses of a button are always separated by runloop turns —
        // same-tick re-entry is a harness artifact SwiftData can't promise
        // consistency for (its relationship/fetch views lag within a tick).
        try await Task.sleep(nanoseconds: 100_000_000)
        try repo.snapshotVersion(of: rec, engineId: "e1", engineLabel: "E1")   // dup
        XCTAssertEqual(rec.versions.count, 1, "identical snapshot must dedup")

        try repo.clearSegments(of: rec)
        try repo.appendSegments([Segment(startSeconds: 0, endSeconds: 1, text: "changed",
                                         speaker: nil, speakerName: nil)], to: rec)
        try repo.restoreVersion(rec.versions[0], to: rec)
        XCTAssertEqual(rec.segments.first?.text, "original")
        XCTAssertEqual(rec.segments.first?.speakerName, "Yuri")
    }

    // MARK: - Merge recordings (context-menu action)

    func testMergeRecordingsOffsetsRemapsAndNames() async throws {
        let a = try makeRecording(title: "A", seconds: 2, segs: [
            (0, 1, "hi", "ME", "Yuri"),
            (1, 2, "yo", "SPEAKER_00", "Len"),
        ])
        let b = try makeRecording(title: "B", seconds: 2, segs: [
            (0, 1, "hey", "ME", "Yuri"),
            (1, 2, "sup", "SPEAKER_00", "Lana"),
        ])
        let merged = try await repo.merge(a, b)
        defer { tempFiles.append(URL(fileURLWithPath: merged.audioPath)) }

        XCTAssertEqual(merged.segments.count, 4)
        XCTAssertEqual(merged.durationSeconds, 4, accuracy: 0.05)
        let sorted = merged.segments.sorted { $0.startSeconds < $1.startSeconds }
        // b's timeline shifted by a's length
        XCTAssertEqual(sorted[2].startSeconds, 2, accuracy: 0.05)
        // ME stays ME in both halves; b's SPEAKER_00 remapped past a's
        XCTAssertEqual(sorted[0].speaker, "ME")
        XCTAssertEqual(sorted[2].speaker, "ME")
        XCTAssertEqual(sorted[1].speaker, "SPEAKER_00")
        XCTAssertEqual(sorted[3].speaker, "SPEAKER_01")
        XCTAssertEqual(sorted[3].speakerName, "Lana")
        // name map persisted with remapped keys
        let map = repo.storedSpeakerNames(merged)
        XCTAssertEqual(map["SPEAKER_00"], "Len")
        XCTAssertEqual(map["SPEAKER_01"], "Lana")
        // originals untouched
        XCTAssertEqual(a.segments.count, 2)
        XCTAssertEqual(b.segments.count, 2)
    }

    // MARK: - Delete safety

    func testClearSegmentsRemovesRows() throws {
        let rec = try makeRecording(title: "t", seconds: 1,
            segs: [(0, 1, "x", nil, nil), (1, 2, "y", nil, nil)])
        try repo.clearSegments(of: rec)
        XCTAssertTrue(rec.segments.isEmpty)
    }
}
