import Foundation
import FluidAudio

/// Ihnatov Parakeet UK: Parakeet TDT 0.6B v3 fine-tuned for Ukrainian, as a
/// Core ML build on Hugging Face (`ihnatov-yuri/parakeet-tdt-0.6b-v3-uk`,
/// `coreml/int8/`). It runs on FluidAudio like stock v3 — same graph, same
/// vocabulary — but lives in its own folder so both engines can be installed
/// and picked side by side. FluidAudio only downloads from FluidInference's
/// repos, so the app fetches and updates it itself (`HFModelRelease`).
nonisolated enum ParakeetUKModel {
    static let release: HFModelRelease = {
        var parts = ["parakeet_vocab.json", "config.json"]
        for part in ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"] {
            parts += ["weights/weight.bin", "model.mil", "coremldata.bin"].map { "\(part).mlmodelc/\($0)" }
        }
        // FluidAudio finds a v3 model in `<parent>/parakeet-tdt-0.6b-v3`, so
        // the last component keeps the stock name. Under the durable models
        // folder: out of Caches and out of Time Machine.
        return HFModelRelease(
            repo: "ihnatov-yuri/parakeet-tdt-0.6b-v3-uk", remoteFolder: "coreml/int8/parakeet-tdt-0.6b-v3",
            displayName: "Parakeet UK", logTag: "parakeet-uk",
            maxTotalBytes: 1_500_000_000,  // today's release is about 630 MB
            requiredFiles: parts,
            parentDirectory: ModelCatalog.durableModelsDirectory()
                .appendingPathComponent("ihnatov-yuri/parakeet-tdt-0.6b-v3-uk", isDirectory: true),
            folderName: "parakeet-tdt-0.6b-v3",
            legacyVersion: "uk_v3")  // version 1 (4.7.0) wrote none
    }()

    static let displayName = "Ihnatov Parakeet UK"
    typealias File = HFModelRelease.File
    typealias Manifest = HFModelRelease.Manifest
    typealias UpdateResult = HFModelRelease.UpdateResult

    static var parentDirectory: URL { release.parentDirectory }
    static var modelDirectory: URL { release.modelDirectory }
    static var pendingDirectory: URL { release.pendingDirectory }

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

    static func manifest(at dir: URL) -> Manifest? { release.manifest(at: dir) }
    static func isInstalled(at dir: URL = modelDirectory) -> Bool { release.isInstalled(at: dir) }
    static func versionName(at dir: URL = modelDirectory) -> String { release.versionName(at: dir) }
    /// FluidAudio's recovery deletes a folder that fails to load and fills it
    /// from the STOCK repo; this tells the two apart afterwards.
    static func isFineTune(at dir: URL) -> Bool { release.isFineTune(at: dir) }
    static func remoteURL(_ file: File, revision: String) -> URL { release.remoteURL(file, revision: revision) }
    static func manifest(revision: String, tree: Any) throws -> Manifest { try release.manifest(revision: revision, tree: tree) }
    static func validate(_ m: Manifest) throws { try release.validate(m) }
    static func fetchLatest() async throws -> Manifest { try await release.fetchLatest() }
    static func gitBlobSHA1(of url: URL) throws -> String { try HFModelRelease.gitBlobSHA1(of: url) }
    static func matches(_ file: File, at url: URL) -> Bool { HFModelRelease.matches(file, at: url) }
    static func markInUse() { release.markInUse() }
    static func applyPendingUpdate() { release.applyPendingUpdate() }
    @discardableResult
    static func checkForUpdate() async -> UpdateResult { await release.checkForUpdate() }

    /// Before the engine loads: move a hand-made install out of the stock
    /// folder, take over a waiting newer release, download one if none.
    static func ensureDownloaded(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        migrateInPlaceInstall()
        try await release.ensureDownloaded(progress: progress)
    }

    /// Once a day while the app runs, when the user allowed update checks.
    static func startUpdateLoop(allowed: @escaping @Sendable () async -> Bool) {
        release.startUpdateLoop(lastCheckKey: "parakeetUK.lastUpdateCheck", allowed: allowed)
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
        for key in ["ui.defaultBackend", "ui.liveEngine", "dictation.engine"]
        where (defaults.string(forKey: key) ?? stock) == stock {
            defaults.set(uk, forKey: key)
        }
        // Super's pair defaults to Whisper + Parakeet UK: only an explicit stock v3 moves.
        for key in ["ensemble.engineA", "ensemble.engineB"] where defaults.string(forKey: key) == stock {
            defaults.set(uk, forKey: key)
        }
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
