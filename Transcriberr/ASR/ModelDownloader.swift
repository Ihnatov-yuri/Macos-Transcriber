import Foundation
import Observation

/// Thin coordinator that fronts Gemma4Swift's downloader (and, later,
/// FluidAudio's). Lets the UI observe per-model progress and trigger cancels.
@Observable
final class ModelDownloader: @unchecked Sendable {
    struct ProgressInfo: Sendable, Equatable {
        var bytesDownloaded: Int64
        var totalBytes: Int64
        var status: String
        var fractionComplete: Double {
            totalBytes > 0 ? Double(bytesDownloaded) / Double(totalBytes) : 0
        }
    }

    private(set) var progress: [String: ProgressInfo] = [:]
    private(set) var isDownloading: Set<String> = []

    private var activeTasks: [String: Task<URL, Error>] = [:]

    init() {}

    @discardableResult
    func download(_ entry: ModelEntry) async throws -> URL {
        // Single-file models (.litertlm bundles): direct streaming download —
        // a repo snapshot would pull every device-specific variant (~20 GB).
        if let direct = entry.directURL {
            return try await downloadDirect(entry, from: direct)
        }
        throw NSError(
            domain: "Transcriberr.ModelDownloader", code: -5,
            userInfo: [NSLocalizedDescriptionKey: "\(entry.name) has no direct download URL."]
        )
    }

    private func downloadDirect(_ entry: ModelEntry, from remote: URL) async throws -> URL {
        // Run inside a registered Task so cancel(id:) actually stops the byte
        // loop (before this, CANCEL left the loop running and a second press
        // could interleave two writers into one .partial file).
        let task = Task<URL, Error> { try await self.downloadDirectBody(entry, from: remote) }
        await MainActor.run { activeTasks[entry.id] = task }
        defer { Task { @MainActor in self.activeTasks.removeValue(forKey: entry.id) } }
        return try await task.value
    }

    private func downloadDirectBody(_ entry: ModelEntry, from remote: URL) async throws -> URL {
        guard let dir = directTargetDirectory(entry) else {
            throw NSError(domain: "Transcriberr.ModelDownloader", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "No cache path for \(entry.name)"])
        }
        let target = dir.appendingPathComponent(remote.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) { return dir }

        isDownloading.insert(entry.id)
        defer { isDownloading.remove(entry.id) }
        progress[entry.id] = ProgressInfo(bytesDownloaded: 0, totalBytes: entry.sizeBytes, status: "Downloading…")

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = target.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }

        let (bytes, response) = try await URLSession.shared.bytes(from: remote)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Transcriberr.ModelDownloader", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"])
        }
        let total = http.expectedContentLength > 0 ? http.expectedContentLength : entry.sizeBytes
        var buffer = Data(capacity: 4 << 20)
        var written: Int64 = 0
        var lastReport: Int64 = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= (4 << 20) {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if written - lastReport > (64 << 20) {
                    lastReport = written
                    let entryID = entry.id
                    let w = written
                    Task { @MainActor in
                        self.progress[entryID] = ProgressInfo(bytesDownloaded: w, totalBytes: total, status: "Downloading…")
                    }
                }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); written += Int64(buffer.count) }
        try handle.close()
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: temp)
            throw CancellationError()
        }
        try FileManager.default.moveItem(at: temp, to: target)
        progress[entry.id] = ProgressInfo(bytesDownloaded: written, totalBytes: total, status: "Downloaded.")
        AppLog.info("models", "direct download done: \(target.lastPathComponent) (\(written) bytes)")
        return dir
    }

    private func directTargetDirectory(_ entry: ModelEntry) -> URL? {
        guard let hfID = entry.huggingFaceID else { return nil }
        // Application Support, NOT Caches — macOS purges Caches under disk
        // pressure and has already evicted a 10 GB model this way.
        var dir = ModelCatalog.durableModelsDirectory()
        for part in hfID.split(separator: "/") { dir = dir.appendingPathComponent(String(part)) }
        return dir
    }

    func cancel(_ id: String) {
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
        isDownloading.remove(id)
        progress[id]?.status = "Cancelled."
    }

    func isCached(_ entry: ModelEntry) -> Bool {
        if let direct = entry.directURL {
            guard let dir = directTargetDirectory(entry) else { return false }
            return FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(direct.lastPathComponent).path)
        }
        return false
    }

    func localPath(_ entry: ModelEntry) -> URL? {
        if entry.directURL != nil {
            guard let dir = directTargetDirectory(entry), isCached(entry) else { return nil }
            return dir
        }
        return nil
    }

    /// Disk size of a downloaded model, in bytes (sum of every file in the
    /// model's directory). Returns nil if not downloaded.
    func diskSize(_ entry: ModelEntry) -> Int64? {
        guard let url = localPath(entry) else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return nil }
        var total: Int64 = 0
        for case let f as URL in enumerator {
            if let values = try? f.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize { total += Int64(size) }
        }
        return total > 0 ? total : nil
    }

    /// Remove a downloaded model directory from disk.
    @discardableResult
    func deleteCached(_ entry: ModelEntry) -> Bool {
        guard let url = localPath(entry) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            progress.removeValue(forKey: entry.id)
            AppLog.info("modeldl", "deleted \(entry.id) at \(url.path)")
            return true
        } catch {
            AppLog.error("modeldl", "delete failed for \(entry.id): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Internals
}
