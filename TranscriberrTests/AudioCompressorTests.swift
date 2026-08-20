import XCTest
import AVFoundation
@testable import Transcriberr

/// Disk-space reclaim: WAV → AAC transcode with verify-before-delete, and
/// the sidecar lookup that lets split-track meetings keep working across
/// the transition (some on disk as .wav, new ones as .m4a).
final class AudioCompressorTests: XCTestCase {
    var tempFiles: [URL] = []

    override func tearDown() {
        for f in tempFiles { try? FileManager.default.removeItem(at: f) }
        tempFiles = []
    }

    private func makeWav(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("compressor_test_\(UUID().uuidString.prefix(6)).wav")
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                channels: 1, interleaved: false)!
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.2 }
        try f.write(from: buf)
        tempFiles.append(url)
        return url
    }

    func testCompressAndReplaceProducesMatchingDurationAndDeletesOriginal() async throws {
        let wav = try makeWav(seconds: 3)
        let m4a = try await AudioCompressor.compressAndReplace(wav)
        tempFiles.append(m4a)

        XCTAssertEqual(m4a.pathExtension, "m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path),
                       "original WAV must be removed once the transcode is verified")
        XCTAssertTrue(FileManager.default.fileExists(atPath: m4a.path))

        let asset = AVURLAsset(url: m4a)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.2)

        // Must actually decode back to real audio, not a stub/empty file —
        // this is the same reader every part of the app uses.
        let samples = try await AudioDecoder().decodeAll(file: m4a)
        XCTAssertGreaterThan(samples.count, 0)
    }

    func testCompressAndReplaceThrowsAndLeavesNothingBehindForMissingFile() async {
        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).wav")
        do {
            _ = try await AudioCompressor.compressAndReplace(ghost)
            XCTFail("must throw for a file that was never written")
        } catch {
            // expected
        }
        let m4a = ghost.deletingPathExtension().appendingPathExtension("m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: m4a.path),
                       "a failed transcode must not leave a partial .m4a behind")
    }

    func testCompressAndReplaceHandlesVeryShortClipWithoutFalseReject() async throws {
        // Regression guard for the tighter, relative duration tolerance:
        // a legitimately short clip (well under the old flat 0.5s window)
        // must still compress successfully — the tolerance fix must reject
        // genuinely BAD transcodes without also rejecting normal short ones.
        let wav = try makeWav(seconds: 0.2)
        let m4a = try await AudioCompressor.compressAndReplace(wav)
        tempFiles.append(m4a)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
        let duration = try await AVURLAsset(url: m4a).load(.duration).seconds
        XCTAssertEqual(duration, 0.2, accuracy: 0.15)
    }

    func testCompressAndReplaceLeavesNoPartialM4AWhenSourceHasNoAudioTrack() async {
        // transcode() throws .noAudioTrack for a zero-length input — the
        // cleanup-on-throw path (not just the duration-mismatch path) must
        // remove any partial .m4a rather than orphaning it.
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty_\(UUID().uuidString.prefix(6)).wav")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        tempFiles.append(empty)
        do {
            _ = try await AudioCompressor.compressAndReplace(empty)
            XCTFail("must throw for a file with no audio track")
        } catch {
            // expected — a bare zero-byte file isn't valid WAV/duration-readable
        }
        let m4a = empty.deletingPathExtension().appendingPathExtension("m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: m4a.path),
                       "a failed transcode must never leave a partial .m4a behind")
    }

    func testCompressRecordingFilesCompressesMainAndSidecarsConcurrently() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recfiles_\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempFiles.append(dir)

        func writeWav(_ name: String, seconds: Double) throws -> URL {
            let url = dir.appendingPathComponent(name)
            let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                    channels: 1, interleaved: false)!
            let f = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(seconds * 16_000)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
            buf.frameLength = frames
            for i in 0..<Int(frames) { buf.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.2 }
            try f.write(from: buf)
            return url
        }

        let main = try writeWav("meeting_1.wav", seconds: 1)
        _ = try writeWav("meeting_1.mic.wav", seconds: 1)
        _ = try writeWav("meeting_1.sys.wav", seconds: 1)

        let finalURL = await AudioCompressor.compressRecordingFiles(mainURL: main, includeSidecars: true)

        XCTAssertEqual(finalURL.pathExtension, "m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: main.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting_1.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting_1.mic.m4a").path),
                      "sidecars must be compressed too when includeSidecars is true")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting_1.sys.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting_1.mic.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting_1.sys.wav").path))
    }

    func testCompressRecordingFilesFallsBackToOriginalOnFailureWithoutThrowing() async {
        // compressRecordingFiles must never throw — a compression failure
        // must never cost the caller the recording itself.
        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghost_\(UUID().uuidString).wav")
        let finalURL = await AudioCompressor.compressRecordingFiles(mainURL: ghost, includeSidecars: false)
        XCTAssertEqual(finalURL, ghost, "on failure, the original URL must be returned unchanged")
    }

    func testSidecarURLPrefersM4AOverLegacyWav() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar_test_\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempFiles.append(dir)
        let main = dir.appendingPathComponent("meeting_123.wav")
        let wavSidecar = dir.appendingPathComponent("meeting_123.mic.wav")
        let m4aSidecar = dir.appendingPathComponent("meeting_123.mic.m4a")

        // Neither exists yet.
        XCTAssertNil(AudioCompressor.sidecarURL(for: main, kind: "mic"))

        // Legacy-only recording (pre-migration): falls back to .wav.
        FileManager.default.createFile(atPath: wavSidecar.path, contents: Data())
        XCTAssertEqual(AudioCompressor.sidecarURL(for: main, kind: "mic")?.path, wavSidecar.path)

        // Once a compressed sidecar exists alongside it, it wins.
        FileManager.default.createFile(atPath: m4aSidecar.path, contents: Data())
        XCTAssertEqual(AudioCompressor.sidecarURL(for: main, kind: "mic")?.path, m4aSidecar.path)
    }
}
