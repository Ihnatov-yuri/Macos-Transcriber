import XCTest
import AVFoundation
import SwiftData
@testable import Transcriberr

/// Crash repair: a WAV whose header never got its sizes (the app died before
/// AVAudioFile closed it) must read back in full after `WavRepair.repair`.
/// Everything lives in the temporary directory — never the real Recordings
/// folder.
final class WavRepairTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriberr-wavrepair-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The recorders' exact file format: 16 kHz mono Float32.
    private func writeWav(_ name: String, frames: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
            buf.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames { buf.floatChannelData![0][i] = sin(Float(i) / 10) * 0.3 }
            try file.write(from: buf)
        }   // file closed here
        return url
    }

    /// Byte offset of the `data` chunk header, found by walking the chunks.
    private func dataChunkOffset(_ bytes: Data) -> Int? {
        var pos = 12
        while pos + 8 <= bytes.count {
            let id = String(decoding: bytes[pos..<pos + 4], as: UTF8.self)
            if id == "data" { return pos }
            let size = bytes[pos + 4..<pos + 8].enumerated()
                .reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            pos += 8 + size + (size & 1)
        }
        return nil
    }

    /// What a crash leaves (measured): the RIFF size still covers only the
    /// header, and the data size is zero.
    private func simulateCrash(_ url: URL) throws {
        var bytes = try Data(contentsOf: url)
        let data = try XCTUnwrap(dataChunkOffset(bytes))
        let riffSize = UInt32(data)   // header length (data + 8) minus the 8-byte RIFF preamble
        withUnsafeBytes(of: riffSize.littleEndian) { bytes.replaceSubrange(4..<8, with: $0) }
        bytes.replaceSubrange(data + 4..<data + 8, with: [0, 0, 0, 0])
        try bytes.write(to: url)
    }

    func testZeroedSizesAreRepairedToTheFullFrameCount() throws {
        let url = try writeWav("Recording_test.wav", frames: 48_000)
        try simulateCrash(url)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 0, "precondition: the crash left an empty-looking file")

        XCTAssertEqual(WavRepair.repair(url), .repaired(frames: 48_000, seconds: 3))
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 48_000)
        XCTAssertEqual(WavRepair.repair(url), .healthy, "a second pass must not touch it")
    }

    func testCleanFileIsLeftAlone() throws {
        let url = try writeWav("meeting_1_x.wav", frames: 16_000)
        let before = try Data(contentsOf: url)
        XCTAssertEqual(WavRepair.repair(url), .healthy)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testPartialTrailingFrameIsTrimmed() throws {
        let url = try writeWav("Recording_partial.wav", frames: 16_000)
        try simulateCrash(url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1, 2]))   // half a Float32 frame
        try handle.close()

        XCTAssertEqual(WavRepair.repair(url), .repaired(frames: 16_000, seconds: 1))
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 16_000)
    }

    func testOnlyRecorderFilesAreCandidatesAndOpenFilesAreSkipped() throws {
        let mix = try writeWav("meeting_2_y.wav", frames: 32_000)
        let mic = try writeWav("meeting_2_y.mic.wav", frames: 32_000)
        let other = try writeWav("Dictation_z.wav", frames: 16_000)
        for url in [mix, mic, other] { try simulateCrash(url) }

        let candidates = WavRepair.candidates(in: dir)
        XCTAssertEqual(Set(candidates.map(\.lastPathComponent)), ["meeting_2_y.wav", "meeting_2_y.mic.wav"])
        let repaired = WavRepair.repairAll(candidates, excluding: [mic.standardizedFileURL.path])
        XCTAssertEqual(repaired.map { $0.url.lastPathComponent }, ["meeting_2_y.wav"], "an excluded (open) file is never touched")
        XCTAssertEqual(try AVAudioFile(forReading: mic).length, 0)
        XCTAssertEqual(try AVAudioFile(forReading: mix).length, 32_000)
    }

    /// A crashed recording never reached Stop, so it has no row: it gets one.
    /// A HEALTHY orphan is a recording the user deleted — it must stay gone.
    @MainActor
    func testCrashedRecordingWithoutARowIsImportedOnce() throws {
        // Keep BackupService off the real ~/Documents/Transcriberr/Backups.
        setenv("TRANSCRIBERR_BACKUP_ROOT", dir.appendingPathComponent("backups").path, 1)
        defer { BackupService.flush(); unsetenv("TRANSCRIBERR_BACKUP_ROOT") }
        let store = try ModelContainer(for: Schema(TranscriberrSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let repo = RecordingRepository(context: store.mainContext)

        let crashed = try writeWav("Recording_crashed.wav", frames: 16_000)
        try simulateCrash(crashed)
        _ = try writeWav("Recording_deleted.wav", frames: 16_000)

        let repaired = WavRepair.repairAll(WavRepair.candidates(in: dir))
        XCTAssertEqual(WavRepair.importOrphans(repaired, into: repo), 1)
        let rows = try repo.all()
        XCTAssertEqual(rows.map(\.audioPath), [crashed.path])
        XCTAssertEqual(rows.first?.durationSeconds ?? 0, 1, accuracy: 0.001)
        XCTAssertTrue(rows.first?.title.hasPrefix("Recovered recording") == true)
        XCTAssertEqual(WavRepair.importOrphans(repaired, into: repo), 0, "a file with a row is never imported twice")
    }

    func testNotAWavIsUnrepairable() throws {
        let url = dir.appendingPathComponent("Recording_junk.wav")
        try Data(repeating: 7, count: 100).write(to: url)
        guard case .unrepairable = WavRepair.repair(url) else { return XCTFail("garbage must not be rewritten") }
    }
}
