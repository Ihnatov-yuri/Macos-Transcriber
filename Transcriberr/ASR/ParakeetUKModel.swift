import Foundation
import FluidAudio

/// Ihnatov Parakeet UK: Parakeet TDT 0.6B v3 fine-tuned for Ukrainian, as a
/// Core ML build on Hugging Face (`ihnatov-yuri/parakeet-tdt-0.6b-v3-uk`,
/// `coreml/int8/`). It runs on FluidAudio like stock v3 — same graph, same
/// vocabulary — but lives in its own folder so both engines can be installed
/// and picked side by side.
///
/// FluidAudio only downloads from FluidInference's repos, so this type
/// fetches the files itself, pinned to one commit and checked file by file
/// against the hashes below: the bundle is parsed by native Core ML code in
/// a process holding mic + Accessibility grants.
enum ParakeetUKModel {
    static let repo = "ihnatov-yuri/parakeet-tdt-0.6b-v3-uk"
    static let revision = "08e41c6324a5a668d768d099cb07b0696f0f6279"
    static let remoteFolder = "coreml/int8/parakeet-tdt-0.6b-v3"
    static let displayName = "Ihnatov Parakeet UK"

    struct File: Sendable {
        let path: String
        let size: Int64
        let sha256: String
    }

    /// Every file in `remoteFolder` at `revision`.
    static let files: [File] = [
        File(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "975654ff914b8fc93383c76c965215a060a21c373cfa2826ecc8e205277160b2"),
        File(path: "Decoder.mlmodelc/coremldata.bin", size: 736, sha256: "c928606fb8b6639bb57aeaa2c34ef75239087559e279d11f149bc456e33f352a"),
        File(path: "Decoder.mlmodelc/metadata.json", size: 3655, sha256: "69bec396dbf01e6bdf6874ceef4df7e2efac0c61e7a6779b35ff275f2d4e79a1"),
        File(path: "Decoder.mlmodelc/model.mil", size: 13381, sha256: "71bf0c63a5e5c64391781c36fc7dd59534436a24abff6d1e7ae437d4c03f9c03"),
        File(path: "Decoder.mlmodelc/weights/weight.bin", size: 23_604_992, sha256: "dc10aaf4a610ca1ba0bce06ced35212af94d37e5c31d9010af688c3a32dfde6d"),
        File(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "b187a45a4ae9f7659e1a119308ac6bec73d07f8ed3ea1388b53513af3e17d997"),
        File(path: "Encoder.mlmodelc/coremldata.bin", size: 714, sha256: "fc6aa58ce0919f63cfe8af9e409af09d60bae5ebd43e910546b1ea98874ad954"),
        File(path: "Encoder.mlmodelc/metadata.json", size: 3308, sha256: "a6be50007cae89001301badfcb5d2db65648c86a8f3a6de1f3744bf2ab56d617"),
        File(path: "Encoder.mlmodelc/model.mil", size: 806_658, sha256: "eb39ed53106bc3b1940bc103a7efc2a49965098b8e7275afa7c29eceee9de822"),
        File(path: "Encoder.mlmodelc/weights/weight.bin", size: 594_214_208, sha256: "f0d6b06bd535a7e2293e95ba49e2fb1cd5367bf7432e796343805c182ae0d87c"),
        File(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "69e83ed1a989b89bf05cd655642fc99c97c309767f88b67b9e45dcab0ac3cdf5"),
        File(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 772, sha256: "fe54a2b01aaf722f008545555e2b9b16f32697f62bde1fc2e5b7cf2842a61847"),
        File(path: "JointDecisionv3.mlmodelc/metadata.json", size: 3803, sha256: "f18d9d727d95ed907ac8e10405f3e5be24115889a8d98bc8fb38975632edd670"),
        File(path: "JointDecisionv3.mlmodelc/model.mil", size: 11192, sha256: "044e49edd76ba6e73f5d137111c65db53e0339411ecdc1b6e5ca538c441af808"),
        File(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12_642_764, sha256: "9d1616589e686d104fd606c9030ebeecf1ceec052e0c14d551336dd111b7fb57"),
        File(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        File(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        File(path: "Preprocessor.mlmodelc/metadata.json", size: 2841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        File(path: "Preprocessor.mlmodelc/model.mil", size: 28181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        File(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491_072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
        File(path: "config.json", size: 339, sha256: "07d3bc4ae7ab48ca25f272a8cc59110b222628ee33ae870d127f40b266245f08"),
        File(path: "parakeet_v3_vocab.json", size: 151_122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        File(path: "parakeet_vocab.json", size: 151_122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
    ]

    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    // MARK: - Locations

    /// FluidAudio finds a v3 model in `<parent>/parakeet-tdt-0.6b-v3`, so
    /// the last component keeps the stock name. Under the durable models
    /// folder: out of Caches and out of Time Machine.
    static var parentDirectory: URL {
        ModelCatalog.durableModelsDirectory()
            .appendingPathComponent("ihnatov-yuri/parakeet-tdt-0.6b-v3-uk", isDirectory: true)
    }

    static var modelDirectory: URL {
        parentDirectory.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
    }

    private static var stagingDirectory: URL {
        parentDirectory.appendingPathComponent("download", isDirectory: true)
    }

    /// Stock Parakeet v3, where FluidAudio downloads it.
    static var stockDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3", isDirectory: true)
    }

    /// Written when an in-place install was moved out of the stock folder;
    /// the app reads it once to move the user's engine choices along.
    static var movedMarker: URL {
        parentDirectory.appendingPathComponent("moved-from-stock-folder")
    }

    // MARK: - Install state

    /// Every file present at its expected size. `config.json` is exempt: an
    /// install moved from the stock folder keeps its hand-written one.
    static func isInstalled(at dir: URL = modelDirectory) -> Bool {
        files.allSatisfy { f in
            let url = dir.appendingPathComponent(f.path)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else {
                return false
            }
            return f.path == "config.json" || size == f.size
        }
    }

    /// True when `dir/config.json` names this fine-tune. FluidAudio's
    /// recovery deletes a folder that fails to load and fills it from the
    /// STOCK repo; this tells the two apart afterwards.
    static func isFineTune(at dir: URL) -> Bool {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["model_name"] as? String
        else { return false }
        return name.hasSuffix("/parakeet-tdt-0.6b-v3-uk")
    }

    static func remoteURL(_ file: File) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(remoteFolder)/\(file.path)")!
    }

    // MARK: - Download

    /// Downloads the model unless it is installed. Files land in a staging
    /// folder first, each checked against its hash; the folder is moved into
    /// place only when complete. Verified files survive a failed attempt, so
    /// the next one only fetches what is missing.
    static func ensureDownloaded(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        migrateInPlaceInstall()
        if isInstalled() { return }
        let fm = FileManager.default
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        AppLog.info("parakeet-uk", "downloading \(repo) (\(totalBytes / 1_000_000) MB)…")
        var done: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let target = stagingDirectory.appendingPathComponent(file.path)
            if fm.fileExists(atPath: target.path) {
                if (try? ModelDownloader.sha256(of: target)) == file.sha256 {
                    done += file.size
                    continue
                }
                try? fm.removeItem(at: target)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if file.size > 50_000_000 {
                AppLog.info("parakeet-uk", "fetching \(file.path) (\(file.size / 1_000_000) MB)")
            }
            let (temp, response) = try await URLSession.shared.download(from: remoteURL(file))
            defer { try? fm.removeItem(at: temp) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw ASRError.modelLoadFailed(reason: "Parakeet UK download failed: HTTP \(code) for \(file.path)")
            }
            let actual = try ModelDownloader.sha256(of: temp)
            guard actual == file.sha256 else {
                AppLog.error("parakeet-uk", "checksum mismatch for \(file.path): got \(actual)")
                throw ASRError.modelLoadFailed(reason: "Parakeet UK: \(file.path) did not match its checksum — download discarded")
            }
            try fm.moveItem(at: temp, to: target)
            done += file.size
            progress?(Double(done) / Double(totalBytes))
        }
        if fm.fileExists(atPath: modelDirectory.path) { try fm.removeItem(at: modelDirectory) }
        try fm.moveItem(at: stagingDirectory, to: modelDirectory)
        AppLog.info("parakeet-uk", "downloaded to \(modelDirectory.path)")
    }

    // MARK: - In-place installs

    /// Before this engine existed the fine-tune was installed by hand OVER
    /// stock v3 in FluidAudio's folder, with the stock files moved to
    /// FluidAudio/Backups. Move it into its own folder, put stock back from
    /// the newest backup (or leave the slot empty for FluidAudio to fill),
    /// and leave a marker so the app moves the user's engine choices to the
    /// new engine. Runs once per process, before either engine loads.
    static func migrateInPlaceInstall() { _ = migrated }

    /// Engine choices that meant the in-place fine-tune: "parakeet-v3" (or
    /// unset, which defaults to it) now names stock again. Moves them to
    /// "parakeet-uk" once, so nothing quietly drops to stock. Called before
    /// the stores read their defaults.
    static func adoptMovedEngineChoices(_ defaults: UserDefaults = .standard) {
        migrateInPlaceInstall()
        guard FileManager.default.fileExists(atPath: movedMarker.path) else { return }
        remapEngineChoices(defaults)
        try? FileManager.default.removeItem(at: movedMarker)
        AppLog.info("parakeet-uk", "engine choices that used the in-place install now use Parakeet UK")
    }

    static func remapEngineChoices(_ defaults: UserDefaults) {
        let uk = BackendFactory.Kind.parakeetUK.rawValue
        let stock = BackendFactory.Kind.parakeet.rawValue
        // Unset means the default, which is stock v3 for these keys.
        for key in ["ui.defaultBackend", "ui.liveEngine", "ensemble.engineA", "dictation.engine"]
        where (defaults.string(forKey: key) ?? stock) == stock {
            defaults.set(uk, forKey: key)
        }
        // engineB defaults to Parakeet v2: only an explicit v3 moves.
        if defaults.string(forKey: "ensemble.engineB") == stock { defaults.set(uk, forKey: "ensemble.engineB") }
    }

    private static let migrated: Void = {
        // Never under the test host: it would move the user's real models.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let fm = FileManager.default
        let stock = stockDirectory
        guard isFineTune(at: stock) else { return }
        do {
            try fm.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            if isInstalled() {
                try fm.removeItem(at: stock)
                AppLog.info("parakeet-uk", "removed the in-place copy from the stock folder (already installed separately)")
            } else {
                if fm.fileExists(atPath: modelDirectory.path) { try fm.removeItem(at: modelDirectory) }
                try fm.moveItem(at: stock, to: modelDirectory)
                AppLog.info("parakeet-uk", "moved the in-place install to \(modelDirectory.path)")
            }
            fm.createFile(atPath: movedMarker.path, contents: nil)
            let backups = stock.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Backups", isDirectory: true)
            let newest = ((try? fm.contentsOfDirectory(atPath: backups.path)) ?? [])
                .filter { $0.hasPrefix("parakeet-tdt-0.6b-v3-stock") }
                .sorted()
                .last
            if let newest {
                let backup = backups.appendingPathComponent(newest, isDirectory: true)
                if !isFineTune(at: backup) {
                    try fm.moveItem(at: backup, to: stock)
                    AppLog.info("parakeet-uk", "restored stock Parakeet v3 from \(newest)")
                }
            }
        } catch {
            AppLog.error("parakeet-uk", "moving the in-place install failed: \(error.localizedDescription)")
        }
    }()
}
