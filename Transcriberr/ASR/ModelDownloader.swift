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

        // Delegate-driven, CHUNKED. `URLSession.bytes` hands back an
        // AsyncSequence of individual UInt8 values: on a 4.9 GB bundle that
        // is ~5 billion async-iteration steps (plus a `Task.checkCancellation`
        // and a `Data.append` each), which made the download CPU-bound rather
        // than network-bound. The delegate delivers whole Data chunks.
        let entryID = entry.id
        let fallbackTotal = entry.sizeBytes
        let written: Int64
        // One UI hop per 16 MB, not per network chunk.
        let reported = ByteCounter()
        do {
            written = try await StreamingDownload(handle: handle) { [weak self] got, expected in
                guard reported.shouldReport(got, every: 16 << 20) else { return }
                let total = expected > 0 ? expected : fallbackTotal
                Task { @MainActor in
                    self?.progress[entryID] = ProgressInfo(
                        bytesDownloaded: got, totalBytes: total, status: "Downloading…")
                }
            }.run(url: remote)
        } catch {
            // Every failure used to leave the Settings → Models row showing a
            // frozen "Downloading…" bar forever: only `isDownloading` was
            // cleaned up, never the status.
            try? handle.close()
            try? FileManager.default.removeItem(at: temp)
            let cancelled = error is CancellationError || (error as NSError).code == NSURLErrorCancelled
            progress[entry.id] = ProgressInfo(
                bytesDownloaded: 0, totalBytes: entry.sizeBytes,
                status: cancelled ? "Cancelled." : "Failed: \(error.localizedDescription)")
            AppLog.error("models", "direct download failed for \(entry.id): \(error.localizedDescription)")
            throw error
        }
        try handle.close()
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: temp)
            progress[entry.id] = ProgressInfo(bytesDownloaded: 0, totalBytes: entry.sizeBytes, status: "Cancelled.")
            throw CancellationError()
        }
        try FileManager.default.moveItem(at: temp, to: target)
        progress[entry.id] = ProgressInfo(
            bytesDownloaded: written,
            totalBytes: written > 0 ? written : entry.sizeBytes,
            status: "Downloaded.")
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

/// One streaming HTTP download into an open file handle, with progress.
/// A `URLSessionDataDelegate` rather than `URLSession.bytes` because the
/// latter iterates one byte at a time (see the call site), and a download
/// task rather than an in-memory `data(from:)` because these bundles are
/// multi-gigabyte.
private final class StreamingDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var cont: CheckedContinuation<Int64, Error>?
    private var settled = false
    private var pending: Result<Int64, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var written: Int64 = 0
    private var expected: Int64 = 0

    init(handle: FileHandle, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.handle = handle
        self.onProgress = onProgress
    }

    func run(url: URL) async throws -> Int64 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int64, Error>) in
                lock.lock()
                if let p = pending {
                    pending = nil
                    lock.unlock()
                    c.resume(with: p)
                    return
                }
                cont = c
                let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                session = s
                let t = s.dataTask(with: url)
                task = t
                lock.unlock()
                t.resume()
            }
        } onCancel: {
            lock.lock()
            let t = task
            lock.unlock()
            t?.cancel()
        }
    }

    private func settle(_ result: Result<Int64, Error>) {
        lock.lock()
        if settled { lock.unlock(); return }
        settled = true
        let c = cont
        cont = nil
        if c == nil { pending = result }
        let s = session
        lock.unlock()
        s?.finishTasksAndInvalidate()
        c?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            completionHandler(.cancel)
            settle(.failure(NSError(
                domain: "Transcriberr.ModelDownloader", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Download failed (HTTP \(code))"])))
            return
        }
        expected = response.expectedContentLength
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            onProgress(written, expected)
        } catch {
            dataTask.cancel()
            settle(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            settle(.failure(error))
        } else {
            settle(.success(written))
        }
    }
}

/// Throttle for download progress reporting — the delegate fires per network
/// chunk, which is far more often than a progress bar can use.
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64 = 0
    func shouldReport(_ current: Int64, every step: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current - last >= step else { return false }
        last = current
        return true
    }
}
