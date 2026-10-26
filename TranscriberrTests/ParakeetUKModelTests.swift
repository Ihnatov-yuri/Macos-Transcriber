import XCTest
@testable import Transcriberr

final class ParakeetUKModelTests: XCTestCase {
    private let rev = String(repeating: "9e3b5cdc", count: 5)

    /// Hugging Face's tree listing for one release: LFS files carry a
    /// SHA-256, small git files only their blob id.
    private func tree(skip: String? = nil, extra: [[String: Any]] = []) -> [[String: Any]] {
        var paths = ["config.json", "parakeet_vocab.json", "parakeet_v3_vocab.json"]
        for part in ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"] {
            paths += ["weights/weight.bin", "model.mil", "coremldata.bin", "metadata.json"].map { "\(part).mlmodelc/\($0)" }
        }
        var entries: [[String: Any]] = [["type": "directory", "path": "coreml/int8/parakeet-tdt-0.6b-v3/Encoder.mlmodelc", "size": 0]]
        for p in paths where p != skip {
            var e: [String: Any] = ["type": "file", "path": "coreml/int8/parakeet-tdt-0.6b-v3/\(p)", "size": 100,
                                    "oid": String(repeating: "a", count: 40)]
            if p.hasSuffix(".bin") { e["lfs"] = ["oid": String(repeating: "b", count: 64), "size": 100] }
            entries.append(e)
        }
        return entries + extra
    }

    func testReleaseListParsesAndCoversWhatFluidAudioLoads() throws {
        let m = try ParakeetUKModel.manifest(revision: rev, tree: tree())
        XCTAssertNoThrow(try m.validate())
        XCTAssertEqual(m.files.count, 19)
        let weight = try XCTUnwrap(m.files.first { $0.path == "Encoder.mlmodelc/weights/weight.bin" })
        XCTAssertEqual(weight.sha256?.count, 64)
        XCTAssertNil(weight.gitBlob)
        let config = try XCTUnwrap(m.files.first { $0.path == "config.json" })
        XCTAssertNil(config.sha256)
        XCTAssertEqual(config.gitBlob?.count, 40)
        XCTAssertEqual(ParakeetUKModel.remoteURL(weight, revision: rev).absoluteString,
                       "https://huggingface.co/ihnatov-yuri/parakeet-tdt-0.6b-v3-uk/resolve/\(rev)/coreml/int8/parakeet-tdt-0.6b-v3/Encoder.mlmodelc/weights/weight.bin")
        XCTAssertEqual(ParakeetUKModel.modelDirectory.lastPathComponent, "parakeet-tdt-0.6b-v3")
        XCTAssertNotEqual(ParakeetUKModel.modelDirectory.path, ParakeetUKModel.stockDirectory.path)
    }

    func testUnusableReleasesAreRefused() throws {
        // A component FluidAudio needs is missing.
        XCTAssertThrowsError(try ParakeetUKModel.manifest(revision: rev, tree: tree(skip: "Encoder.mlmodelc/weights/weight.bin")).validate())
        // A path that would leave the model folder.
        let escape: [String: Any] = ["type": "file", "path": "coreml/int8/parakeet-tdt-0.6b-v3/../../x", "size": 1,
                                     "oid": String(repeating: "c", count: 40)]
        XCTAssertThrowsError(try ParakeetUKModel.manifest(revision: rev, tree: tree(extra: [escape])).validate())
        // A file without a checksum.
        let bare: [String: Any] = ["type": "file", "path": "coreml/int8/parakeet-tdt-0.6b-v3/extra.bin", "size": 1]
        XCTAssertThrowsError(try ParakeetUKModel.manifest(revision: rev, tree: tree(extra: [bare])).validate())
        // Far larger than a Parakeet release.
        let huge: [String: Any] = ["type": "file", "path": "coreml/int8/parakeet-tdt-0.6b-v3/huge.bin", "size": 3_000_000_000,
                                   "oid": "x", "lfs": ["oid": String(repeating: "d", count: 64)]]
        XCTAssertThrowsError(try ParakeetUKModel.manifest(revision: rev, tree: tree(extra: [huge])).validate())
        // Not a commit id.
        XCTAssertThrowsError(try ParakeetUKModel.manifest(revision: "main", tree: tree()).validate())
        // Files outside the Core ML folder are not part of the release.
        let card: [String: Any] = ["type": "file", "path": "README.md", "size": 10, "oid": String(repeating: "e", count: 40)]
        XCTAssertEqual(try ParakeetUKModel.manifest(revision: rev, tree: tree(extra: [card])).files.count, 19)
    }

    /// A commit that only touched the model card changes nothing to download.
    func testSameFilesIgnoresTheCommit() throws {
        let a = try ParakeetUKModel.manifest(revision: rev, tree: tree())
        let b = try ParakeetUKModel.manifest(revision: String(repeating: "1", count: 40), tree: tree())
        XCTAssertTrue(a.sameFiles(as: b))
        var changed = tree()
        changed[3]["size"] = 101
        XCTAssertFalse(a.sameFiles(as: try ParakeetUKModel.manifest(revision: rev, tree: changed)))
    }

    /// Hugging Face reports git's blob id for files not in LFS.
    func testGitBlobHashMatchesGit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("hello\n".utf8).write(to: url)
        // `printf 'hello\n' | git hash-object --stdin`
        XCTAssertEqual(try ParakeetUKModel.gitBlobSHA1(of: url), "ce013625030ba8dba906f756967f9e9ca394464a")
        let file = ParakeetUKModel.File(path: "x", size: 6, sha256: nil, gitBlob: "ce013625030ba8dba906f756967f9e9ca394464a")
        XCTAssertTrue(ParakeetUKModel.matches(file, at: url))
        XCTAssertFalse(ParakeetUKModel.matches(ParakeetUKModel.File(path: "x", size: 6, sha256: nil, gitBlob: String(repeating: "0", count: 40)), at: url))
    }

    func testInstallStateFromManifestAndFor470Installs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(ParakeetUKModel.isInstalled(at: dir))
        let m = try ParakeetUKModel.manifest(revision: rev, tree: tree())
        for f in m.files {
            let url = dir.appendingPathComponent(f.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: Int(f.size)).write(to: url)
        }
        // 4.7.0 left no manifest: the files FluidAudio needs are enough.
        XCTAssertTrue(ParakeetUKModel.isInstalled(at: dir))
        try JSONEncoder().encode(m).write(to: dir.appendingPathComponent(ParakeetUKModel.manifestName))
        XCTAssertEqual(ParakeetUKModel.manifest(at: dir), m)
        XCTAssertTrue(ParakeetUKModel.isInstalled(at: dir))
        // A file at the wrong size means the release is not complete.
        try Data(count: 5).write(to: dir.appendingPathComponent("Decoder.mlmodelc/model.mil"))
        XCTAssertFalse(ParakeetUKModel.isInstalled(at: dir))
    }

    func testFineTuneMarkerAndVersionName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"model_name": "ihnatov-yuri/parakeet-tdt-0.6b-v3-uk", "version": "uk_v4b"}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        XCTAssertTrue(ParakeetUKModel.isFineTune(at: dir))
        XCTAssertEqual(ParakeetUKModel.versionName(at: dir), "uk_v4b")
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
        XCTAssertEqual(d.string(forKey: "dictation.engine"), "parakeet-uk")
        XCTAssertEqual(d.string(forKey: "ensemble.engineB"), "parakeet-uk")
        // Super's unset side already defaults to Whisper: left alone.
        XCTAssertNil(d.string(forKey: "ensemble.engineA"))
    }

    /// A new Mac's Super pairs Whisper with Parakeet UK; nothing defaults to
    /// the English-only Parakeet v2, so it is never downloaded unasked.
    func testSuperDefaultsToWhisperAndParakeetUK() {
        XCTAssertEqual(EnsembleBackend.defaultEngineA, .whisper)
        XCTAssertEqual(EnsembleBackend.defaultEngineB, .parakeetUK)
        let pair = EnsembleBackend.resolvePair(EnsembleBackend.defaultEngineA, EnsembleBackend.defaultEngineB, languages: ["Ukrainian"])
        XCTAssertEqual(pair.0, .whisper)
        XCTAssertEqual(pair.1, .parakeetUK)
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
