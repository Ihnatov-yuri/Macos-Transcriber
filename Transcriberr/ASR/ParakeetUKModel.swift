import Foundation
import CryptoKit
import FluidAudio
import os

/// Ihnatov Parakeet UK: Parakeet TDT 0.6B v3 fine-tuned for Ukrainian, as a
/// Core ML build on Hugging Face (`ihnatov-yuri/parakeet-tdt-0.6b-v3-uk`,
/// `coreml/int8/`). It runs on FluidAudio like stock v3 — same graph, same
/// vocabulary — but lives in its own folder so both engines can be installed
/// and picked side by side.
///
/// The repo's `main` branch is the current release: each new version is a
/// new commit. FluidAudio only downloads from FluidInference's repos, so this
/// type fetches the files itself. It resolves `main` to a commit, lists that
/// commit's files with Hugging Face's own checksums (SHA-256 for LFS files,
/// the git blob SHA-1 for the small ones), downloads every file from that
/// exact commit and checks it before use: the bundle is parsed by native
/// Core ML code in a process holding mic + Accessibility grants.
///
/// A newer version downloads in the background (with the user's update
/// consent, once a day) next to the one in use, and takes over at the next
/// launch, before any engine has opened the files.
enum ParakeetUKModel {
    static let repo = "ihnatov-yuri/parakeet-tdt-0.6b-v3-uk"
    static let branch = "main"
    static let remoteFolder = "coreml/int8/parakeet-tdt-0.6b-v3"
    static let displayName = "Ihnatov Parakeet UK"
    /// A release larger than this is refused (today's is about 630 MB).
    static let maxTotalBytes: Int64 = 1_500_000_000

    struct File: Codable, Sendable, Equatable {
        let path: String
        let size: Int64
        /// LFS files: Hugging Face's SHA-256 of the content.
        var sha256: String?
        /// Small files kept in git: the blob SHA-1 (`sha1("blob <size>\0" + content)`).
        var gitBlob: String?
    }

    /// One release: the commit and every file in `remoteFolder` at it.
    struct Manifest: Codable, Sendable, Equatable {
        let revision: String
        let files: [File]

        var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

        /// What FluidAudio loads, a hash for every file, sane paths and size.
        func validate() throws {
            let paths = Set(files.map(\.path))
            var missing = ["parakeet_vocab.json", "config.json"]
            for part in ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"] {
                missing += ["weights/weight.bin", "model.mil", "coremldata.bin"].map { "\(part).mlmodelc/\($0)" }
            }
            missing.removeAll(where: paths.contains)
            guard missing.isEmpty else { throw Self.invalid("missing \(missing.joined(separator: ", "))") }
            guard revision.count == 40, revision.allSatisfy(\.isHexDigit) else { throw Self.invalid("bad revision \(revision)") }
            for f in files {
                guard !f.path.isEmpty, !f.path.hasPrefix("/"), !f.path.split(separator: "/").contains("..") else {
                    throw Self.invalid("bad path \(f.path)")
                }
                guard (f.sha256?.count == 64) || (f.gitBlob?.count == 40) else { throw Self.invalid("no checksum for \(f.path)") }
            }
            guard totalBytes <= ParakeetUKModel.maxTotalBytes else { throw Self.invalid("\(totalBytes / 1_000_000) MB is too large") }
        }

        /// Same files, same content: a commit that only changed the model card.
        func sameFiles(as other: Manifest) -> Bool {
            Set(files.map(\.key)) == Set(other.files.map(\.key))
        }

        private static func invalid(_ why: String) -> ASRError {
            .modelLoadFailed(reason: "Parakeet UK release on Hugging Face is not usable: \(why)")
        }
    }

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

    /// First install: files collect here, then the folder becomes `modelDirectory`.
    private static var stagingDirectory: URL { parentDirectory.appendingPathComponent("download", isDirectory: true) }
    /// A newer release being fetched while the current one stays in use.
    private static var updateStagingDirectory: URL { parentDirectory.appendingPathComponent("update-download", isDirectory: true) }
    /// A complete newer release, waiting for the next launch.
    static var pendingDirectory: URL { parentDirectory.appendingPathComponent("update-ready", isDirectory: true) }

    static let manifestName = "release-manifest.json"

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

    static func manifest(at dir: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(manifestName)) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// The release a folder holds: every file of its manifest at its size.
    /// Installs from 4.7.0 and earlier have no manifest; they count as
    /// installed when FluidAudio's files are there, and the update check
    /// replaces them with the current release.
    static func isInstalled(at dir: URL = modelDirectory) -> Bool {
        let fm = FileManager.default
        func size(_ path: String) -> Int64? {
            (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(path).path))?[.size] as? Int64
        }
        if let m = manifest(at: dir) {
            return m.files.allSatisfy { size($0.path) == $0.size }
        }
        let legacy = ["config.json", "parakeet_vocab.json"] + ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"]
            .map { "\($0).mlmodelc/weights/weight.bin" }
        return legacy.allSatisfy { (size($0) ?? 0) > 0 }
    }

    /// The version the folder's config.json names (`uk_v4b`, …), for logs.
    /// Version 1 (4.7.0) wrote none.
    static func versionName(at dir: URL = modelDirectory) -> String {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "unknown" }
        return json["version"] as? String ?? "uk_v3"
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

    static func remoteURL(_ file: File, revision: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(remoteFolder)/\(file.path)")!
    }

    // MARK: - The current release on Hugging Face

    /// `main` resolved to a commit, and that commit's files with their checksums.
    static func fetchLatest() async throws -> Manifest {
        let rev = try await getJSON("https://huggingface.co/api/models/\(repo)/revision/\(branch)")
        guard let sha = (rev as? [String: Any])?["sha"] as? String else {
            throw ASRError.modelLoadFailed(reason: "Parakeet UK: Hugging Face did not name the current release")
        }
        let tree = try await getJSON("https://huggingface.co/api/models/\(repo)/tree/\(sha)/\(remoteFolder)?recursive=true")
        let m = try manifest(revision: sha, tree: tree)
        try m.validate()
        return m
    }

    /// Hugging Face's tree listing → the files under `remoteFolder`.
    static func manifest(revision: String, tree: Any) throws -> Manifest {
        guard let entries = tree as? [[String: Any]] else {
            throw ASRError.modelLoadFailed(reason: "Parakeet UK: unexpected file list from Hugging Face")
        }
        let prefix = remoteFolder + "/"
        let files: [File] = entries.compactMap { e in
            guard e["type"] as? String == "file", let path = e["path"] as? String, path.hasPrefix(prefix),
                  let size = (e["size"] as? NSNumber)?.int64Value else { return nil }
            let lfs = (e["lfs"] as? [String: Any])?["oid"] as? String
            return File(path: String(path.dropFirst(prefix.count)), size: size,
                        sha256: lfs, gitBlob: lfs == nil ? e["oid"] as? String : nil)
        }
        return Manifest(revision: revision, files: files.sorted { $0.path < $1.path })
    }

    /// Anonymous like the app's update check (UpdateChecker, which the CLI
    /// target does not have): no cookies, cache or credentials, and fixed
    /// headers that carry no build, CFNetwork, Darwin or locale details.
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCredentialStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpAdditionalHeaders = [:]
        return URLSession(configuration: cfg)
    }()

    static func request(for url: URL, timeout: TimeInterval = 20) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false
        req.setValue("Transcriberr", forHTTPHeaderField: "User-Agent")
        req.setValue("en", forHTTPHeaderField: "Accept-Language")
        return req
    }

    /// Automatic update checks at most this often.
    static let checkInterval: TimeInterval = 24 * 60 * 60

    private static func getJSON(_ url: String) async throws -> Any {
        let (data, response) = try await session.data(for: request(for: URL(string: url)!))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ASRError.modelLoadFailed(reason: "Parakeet UK: Hugging Face answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Git's blob hash, which Hugging Face reports for files not in LFS.
    static func gitBlobSHA1(of url: URL) throws -> String {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ file: File, at url: URL) -> Bool {
        if let sha = file.sha256 { return (try? ModelDownloader.sha256(of: url)) == sha }
        if let blob = file.gitBlob { return (try? gitBlobSHA1(of: url)) == blob }
        return false
    }

    // MARK: - Download

    /// Fetches `m` into `dir` from its commit, every file checked; the
    /// manifest is written last, so a folder with one is complete. Verified
    /// files survive a failed attempt, so the next one only fetches what is missing.
    static func download(_ m: Manifest, into dir: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        AppLog.info("parakeet-uk", "downloading \(repo) @ \(m.revision.prefix(8)) (\(m.totalBytes / 1_000_000) MB)…")
        var done: Int64 = 0
        for file in m.files {
            try Task.checkCancellation()
            let target = dir.appendingPathComponent(file.path)
            if fm.fileExists(atPath: target.path) {
                if matches(file, at: target) { done += file.size; continue }
                try? fm.removeItem(at: target)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if file.size > 50_000_000 { AppLog.info("parakeet-uk", "fetching \(file.path) (\(file.size / 1_000_000) MB)") }
            let (temp, response) = try await session.download(
                for: request(for: remoteURL(file, revision: m.revision), timeout: 120))
            defer { try? fm.removeItem(at: temp) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw ASRError.modelLoadFailed(reason: "Parakeet UK download failed: HTTP \(code) for \(file.path)")
            }
            guard matches(file, at: temp) else {
                AppLog.error("parakeet-uk", "checksum mismatch for \(file.path)")
                throw ASRError.modelLoadFailed(reason: "Parakeet UK: \(file.path) did not match its checksum — download discarded")
            }
            try fm.moveItem(at: temp, to: target)
            done += file.size
            progress?(Double(done) / Double(m.totalBytes))
        }
        guard isFineTune(at: dir) else {
            throw ASRError.modelLoadFailed(reason: "Parakeet UK: the release's config.json does not name the fine-tune")
        }
        try JSONEncoder().encode(m).write(to: dir.appendingPathComponent(manifestName), options: .atomic)
    }

    /// Before the engine loads: take over a waiting newer release, and
    /// download the current release when nothing is installed.
    static func ensureDownloaded(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        migrateInPlaceInstall()
        applyPendingUpdate()
        if isInstalled() { return }
        let m = try await fetchLatest()
        try await download(m, into: stagingDirectory, progress: progress)
        let fm = FileManager.default
        if fm.fileExists(atPath: modelDirectory.path) { try fm.removeItem(at: modelDirectory) }
        try fm.moveItem(at: stagingDirectory, to: modelDirectory)
        AppLog.info("parakeet-uk", "installed \(versionName()) (\(m.revision.prefix(8))) at \(modelDirectory.path)")
    }

    // MARK: - Updates

    /// Set once an engine has loaded the files in this process: from then on
    /// the folder is in use and a newer release waits for the next launch.
    private static let inUse = OSAllocatedUnfairLock(initialState: false)
    static func markInUse() { inUse.withLock { $0 = true } }

    /// A complete newer release replaces the current one, unless an engine
    /// in this process already opened the current files.
    static func applyPendingUpdate() {
        guard !inUse.withLock({ $0 }), let m = manifest(at: pendingDirectory), isInstalled(at: pendingDirectory) else { return }
        let fm = FileManager.default
        let old = parentDirectory.appendingPathComponent("replaced", isDirectory: true)
        do {
            try? fm.removeItem(at: old)
            if fm.fileExists(atPath: modelDirectory.path) { try fm.moveItem(at: modelDirectory, to: old) }
            try fm.moveItem(at: pendingDirectory, to: modelDirectory)
            try? fm.removeItem(at: old)
            AppLog.info("parakeet-uk", "now using \(versionName()) (\(m.revision.prefix(8)))")
        } catch {
            // Put the previous release back if the swap stopped halfway.
            if !fm.fileExists(atPath: modelDirectory.path), fm.fileExists(atPath: old.path) {
                try? fm.moveItem(at: old, to: modelDirectory)
            }
            AppLog.error("parakeet-uk", "switching to the new release failed: \(error.localizedDescription)")
        }
    }

    enum UpdateResult: Equatable { case notInstalled, upToDate, downloaded(String), failed(String) }

    /// Fetches a newer release next to the one in use, if there is one. Only
    /// for Macs that use Parakeet UK: a missing install is left to the first load.
    @discardableResult
    static func checkForUpdate() async -> UpdateResult {
        guard isInstalled() else { return .notInstalled }
        do {
            let latest = try await fetchLatest()
            let current = manifest(at: modelDirectory)
            if current?.revision == latest.revision { return .upToDate }
            if let current, current.sameFiles(as: latest) {
                // Only the model card changed: note the new commit, fetch nothing.
                try JSONEncoder().encode(Manifest(revision: latest.revision, files: current.files))
                    .write(to: modelDirectory.appendingPathComponent(manifestName), options: .atomic)
                return .upToDate
            }
            if manifest(at: pendingDirectory)?.revision == latest.revision, isInstalled(at: pendingDirectory) {
                return .downloaded(latest.revision)
            }
            let fm = FileManager.default
            // Files of an older half-finished update are not this release's.
            if let partial = manifest(at: updateStagingDirectory), partial.revision != latest.revision {
                try? fm.removeItem(at: updateStagingDirectory)
            }
            try await download(latest, into: updateStagingDirectory)
            try? fm.removeItem(at: pendingDirectory)
            try fm.moveItem(at: updateStagingDirectory, to: pendingDirectory)
            AppLog.info("parakeet-uk", "downloaded \(versionName(at: pendingDirectory)) (\(latest.revision.prefix(8))); it takes over at the next launch")
            return .downloaded(latest.revision)
        } catch {
            AppLog.info("parakeet-uk", "update check failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    private static let lastCheckKey = "parakeetUK.lastUpdateCheck"

    /// Once a day while the app runs, when the user allowed update checks.
    static func startUpdateLoop(allowed: @escaping @Sendable () async -> Bool) {
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
                if await allowed(), isInstalled(), Date().timeIntervalSince(last) >= checkInterval {
                    if case .failed = await checkForUpdate() {} else {
                        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
                    }
                }
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
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

private extension ParakeetUKModel.File {
    var key: String { "\(path)|\(size)|\(sha256 ?? "")|\(gitBlob ?? "")" }
}
