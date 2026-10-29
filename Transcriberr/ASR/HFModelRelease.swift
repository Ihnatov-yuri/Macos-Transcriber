import Foundation
import CryptoKit
import os

/// A Core ML model of our own on Hugging Face (`ihnatov-yuri/...`), fetched
/// and updated by the app itself: Parakeet UK and Whisper UK.
///
/// The repo's `main` branch is the current release: each new version is a
/// new commit. `main` is resolved to a commit, that commit's files are listed
/// with Hugging Face's own checksums (SHA-256 for LFS files, the git blob
/// SHA-1 for the small ones), and every file is downloaded from that exact
/// commit and checked before use: the bundle is parsed by native Core ML
/// code in a process holding mic + Accessibility grants.
///
/// A newer version downloads in the background (with the user's update
/// consent, once a day) next to the one in use, and takes over at the next
/// launch, before any engine has opened the files.
nonisolated struct HFModelRelease: Sendable {
    let repo: String
    let branch = "main"
    /// The folder in the repo the engine loads.
    let remoteFolder: String
    let displayName: String
    /// AppLog category.
    let logTag: String
    /// A release larger than this is refused.
    let maxTotalBytes: Int64
    /// Paths under `remoteFolder` the engine cannot load without.
    let requiredFiles: [String]
    /// Holds the model folder and the download / update folders beside it.
    let parentDirectory: URL
    /// The model folder's name inside `parentDirectory`.
    let folderName: String
    /// `config.json`'s "version" when it has none (releases from before it was written).
    let legacyVersion: String

    init(repo: String, remoteFolder: String, displayName: String, logTag: String, maxTotalBytes: Int64,
         requiredFiles: [String], parentDirectory: URL, folderName: String, legacyVersion: String = "unknown") {
        self.repo = repo
        self.remoteFolder = remoteFolder
        self.displayName = displayName
        self.logTag = logTag
        self.maxTotalBytes = maxTotalBytes
        self.requiredFiles = requiredFiles
        self.parentDirectory = parentDirectory
        self.folderName = folderName
        self.legacyVersion = legacyVersion
    }

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

        /// Same files, same content: a commit that only changed the model card.
        func sameFiles(as other: Manifest) -> Bool {
            Set(files.map(\.key)) == Set(other.files.map(\.key))
        }
    }

    /// What the engine loads, a hash for every file, sane paths and size.
    func validate(_ m: Manifest) throws {
        let paths = Set(m.files.map(\.path))
        let missing = requiredFiles.filter { !paths.contains($0) }
        guard missing.isEmpty else { throw invalid("missing \(missing.joined(separator: ", "))") }
        guard m.revision.count == 40, m.revision.allSatisfy(\.isHexDigit) else { throw invalid("bad revision \(m.revision)") }
        for f in m.files {
            guard !f.path.isEmpty, !f.path.hasPrefix("/"), !f.path.split(separator: "/").contains("..") else {
                throw invalid("bad path \(f.path)")
            }
            guard (f.sha256?.count == 64) || (f.gitBlob?.count == 40) else { throw invalid("no checksum for \(f.path)") }
        }
        guard m.totalBytes <= maxTotalBytes else { throw invalid("\(m.totalBytes / 1_000_000) MB is too large") }
    }

    private func invalid(_ why: String) -> ASRError {
        .modelLoadFailed(reason: "\(displayName) release on Hugging Face is not usable: \(why)")
    }

    // MARK: - Locations

    var modelDirectory: URL { parentDirectory.appendingPathComponent(folderName, isDirectory: true) }
    /// First install: files collect here, then the folder becomes `modelDirectory`.
    var stagingDirectory: URL { parentDirectory.appendingPathComponent("download", isDirectory: true) }
    /// A newer release being fetched while the current one stays in use.
    var updateStagingDirectory: URL { parentDirectory.appendingPathComponent("update-download", isDirectory: true) }
    /// A complete newer release, waiting for the next launch.
    var pendingDirectory: URL { parentDirectory.appendingPathComponent("update-ready", isDirectory: true) }

    static let manifestName = "release-manifest.json"

    // MARK: - Install state

    func manifest(at dir: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.manifestName)) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// The release a folder holds: every file of its manifest at its size.
    /// A folder without a manifest counts when the required files are there
    /// (Parakeet UK installs from 4.7.0 and earlier); the update check then
    /// replaces it with the current release.
    func isInstalled(at dir: URL? = nil) -> Bool {
        let dir = dir ?? modelDirectory
        let fm = FileManager.default
        func size(_ path: String) -> Int64? {
            (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(path).path))?[.size] as? Int64
        }
        if let m = manifest(at: dir) {
            return m.files.allSatisfy { size($0.path) == $0.size }
        }
        return requiredFiles.filter { $0.hasSuffix("weight.bin") || $0 == "config.json" }.allSatisfy { (size($0) ?? 0) > 0 }
    }

    /// The version the folder's config.json names (`uk_v4b`, `whisper_b1`, …), for logs.
    func versionName(at dir: URL? = nil) -> String {
        guard let data = try? Data(contentsOf: (dir ?? modelDirectory).appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "unknown" }
        return json["version"] as? String ?? legacyVersion
    }

    /// True when `dir/config.json` names this repo's model.
    func isFineTune(at dir: URL) -> Bool {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["model_name"] as? String,
              let repoName = repo.split(separator: "/").last
        else { return false }
        return name.hasSuffix("/\(repoName)")
    }

    func remoteURL(_ file: File, revision: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(remoteFolder)/\(file.path)")!
    }

    // MARK: - The current release on Hugging Face

    /// `main` resolved to a commit, and that commit's files with their checksums.
    func fetchLatest() async throws -> Manifest {
        let rev = try await getJSON("https://huggingface.co/api/models/\(repo)/revision/\(branch)")
        guard let sha = (rev as? [String: Any])?["sha"] as? String else {
            throw ASRError.modelLoadFailed(reason: "\(displayName): Hugging Face did not name the current release")
        }
        let tree = try await getJSON("https://huggingface.co/api/models/\(repo)/tree/\(sha)/\(remoteFolder)?recursive=true")
        let m = try manifest(revision: sha, tree: tree)
        try validate(m)
        return m
    }

    /// Hugging Face's tree listing → the files under `remoteFolder`.
    func manifest(revision: String, tree: Any) throws -> Manifest {
        guard let entries = tree as? [[String: Any]] else {
            throw ASRError.modelLoadFailed(reason: "\(displayName): unexpected file list from Hugging Face")
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

    private func getJSON(_ url: String) async throws -> Any {
        let (data, response) = try await Self.session.data(for: Self.request(for: URL(string: url)!))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ASRError.modelLoadFailed(reason: "\(displayName): Hugging Face answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
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
    @concurrent
    func download(_ m: Manifest, into dir: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        AppLog.info(logTag, "downloading \(repo) @ \(m.revision.prefix(8)) (\(m.totalBytes / 1_000_000) MB)…")
        var done: Int64 = 0
        for file in m.files {
            try Task.checkCancellation()
            let target = dir.appendingPathComponent(file.path)
            if fm.fileExists(atPath: target.path) {
                if Self.matches(file, at: target) { done += file.size; continue }
                try? fm.removeItem(at: target)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if file.size > 50_000_000 { AppLog.info(logTag, "fetching \(file.path) (\(file.size / 1_000_000) MB)") }
            let (temp, response) = try await Self.session.download(
                for: Self.request(for: remoteURL(file, revision: m.revision), timeout: 120))
            defer { try? fm.removeItem(at: temp) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw ASRError.modelLoadFailed(reason: "\(displayName) download failed: HTTP \(code) for \(file.path)")
            }
            guard Self.matches(file, at: temp) else {
                AppLog.error(logTag, "checksum mismatch for \(file.path)")
                throw ASRError.modelLoadFailed(reason: "\(displayName): \(file.path) did not match its checksum — download discarded")
            }
            try fm.moveItem(at: temp, to: target)
            done += file.size
            progress?(Double(done) / Double(m.totalBytes))
        }
        guard isFineTune(at: dir) else {
            throw ASRError.modelLoadFailed(reason: "\(displayName): the release's config.json does not name the fine-tune")
        }
        try JSONEncoder().encode(m).write(to: dir.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    /// Before the engine loads: take over a waiting newer release, and
    /// download the current release when nothing is installed.
    @concurrent
    func ensureDownloaded(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        applyPendingUpdate()
        if isInstalled() { return }
        let m = try await fetchLatest()
        try await download(m, into: stagingDirectory, progress: progress)
        let fm = FileManager.default
        if fm.fileExists(atPath: modelDirectory.path) { try fm.removeItem(at: modelDirectory) }
        try fm.moveItem(at: stagingDirectory, to: modelDirectory)
        AppLog.info(logTag, "installed \(versionName()) (\(m.revision.prefix(8))) at \(modelDirectory.path)")
    }

    // MARK: - Updates

    /// Set once an engine has loaded the files in this process: from then on
    /// the folder is in use and a newer release waits for the next launch.
    private let inUse = OSAllocatedUnfairLock(initialState: false)
    func markInUse() { inUse.withLock { $0 = true } }

    /// A complete newer release replaces the current one, unless an engine
    /// in this process already opened the current files.
    func applyPendingUpdate() {
        guard !inUse.withLock({ $0 }), let m = manifest(at: pendingDirectory), isInstalled(at: pendingDirectory) else { return }
        let fm = FileManager.default
        let old = parentDirectory.appendingPathComponent("replaced", isDirectory: true)
        do {
            try? fm.removeItem(at: old)
            if fm.fileExists(atPath: modelDirectory.path) { try fm.moveItem(at: modelDirectory, to: old) }
            try fm.moveItem(at: pendingDirectory, to: modelDirectory)
            try? fm.removeItem(at: old)
            AppLog.info(logTag, "now using \(versionName()) (\(m.revision.prefix(8)))")
        } catch {
            // Put the previous release back if the swap stopped halfway.
            if !fm.fileExists(atPath: modelDirectory.path), fm.fileExists(atPath: old.path) {
                try? fm.moveItem(at: old, to: modelDirectory)
            }
            AppLog.error(logTag, "switching to the new release failed: \(error.localizedDescription)")
        }
    }

    enum UpdateResult: Equatable { case notInstalled, upToDate, downloaded(String), failed(String) }

    /// Fetches a newer release next to the one in use, if there is one. Only
    /// for Macs that use the model: a missing install is left to the first load.
    @discardableResult
    @concurrent
    func checkForUpdate() async -> UpdateResult {
        guard isInstalled() else { return .notInstalled }
        do {
            let latest = try await fetchLatest()
            let current = manifest(at: modelDirectory)
            let fm = FileManager.default
            // Up to date: a release waiting from an earlier check is no longer
            // `main` (it was reverted) and must not take over at the next launch.
            if current?.revision == latest.revision {
                try? fm.removeItem(at: pendingDirectory)
                return .upToDate
            }
            if let current, current.sameFiles(as: latest) {
                // Only the model card changed: note the new commit, fetch nothing.
                try JSONEncoder().encode(Manifest(revision: latest.revision, files: current.files))
                    .write(to: modelDirectory.appendingPathComponent(Self.manifestName), options: .atomic)
                try? fm.removeItem(at: pendingDirectory)
                return .upToDate
            }
            if manifest(at: pendingDirectory)?.revision == latest.revision, isInstalled(at: pendingDirectory) {
                return .downloaded(latest.revision)
            }
            // Files of an older half-finished update are not this release's.
            if let partial = manifest(at: updateStagingDirectory), partial.revision != latest.revision {
                try? fm.removeItem(at: updateStagingDirectory)
            }
            try await download(latest, into: updateStagingDirectory)
            try? fm.removeItem(at: pendingDirectory)
            try fm.moveItem(at: updateStagingDirectory, to: pendingDirectory)
            AppLog.info(logTag, "downloaded \(versionName(at: pendingDirectory)) (\(latest.revision.prefix(8))); it takes over at the next launch")
            return .downloaded(latest.revision)
        } catch {
            AppLog.info(logTag, "update check failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    /// Once a day while the app runs, when the user allowed update checks.
    func startUpdateLoop(lastCheckKey: String, allowed: @escaping @Sendable () async -> Bool) {
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
                if await allowed(), isInstalled(), Date().timeIntervalSince(last) >= Self.checkInterval {
                    if case .failed = await checkForUpdate() {} else {
                        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
                    }
                }
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }
}

nonisolated private extension HFModelRelease.File {
    var key: String { "\(path)|\(size)|\(sha256 ?? "")|\(gitBlob ?? "")" }
}
