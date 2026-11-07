import CryptoKit
import Foundation
import Observation

/// Downloads the text models in `ModelCatalog`: every file of a pinned
/// commit, checksum-checked. Lets the UI observe per-model progress and
/// trigger cancels.
@Observable
nonisolated final class ModelDownloader: @unchecked Sendable {
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
    /// The attempt whose bytes are streaming now, per model. Progress hops
    /// are fire-and-forget and can land after the status moved on
    /// ("Verifying…", "Cancelled.", "Failed: …"); they only apply while
    /// their own attempt is still streaming.
    @ObservationIgnored private var streamingAttempt: [String: Int] = [:]
    @ObservationIgnored private var attemptCounter = 0

    init() {}

    // Main actor: `progress`, `isDownloading` and `activeTasks` are read by
    // SwiftUI and were being mutated from the download task's pool thread — a
    // dictionary data race. The bytes still arrive on URLSession's queue.
    @MainActor
    @discardableResult
    func download(_ entry: ModelEntry) async throws -> URL {
        // A second press while one is running would truncate the shared
        // `.partial` underneath the first writer. A cancelled one still
        // winding down is waited out: its cleanup deletes that `.partial`
        // and clears `isDownloading`, and on a quick restart both landed on
        // the new download.
        while let running = activeTasks[entry.id] {
            guard running.isCancelled else { return try await running.value }
            _ = await running.result
        }
        // Run inside a registered Task so cancel(id:) actually stops the byte
        // loop (before this, CANCEL left the loop running and a second press
        // could interleave two writers into one .partial file).
        //
        // The task unregisters itself, as its last step: cancel() leaves it
        // registered so a restart waits for its cleanup (see download), and
        // no other task can be registered under this id meanwhile.
        let task = Task<URL, Error> { @MainActor in
            defer { self.activeTasks.removeValue(forKey: entry.id) }
            isDownloading.insert(entry.id)
            defer { isDownloading.remove(entry.id) }
            progress[entry.id] = ProgressInfo(bytesDownloaded: 0, totalBytes: entry.sizeBytes, status: "Downloading…")
            do {
                let dir = try await self.downloadFiles(entry)
                progress[entry.id] = ProgressInfo(bytesDownloaded: entry.sizeBytes, totalBytes: entry.sizeBytes, status: "Downloaded.")
                AppLog.info("models", "\(entry.id) installed")
                return dir
            } catch {
                // Every failure used to leave the Settings → Models row
                // showing a frozen "Downloading…" bar forever.
                let cancelled = error is CancellationError || (error as NSError).code == NSURLErrorCancelled
                progress[entry.id] = ProgressInfo(
                    bytesDownloaded: 0, totalBytes: entry.sizeBytes,
                    status: cancelled ? "Cancelled." : "Failed: \(error.localizedDescription)")
                AppLog.error("models", "download failed for \(entry.id): \(error.localizedDescription)")
                throw error
            }
        }
        activeTasks[entry.id] = task
        return try await task.value
    }

    /// Every file of the entry's pinned commit into its folder, each checked
    /// against Hugging Face's checksum before it is moved into place (the
    /// weights are parsed by native code in a process holding mic +
    /// Accessibility grants). Files already there and matching are kept, so
    /// a cut-short download resumes file by file. The completion marker is
    /// written last.
    @MainActor
    private func downloadFiles(_ entry: ModelEntry) async throws -> URL {
        let dir = ModelCatalog.localDirectory(entry)
        let repo = entry.huggingFaceID, revision = entry.revision
        let fm = FileManager.default
        let marker = dir.appendingPathComponent(ModelCatalog.completeMarker)
        if fm.fileExists(atPath: marker.path) { return dir }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let entryID = entry.id
        var done: Int64 = 0
        for file in entry.files {
            try Task.checkCancellation()
            let target = dir.appendingPathComponent(file.path)
            if fm.fileExists(atPath: target.path) {
                progress[entry.id]?.status = "Checking \(file.path)…"
                if await Self.matchesDetached(file, at: target) { done += file.size; continue }
                try? fm.removeItem(at: target)
            }
            let remote = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
            let temp = target.appendingPathExtension("partial")
            // Nested files (Qwen's speculator/) need their folder: without it
            // createFile failed quietly and the open below threw every time.
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: temp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: temp)
            // Delegate-driven, CHUNKED. `URLSession.bytes` hands back an
            // AsyncSequence of individual UInt8 values: on a 5 GB file that
            // is ~5 billion async-iteration steps, which made the download
            // CPU-bound rather than network-bound.
            let reported = ByteCounter()
            attemptCounter += 1
            let attempt = attemptCounter
            streamingAttempt[entry.id] = attempt
            let base = done
            let total = entry.sizeBytes
            do {
                // A pinned file is its listed size: a server that streams
                // far more is refused as it arrives, not after it has filled
                // the disk.
                _ = try await StreamingDownload(handle: handle, maxBytes: Self.downloadCap(sizeBytes: file.size, pinned: true)) { [weak self] got, _ in
                    guard reported.shouldReport(got, every: 16 << 20) else { return }
                    Task { @MainActor in
                        guard let self, self.streamingAttempt[entryID] == attempt else { return }
                        self.progress[entryID] = ProgressInfo(bytesDownloaded: base + got, totalBytes: total, status: "Downloading…")
                    }
                }.run(url: remote)
                streamingAttempt[entry.id] = nil
                try handle.close()
            } catch {
                streamingAttempt[entry.id] = nil
                try? handle.close()
                try? fm.removeItem(at: temp)
                throw error
            }
            if Task.isCancelled {
                try? fm.removeItem(at: temp)
                throw CancellationError()
            }
            progress[entry.id] = ProgressInfo(bytesDownloaded: base + file.size, totalBytes: total, status: "Verifying \(file.path)…")
            guard await Self.matchesDetached(file, at: temp) else {
                try? fm.removeItem(at: temp)
                AppLog.error("models", "checksum mismatch for \(entry.id)/\(file.path)")
                throw NSError(domain: "Transcriberr.ModelDownloader", code: -6,
                              userInfo: [NSLocalizedDescriptionKey: "\(entry.name): \(file.path) did not match its checksum — download discarded."])
            }
            // The hash runs detached, so a cancel during it only shows here.
            if Task.isCancelled {
                try? fm.removeItem(at: temp)
                throw CancellationError()
            }
            try fm.moveItem(at: temp, to: target)
            done += file.size
        }
        for (path, content) in entry.generatedFiles {
            try Data(content.utf8).write(to: dir.appendingPathComponent(path), options: .atomic)
        }
        fm.createFile(atPath: marker.path, contents: Data(revision.utf8))
        return dir
    }

    nonisolated private static func matchesDetached(_ file: ModelEntry.File, at url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            if let sha = file.sha256 { return (try? sha256(of: url)) == sha }
            if let blob = file.gitBlob { return (try? HFModelRelease.gitBlobSHA1(of: url)) == blob }
            return false
        }.value
    }

    /// The most bytes a download of a `sizeBytes` catalog entry may bring:
    /// its size plus 5 % for a hash-pinned file (the hash decides the rest;
    /// the slack only covers a catalog size that is slightly off), twice it
    /// (and at least 64 MB) for one whose size is only an estimate.
    nonisolated static func downloadCap(sizeBytes: Int64, pinned: Bool) -> Int64 {
        let floor: Int64 = 64 << 20
        guard sizeBytes > 0 else { return floor }
        if pinned {
            let slack = max(sizeBytes / 20, 1 << 20)
            return sizeBytes > Int64.max - slack ? Int64.max : sizeBytes + slack
        }
        let doubled = sizeBytes.multipliedReportingOverflow(by: 2)
        return doubled.overflow ? Int64.max : max(doubled.partialValue, floor)
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The task stays registered until its own cleanup has run (see
    /// download); only the UI state is cleared here, at once.
    @MainActor
    func cancel(_ id: String) {
        activeTasks[id]?.cancel()
        streamingAttempt[id] = nil
        isDownloading.remove(id)
        progress[id]?.status = "Cancelled."
    }

    func isCached(_ entry: ModelEntry) -> Bool { ModelCatalog.isInstalled(entry) }

    /// The model's folder once installed.
    func localPath(_ entry: ModelEntry) -> URL? {
        guard isCached(entry) else { return nil }
        return ModelCatalog.localDirectory(entry)
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
nonisolated private final class StreamingDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private let maxBytes: Int64
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var cont: CheckedContinuation<Int64, Error>?
    private var settled = false
    private var pending: Result<Int64, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var written: Int64 = 0
    private var expected: Int64 = 0
    /// Set by the cancellation handler. On a task that is already cancelled
    /// the handler runs BEFORE the operation, when there is no data task yet
    /// to cancel — without this the download started anyway and ran to the
    /// end for a result nobody would keep.
    private var cancelled = false

    init(handle: FileHandle, maxBytes: Int64, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.handle = handle
        self.maxBytes = maxBytes
        self.onProgress = onProgress
    }


    private func tooLarge() -> NSError {
        NSError(domain: "Transcriberr.ModelDownloader", code: -7,
                userInfo: [NSLocalizedDescriptionKey: "Download is larger than the model it should be — discarded."])
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
                if cancelled {
                    settled = true
                    lock.unlock()
                    c.resume(throwing: CancellationError())
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
            cancelled = true
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
        guard expected <= maxBytes else {
            completionHandler(.cancel)
            settle(.failure(tooLarge()))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard written + Int64(data.count) <= maxBytes else {
            dataTask.cancel()
            settle(.failure(tooLarge()))
            return
        }
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
nonisolated private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64 = 0
    func shouldReport(_ current: Int64, every step: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current - last >= step else { return false }
        last = current
        return true
    }
}
