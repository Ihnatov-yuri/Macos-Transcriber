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

    var backupRoot: URL!

    override func setUp() async throws {
        let schema = Schema(TranscriberrSchema.models)
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        repo = RecordingRepository(context: container.mainContext)
        // Redirect BackupService off the user's real ~/Documents/Transcriberr
        // Backups — every repository write triggers a real disk write, and
        // backups are never pruned, so unguarded tests would leave junk there
        // forever.
        backupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriberr-test-backups-\(UUID().uuidString.prefix(6))")
        setenv("TRANSCRIBERR_BACKUP_ROOT", backupRoot.path, 1)
    }

    override func tearDown() async throws {
        for f in tempFiles { try? FileManager.default.removeItem(at: f) }
        tempFiles = []
        unsetenv("TRANSCRIBERR_BACKUP_ROOT")
        try? FileManager.default.removeItem(at: backupRoot)
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

    func testMergeOrdersByCreationTimeNotClickOrder() async throws {
        let early = try makeRecording(title: "Early", seconds: 1, segs: [(0, 1, "first", nil, nil)])
        let late = try makeRecording(title: "Late", seconds: 1, segs: [(0, 1, "second", nil, nil)])
        early.createdAtMillis = 1_000
        late.createdAtMillis = 2_000

        // Merge initiated FROM the later recording — the earlier one must
        // still open the merged timeline.
        let merged = try await repo.merge(late, early)
        defer { tempFiles.append(URL(fileURLWithPath: merged.audioPath)) }
        XCTAssertEqual(merged.title, "Early + Late")
        let sorted = merged.segments.sorted { $0.startSeconds < $1.startSeconds }
        XCTAssertEqual(sorted.first?.text, "first")
        XCTAssertEqual(sorted.last?.text, "second")
        XCTAssertEqual(sorted.last!.startSeconds, 1, accuracy: 0.05)
    }

    func testMergeInheritsFolderFromSources() async throws {
        let folder = try repo.createFolder(named: "Work")
        let a = try makeRecording(title: "A", seconds: 1, segs: [(0, 1, "hi", nil, nil)])
        let b = try makeRecording(title: "B", seconds: 1, segs: [(0, 1, "yo", nil, nil)])
        try repo.move(a, to: folder)
        try repo.move(b, to: folder)

        let merged = try await repo.merge(a, b)
        defer { tempFiles.append(URL(fileURLWithPath: merged.audioPath)) }
        XCTAssertEqual(merged.folder?.id, folder.id,
                       "merging two recordings in a folder must file the result there")

        // a unfiled, b filed → b's folder wins as the only one present
        let c = try makeRecording(title: "C", seconds: 1, segs: [(0, 1, "ok", nil, nil)])
        let merged2 = try await repo.merge(c, b)
        defer { tempFiles.append(URL(fileURLWithPath: merged2.audioPath)) }
        XCTAssertEqual(merged2.folder?.id, folder.id)
    }

    // MARK: - Backup shadow (file-based, independent of the SwiftData store)

    /// appendSegments/replaceSegmentsInRange run on @MainActor once per
    /// transcription CHUNK — they must NOT also pay a synchronous
    /// JSON-encode-and-disk-write per chunk. Confirms recording.json only
    /// picks up new segments at snapshotVersion (a run's completion
    /// checkpoint), not on every live append.
    func testLiveAppendDoesNotBackupPerChunk() throws {
        let rec = try makeRecording(title: "Streaming", seconds: 1,
            segs: [(0, 1, "chunk one", nil, nil)])
        XCTAssertNil(BackupService.allRecordingBackups().first { $0.id == rec.id }?.segments.first,
                     "save() backs up the recording as created (no segments yet); appendSegments must not add to it")

        try repo.appendSegments([Segment(startSeconds: 1, endSeconds: 2, text: "chunk two",
                                         speaker: nil, speakerName: nil)], to: rec)
        XCTAssertTrue(BackupService.allRecordingBackups().first { $0.id == rec.id }?.segments.isEmpty ?? true,
                      "a live per-chunk append must not trigger a backup write")

        try repo.snapshotVersion(of: rec, engineId: "e1", engineLabel: "E1")
        let dto = BackupService.allRecordingBackups().first { $0.id == rec.id }
        XCTAssertEqual(dto?.segments.count, 2, "the run-completion checkpoint must capture everything appended")
    }

    func testBackupShadowsRecordingVersionAndOutput() throws {
        let rec = try makeRecording(title: "Backed Up", seconds: 1,
            segs: [(0, 1, "hello", "ME", "Yuri")])
        try repo.snapshotVersion(of: rec, engineId: "e1", engineLabel: "E1")
        try repo.replaceOutput(
            OutputDoc(presetId: "summary", title: "Summary", markdown: "- point one"),
            for: rec)

        let backups = BackupService.allRecordingBackups()
        guard let dto = backups.first(where: { $0.id == rec.id }) else {
            return XCTFail("recording backup not found")
        }
        XCTAssertEqual(dto.title, "Backed Up")
        XCTAssertEqual(dto.segments.count, 1)
        XCTAssertEqual(dto.segments.first?.text, "hello")

        let versions = BackupService.versionBackups(for: rec.id)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions.first?.engineId, "e1")

        let outputs = BackupService.outputBackups(for: rec.id)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs.first?.presetId, "summary")
    }

    func testBackupSurvivesRecordingDelete() throws {
        let rec = try makeRecording(title: "Deleted But Backed Up", seconds: 1,
            segs: [(0, 1, "keep me", nil, nil)])
        // recording.json is refreshed at run-completion checkpoints
        // (snapshotVersion/replaceSegments/etc.), not on every live-append —
        // mirrors the real flow where a completed transcription run always
        // snapshots before the recording becomes something a user could see
        // or delete.
        try repo.snapshotVersion(of: rec, engineId: "e1", engineLabel: "E1")
        let id = rec.id
        try repo.delete(rec)

        let dto = BackupService.allRecordingBackups().first { $0.id == id }
        XCTAssertNotNil(dto, "backup must survive a Recording delete — that's the whole point")
        XCTAssertEqual(dto?.segments.first?.text, "keep me")
    }

    // MARK: - Delete safety

    func testClearSegmentsRemovesRows() throws {
        let rec = try makeRecording(title: "t", seconds: 1,
            segs: [(0, 1, "x", nil, nil), (1, 2, "y", nil, nil)])
        try repo.clearSegments(of: rec)
        XCTAssertTrue(rec.segments.isEmpty)
    }
}
