import XCTest
@testable import Transcriberr

final class BenchmarkTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID())")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testWordErrors() {
        XCTAssertEqual(Benchmark.wordErrors(ref: "We met Kaiko today.", hyp: "we met kaico today").errors, 1)
        XCTAssertEqual(Benchmark.wordErrors(ref: "a b c", hyp: "a c").errors, 1)
        XCTAssertEqual(Benchmark.wordErrors(ref: "a b c", hyp: "").errors, 3)
        XCTAssertEqual(Benchmark.wordErrors(ref: "a b", hyp: "a b").errors, 0)
    }

    private func audio(seconds: Double) throws -> URL {
        let url = dir.appendingPathComponent("rec.wav")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let n = Int(seconds * 16_000)
        try Benchmark.writeWAV((0..<n).map { Float(sin(Double($0) * 0.05)) * 0.3 }, to: url)
        return url
    }

    func testRecordCutsClipAndKeepsFirstMachineText() async throws {
        let wav = try audio(seconds: 10)
        let id = UUID()
        var src = Benchmark.Source(segmentId: id, recordingId: UUID(), recordingTitle: "t", audioPath: wav.path,
                                   language: "Ukrainian", speaker: nil, start: 2, end: 5,
                                   text: "Kaiko is here", engine: "ensemble")
        let first = await Benchmark.record(src, machine: "Kaico is here", in: dir)
        XCTAssertEqual(first?.machine, "Kaico is here")
        XCTAssertEqual(first?.track, "mix")
        let clip = dir.appendingPathComponent(first!.clip)
        let samples = try AudioDecoder.decodeViaAudioFile(clip)
        XCTAssertEqual(Double(samples.count) / 16_000, 3 + 2 * Benchmark.padding, accuracy: 0.05)

        // A second edit keeps the engine's original text.
        src.text = "Kaiko is here now"
        let second = await Benchmark.record(src, machine: "Kaiko is here", in: dir)
        XCTAssertEqual(second?.machine, "Kaico is here")
        XCTAssertEqual(second?.reference, "Kaiko is here now")
        XCTAssertEqual(Benchmark.items(in: dir).count, 1)

        let s = Benchmark.summary(Benchmark.items(in: dir))
        XCTAssertEqual(s.first?.language, "Ukrainian")
        XCTAssertEqual(s.first?.words, 4)
        XCTAssertEqual(s.first?.errors, 2)

        Benchmark.remove(id, in: dir)
        XCTAssertTrue(Benchmark.items(in: dir).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path))
    }

    func testSplitTrackLineKeepsAllThreeTracks() async throws {
        let wav = try audio(seconds: 10)
        let base = wav.deletingPathExtension()
        for kind in ["mic", "sys"] {
            try Benchmark.writeWAV([Float](repeating: 0.1, count: 160_000), to: base.appendingPathExtension("\(kind).wav"))
        }
        let id = UUID()
        let src = Benchmark.Source(segmentId: id, recordingId: UUID(), recordingTitle: "m", audioPath: wav.path,
                                   language: "English", speaker: "ME", start: 1, end: 3, text: "hello there", engine: nil)
        let item = await Benchmark.record(src, machine: "hello their", in: dir)
        XCTAssertEqual(item?.track, "mic")
        let clip = dir.appendingPathComponent(item!.clip).deletingPathExtension()
        for ext in ["wav", "mic.wav", "sys.wav"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: clip.appendingPathExtension(ext).path), ext)
        }
        // The scoring run sees a split-track recording, as the real one did.
        XCTAssertNotNil(AudioCompressor.sidecarURL(for: dir.appendingPathComponent(item!.clip), kind: "mic"))
        XCTAssertTrue(Benchmark.onSide(speakerKey: "ME", track: "mic"))
        XCTAssertFalse(Benchmark.onSide(speakerKey: "SPEAKER_01", track: "mic"))
        XCTAssertTrue(Benchmark.onSide(speakerKey: "SPEAKER_01", track: "sys"))
        Benchmark.remove(id, in: dir)
        for ext in ["wav", "mic.wav", "sys.wav"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: clip.appendingPathExtension(ext).path), ext)
        }
    }
}
