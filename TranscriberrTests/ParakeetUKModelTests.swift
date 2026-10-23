import XCTest
@testable import Transcriberr

final class ParakeetUKModelTests: XCTestCase {
    /// FluidAudio needs every v3 component plus the vocabulary, and finds
    /// them only under a folder named like stock's.
    func testManifestCoversWhatFluidAudioLoads() {
        let paths = Set(ParakeetUKModel.files.map(\.path))
        XCTAssertEqual(paths.count, ParakeetUKModel.files.count)
        for part in ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"] {
            XCTAssertTrue(paths.contains("\(part).mlmodelc/weights/weight.bin"), part)
            XCTAssertTrue(paths.contains("\(part).mlmodelc/model.mil"), part)
            XCTAssertTrue(paths.contains("\(part).mlmodelc/coremldata.bin"), part)
        }
        XCTAssertTrue(paths.contains("parakeet_vocab.json"))
        XCTAssertTrue(paths.contains("config.json"))
        XCTAssertEqual(ParakeetUKModel.modelDirectory.lastPathComponent, "parakeet-tdt-0.6b-v3")
        XCTAssertNotEqual(ParakeetUKModel.modelDirectory.path, ParakeetUKModel.stockDirectory.path)
    }

    func testDownloadsArePinnedAndHashed() {
        XCTAssertEqual(ParakeetUKModel.revision.count, 40)
        for f in ParakeetUKModel.files {
            XCTAssertEqual(f.sha256.count, 64, f.path)
            XCTAssertGreaterThan(f.size, 0, f.path)
            let url = ParakeetUKModel.remoteURL(f).absoluteString
            XCTAssertTrue(url.hasPrefix("https://huggingface.co/ihnatov-yuri/parakeet-tdt-0.6b-v3-uk/resolve/\(ParakeetUKModel.revision)/coreml/int8/"), url)
        }
    }

    func testInstallCheckAndFineTuneMarker() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(ParakeetUKModel.isInstalled(at: dir))
        for f in ParakeetUKModel.files where f.path != "config.json" {
            let url = dir.appendingPathComponent(f.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(f.size))
            try handle.close()
        }
        // config.json is required, at any size (an in-place install keeps its own).
        XCTAssertFalse(ParakeetUKModel.isInstalled(at: dir))
        try Data(#"{"model_name": "ihnatov/parakeet-tdt-0.6b-v3-uk"}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        XCTAssertTrue(ParakeetUKModel.isInstalled(at: dir))
        XCTAssertTrue(ParakeetUKModel.isFineTune(at: dir))
        // What FluidAudio's recovery would leave: stock files, no UK name.
        try Data(#"{"model_name": "nvidia/parakeet-tdt-0.6b-v3"}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        XCTAssertFalse(ParakeetUKModel.isFineTune(at: dir))
    }

    func testRemapMovesStockChoicesToUK() throws {
        let suite = "ParakeetUKModelTests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        d.set("parakeet-v3", forKey: "ui.defaultBackend")
        d.set("whisper-large-v3", forKey: "ui.liveEngine")
        d.set("parakeet-v3", forKey: "ensemble.engineB")
        ParakeetUKModel.remapEngineChoices(d)
        XCTAssertEqual(d.string(forKey: "ui.defaultBackend"), "parakeet-uk")
        XCTAssertEqual(d.string(forKey: "ui.liveEngine"), "whisper-large-v3")
        // Unset meant the stock default.
        XCTAssertEqual(d.string(forKey: "ensemble.engineA"), "parakeet-uk")
        XCTAssertEqual(d.string(forKey: "dictation.engine"), "parakeet-uk")
        XCTAssertEqual(d.string(forKey: "ensemble.engineB"), "parakeet-uk")
    }

    func testUKIsALocalParakeetEngine() {
        let uk = BackendFactory.Kind.parakeetUK
        XCTAssertTrue(uk.isLocal)
        XCTAssertTrue(uk.isParakeet)
        XCTAssertTrue(uk.supportsLive)
        XCTAssertFalse(uk.supportsTextGeneration)
        XCTAssertTrue(uk.displayName.contains("Parakeet UK"))
        XCTAssertNotEqual(BackendFactory.Kind.parakeet.rawValue, uk.rawValue)
    }
}
