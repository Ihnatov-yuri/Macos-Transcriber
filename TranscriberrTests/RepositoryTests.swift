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

    /// Writes a `<base>.<suffix>` sidecar (e.g. "mic.wav", "sys.wav") next to
    /// an already-created main audio file, so split()'s sidecar-cutting path
    /// (otherwise unreachable — `AudioCompressor.sidecarURL` returns nil
    /// without one) actually runs in a test.
    private func makeSidecarWav(seconds: Double, suffix: String, of mainURL: URL) throws {
        let url = mainURL.deletingPathExtension().appendingPathExtension(suffix)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                channels: 1, interleaved: false)!
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = sin(Float(i) * 0.07) * 0.1 }
        try f.write(from: buf)
        tempFiles.append(url)
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

    /// Every file a split half COULD have produced (main audio in either
    /// possible extension, mic/sys sidecars, me.json), for teardown.
    /// split() always writes to the real ~/Documents/Transcriberr/Recordings
    /// directory (there's no sandboxed test path), so tracking only the
    /// main audio file — as earlier split tests did — leaves the
    /// sidecars/me.json behind as permanent orphans in the user's real
    /// library folder. `tearDown`'s `try?` makes registering extensions
    /// that don't end up existing harmless.
    private func tempFilesForSplitHalf(_ recording: Recording) -> [URL] {
        let main = URL(fileURLWithPath: recording.audioPath)
        let base = main.deletingPathExtension()
        return [main] + ["wav", "m4a", "mic.wav", "mic.m4a", "sys.wav", "sys.m4a", "me.json"]
            .map { base.appendingPathExtension($0) }
    }

    // MARK: - Split recording (inverse of merge, "cut in two" action)

    func testSplitProducesTwoRecordingsAtMidpoint() async throws {
        let rec = try makeRecording(title: "Meeting", seconds: 4, segs: [
            (0, 1, "a", "ME", "Yuri"),
            (1, 2, "b", "SPEAKER_00", "Len"),
            (2, 3, "c", "ME", "Yuri"),
            (3, 4, "d", "SPEAKER_00", "Len"),
        ])
        let (first, second) = try await repo.split(rec, atSeconds: 2.0)
        defer {
            tempFiles += tempFilesForSplitHalf(first)
            tempFiles += tempFilesForSplitHalf(second)
        }

        XCTAssertEqual(first.title, "Meeting (1)")
        XCTAssertEqual(second.title, "Meeting (2)")
        XCTAssertEqual(first.durationSeconds, 2, accuracy: 0.05)
        XCTAssertEqual(second.durationSeconds, 2, accuracy: 0.05)

        XCTAssertEqual(first.segments.count, 2)
        XCTAssertEqual(second.segments.count, 2)
        let firstSorted = first.segments.sorted { $0.startSeconds < $1.startSeconds }
        let secondSorted = second.segments.sorted { $0.startSeconds < $1.startSeconds }
        XCTAssertEqual(firstSorted.map(\.text), ["a", "b"])
        XCTAssertEqual(secondSorted.map(\.text), ["c", "d"])
        // second's timeline is re-based to start at 0
        XCTAssertEqual(secondSorted[0].startSeconds, 0, accuracy: 0.05)
        XCTAssertEqual(secondSorted[1].startSeconds, 1, accuracy: 0.05)
        // speaker keys carry over as-is — no remap needed, unlike merge
        // (both halves share the same source timeline).
        XCTAssertEqual(secondSorted[0].speaker, "ME")
        XCTAssertEqual(secondSorted[0].speakerName, "Yuri")

        // source is untouched
        XCTAssertEqual(rec.segments.count, 4)

        // "(2)" is not left to a coin-flip clock read: it deterministically
        // sorts below "(1)" in the newest-first library list.
        XCTAssertGreaterThan(first.createdAtMillis, second.createdAtMillis)
    }

    func testSplitPreservesSegmentLanguageAndRunSettings() async throws {
        let rec = try makeRecording(title: "Meeting", seconds: 4, segs: [
            (0, 2, "hallo", "ME", "Yuri"),
            (2, 4, "hi", "SPEAKER_00", "Len"),
        ])
        // SwiftData relationship arrays aren't guaranteed to preserve
        // insertion order — target by content, not .first/.last, or this
        // flakes under a full-suite run interleaved with other tests.
        rec.segments.first { $0.text == "hallo" }?.language = "nl"
        rec.segments.first { $0.text == "hi" }?.language = "en"
        rec.runBackend = "whisper"
        rec.runLanguages = "nl,en"
        rec.runDiarize = true
        rec.runHybridDiarize = true
        rec.runExpectedSpeakers = 4
        rec.runSpeakersExact = true

        let (first, second) = try await repo.split(rec, atSeconds: 2.0)
        defer {
            tempFiles += tempFilesForSplitHalf(first)
            tempFiles += tempFilesForSplitHalf(second)
        }

        XCTAssertEqual(first.segments.first?.language, "nl")
        XCTAssertEqual(second.segments.first?.language, "en")

        for half in [first, second] {
            XCTAssertEqual(half.runBackend, "whisper")
            XCTAssertEqual(half.runLanguages, "nl,en")
            XCTAssertEqual(half.runDiarize, true)
            XCTAssertEqual(half.runHybridDiarize, true)
            XCTAssertEqual(half.runExpectedSpeakers, 4)
            XCTAssertEqual(half.runSpeakersExact, true)
        }
    }

    /// Splitting an ALREADY-compressed source (the normal case — every
    /// finished recording gets AAC-compressed shortly after it's saved) is
    /// the one that must avoid a second lossy re-encode; see
    /// RecordingRepository.split()'s "Best-effort quality upgrade" comment.
    /// This doesn't assert losslessness directly (proven separately against
    /// a real recording — a decode+recompress pass measured ~6% RMS
    /// distortion there, a bitstream trim measured 0%) — it confirms the
    /// lossless-trim code path integrates correctly and doesn't break the
    /// ordinary split contract when it's actually exercised.
    func testSplitOnAlreadyCompressedSource() async throws {
        let wav = try makeWav(seconds: 4)
        let compressed = try await AudioCompressor.compressAndReplace(wav)
        XCTAssertEqual(compressed.pathExtension, "m4a", "precondition: source must be compressed for this test to exercise the lossless-trim path")
        tempFiles.append(compressed)

        let rec = Recording(title: "Compressed", audioPath: compressed.path, durationSeconds: 4)
        try repo.save(rec)
        try repo.appendSegments([
            Segment(startSeconds: 0, endSeconds: 2, text: "before", speaker: nil, speakerName: nil),
            Segment(startSeconds: 2, endSeconds: 4, text: "after", speaker: nil, speakerName: nil),
        ], to: rec)

        let (first, second) = try await repo.split(rec, atSeconds: 2.0)
        defer {
            tempFiles += tempFilesForSplitHalf(first)
            tempFiles += tempFilesForSplitHalf(second)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: first.audioPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.audioPath))
        XCTAssertEqual(first.durationSeconds, 2, accuracy: 0.1)
        XCTAssertEqual(second.durationSeconds, 2, accuracy: 0.1)
        XCTAssertEqual(first.segments.map(\.text), ["before"])
        XCTAssertEqual(second.segments.map(\.text), ["after"])
        // No stray scratch files left behind by the swap-in, in the actual
        // directory split() writes to (not the source's temp directory).
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: URL(fileURLWithPath: first.audioPath).deletingLastPathComponent().path)
        XCTAssertFalse(siblings.contains { $0.hasPrefix(".lossless-") })
    }

    func testSplitCutsSidecarTracksAndMeTimeline() async throws {
        let wav = try makeWav(seconds: 4)
        try makeSidecarWav(seconds: 4, suffix: "mic.wav", of: wav)
        try makeSidecarWav(seconds: 4, suffix: "sys.wav", of: wav)
        let meURL = wav.deletingPathExtension().appendingPathExtension("me.json")
        // [0,1] lands wholly before the cut; [1.5,2.5] straddles it;
        // [3,4] lands wholly after.
        let meIntervals: [[Double]] = [[0, 1], [1.5, 2.5], [3, 4]]
        try JSONEncoder().encode(meIntervals).write(to: meURL)
        tempFiles.append(meURL)

        let rec = Recording(title: "Meeting", audioPath: wav.path, durationSeconds: 4)
        try repo.save(rec)

        let (first, second) = try await repo.split(rec, atSeconds: 2.0)
        defer {
            tempFiles += tempFilesForSplitHalf(first)
            tempFiles += tempFilesForSplitHalf(second)
        }

        for kind in AudioCompressor.sidecarKinds {
            XCTAssertNotNil(AudioCompressor.sidecarURL(for: URL(fileURLWithPath: first.audioPath), kind: kind),
                            "first half must keep its \(kind) track")
            XCTAssertNotNil(AudioCompressor.sidecarURL(for: URL(fileURLWithPath: second.audioPath), kind: kind),
                            "second half must keep its \(kind) track")
        }

        func readMeIntervals(of r: Recording) -> [[Double]] {
            let url = URL(fileURLWithPath: r.audioPath).deletingPathExtension().appendingPathExtension("me.json")
            guard let d = try? Data(contentsOf: url) else { return [] }
            return (try? JSONDecoder().decode([[Double]].self, from: d)) ?? []
        }
        let firstMe = readMeIntervals(of: first).sorted { $0[0] < $1[0] }
        let secondMe = readMeIntervals(of: second).sorted { $0[0] < $1[0] }

        // [0,1] whole, plus the straddling interval clipped to [1.5,2].
        XCTAssertEqual(firstMe.count, 2)
        XCTAssertEqual(firstMe[0][0], 0, accuracy: 0.05)
        XCTAssertEqual(firstMe[0][1], 1, accuracy: 0.05)
        XCTAssertEqual(firstMe[1][0], 1.5, accuracy: 0.05)
        XCTAssertEqual(firstMe[1][1], 2.0, accuracy: 0.05)

        // the straddling interval's tail, clipped to [0,0.5], plus [3,4]
        // shifted to [1,2].
        XCTAssertEqual(secondMe.count, 2)
        XCTAssertEqual(secondMe[0][0], 0, accuracy: 0.05)
        XCTAssertEqual(secondMe[0][1], 0.5, accuracy: 0.05)
        XCTAssertEqual(secondMe[1][0], 1.0, accuracy: 0.05)
        XCTAssertEqual(secondMe[1][1], 2.0, accuracy: 0.05)
    }

    func testSplitAssignsStraddlingSegmentByMidpoint() async throws {
        let rec = try makeRecording(title: "T", seconds: 4, segs: [
            (0, 1.5, "before", nil, nil),
            (1.5, 2.5, "straddle", nil, nil),
            (2.5, 4, "after", nil, nil),
        ])
        let (first, second) = try await repo.split(rec, atSeconds: 2.0)
        defer {
            tempFiles += tempFilesForSplitHalf(first)
            tempFiles += tempFilesForSplitHalf(second)
        }
        // Text can't be sliced — the straddling segment's MIDPOINT (2.0)
        // lands on the second half whole, clamped to start at 0.
        XCTAssertEqual(first.segments.map(\.text), ["before"])
        XCTAssertEqual(Set(second.segments.map(\.text)), ["straddle", "after"])
        let straddle = try XCTUnwrap(second.segments.first { $0.text == "straddle" })
        XCTAssertEqual(straddle.startSeconds, 0, accuracy: 0.05)
        XCTAssertEqual(straddle.endSeconds, 0.5, accuracy: 0.05)
    }

    func testSplitRejectsPointNearEitherEdge() async throws {
        let rec = try makeRecording(title: "Short", seconds: 1, segs: [(0, 1, "hi", nil, nil)])
        do {
            _ = try await repo.split(rec, atSeconds: 0.9)
            XCTFail("a split point within 0.25s of either edge must be rejected")
        } catch RecordingRepository.SplitError.pointOutsideRecording {
            // expected — both halves must stay non-trivial
        } catch {
            XCTFail("expected SplitError.pointOutsideRecording, got \(error)")
        }
    }

    func testSplitInheritsFolderAndTags() async throws {
        let folder = try repo.createFolder(named: "Work")
        let rec = try makeRecording(title: "T", seconds: 2, segs: [(0, 1, "a", nil, nil), (1, 2, "b", nil, nil)])
        try repo.move(rec, to: folder)
        try repo.addTag(named: "urgent", to: rec)

        let (first, second) = try await repo.split(rec, atSeconds: 1.0)
        defer {
            tempFiles += tempFilesForSplitHalf(first)
            tempFiles += tempFilesForSplitHalf(second)
        }
        XCTAssertEqual(first.folder?.id, folder.id)
        XCTAssertEqual(second.folder?.id, folder.id)
        XCTAssertTrue(first.tags.contains { $0.name == "urgent" })
        XCTAssertTrue(second.tags.contains { $0.name == "urgent" })
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
