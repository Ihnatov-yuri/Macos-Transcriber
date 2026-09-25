import Foundation

/// Crash repair for the WAVs the recorders write.
///
/// AVAudioFile only fills in the RIFF and `data` chunk sizes when the file is
/// closed. A crash, a force quit or a power cut mid-recording leaves every
/// sample on disk but the header still saying "0 bytes of audio" (measured:
/// RIFF size = header only, `data` size = 0), so every reader — the player,
/// the decoder, afinfo — sees an empty file. The fix is mechanical: walk the
/// chunk list to the `data` chunk and rewrite both sizes from the file length.
///
/// Launch-time only. It rewrites headers in place, so it must never run over
/// a file a recorder has open: the caller snapshots the candidate list before
/// any capture can start and passes only files that existed then.
enum WavRepair {

    enum Outcome: Equatable {
        /// Sizes already agree with the file. Nothing written.
        case healthy
        /// `data` size rewritten from the file length — the crash signature.
        /// The file now reads `frames` frames.
        case repaired(frames: Int64, seconds: Double)
        /// Only the RIFF size was off; the audio was already readable.
        case riffSizeFixed
        /// Not a WAV this can fix (no `data`/`fmt ` chunk, RF64, unreadable).
        case unrepairable(String)
    }

    static var recordingsDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriberr/Recordings", isDirectory: true)
    }

    /// The recorders' own WAVs in `dir`: Recording_*.wav, meeting_*.wav and
    /// the meeting's .mic/.sys tracks. Imports, dictation clips and
    /// merge/split outputs are written in one go and left alone.
    static func candidates(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.lowercased().hasSuffix(".wav") && ($0.hasPrefix("Recording_") || $0.hasPrefix("meeting_")) }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    /// Repair every file in `urls` except `activePaths` (files open for
    /// recording right now). Returns only the ones that were rewritten.
    static func repairAll(_ urls: [URL], excluding activePaths: Set<String> = []) -> [(url: URL, seconds: Double)] {
        var repaired: [(url: URL, seconds: Double)] = []
        for url in urls where !activePaths.contains(url.standardizedFileURL.path) {
            switch repair(url) {
            case .healthy:
                break
            case .riffSizeFixed:
                AppLog.info("recover", "corrected the RIFF size of \(url.lastPathComponent)")
            case .repaired(let frames, let seconds):
                AppLog.warn("recover", "repaired the header of \(url.lastPathComponent) after an interrupted recording — \(frames) frames (\(String(format: "%.1f", seconds)) s)")
                repaired.append((url, seconds))
            case .unrepairable(let why):
                AppLog.warn("recover", "could not check \(url.lastPathComponent): \(why)")
            }
        }
        return repaired
    }

    /// Give crashed recordings a library row. The row is only ever created at
    /// Stop, so a recording that never reached Stop has none; one whose
    /// header needed repair is exactly that case. Only repaired MAIN files
    /// qualify — a healthy orphan is a recording the user deleted (deleting
    /// a row leaves its audio on disk), and must not come back.
    @MainActor
    static func importOrphans(_ repaired: [(url: URL, seconds: Double)], into repository: RecordingRepository) -> Int {
        let mains = repaired.filter {
            let name = $0.url.lastPathComponent.lowercased()
            // Under a second is a start that crashed at once, not a
            // recording anyone lost: repaired, but not put in the library.
            return !name.hasSuffix(".mic.wav") && !name.hasSuffix(".sys.wav") && $0.seconds >= 1
        }
        guard !mains.isEmpty, let rows = try? repository.all() else { return 0 }
        let known = Set(rows.map { URL(fileURLWithPath: $0.audioPath).deletingPathExtension().standardizedFileURL.path })
        let stamp = DateFormatter()
        stamp.dateStyle = .short
        stamp.timeStyle = .short
        var imported = 0
        for (url, seconds) in mains {
            guard !known.contains(url.deletingPathExtension().standardizedFileURL.path) else { continue }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let kind = url.lastPathComponent.hasPrefix("meeting_") ? "meeting" : "recording"
            let recording = Recording(
                title: "Recovered \(kind) \(stamp.string(from: created))",
                audioPath: url.path,
                createdAtMillis: Int64(created.timeIntervalSince1970 * 1000),
                durationSeconds: seconds)
            do {
                try repository.save(recording)
                imported += 1
                AppLog.info("recover", "added '\(recording.title)' to the library → \(url.lastPathComponent)")
            } catch {
                AppLog.error("recover", "could not add \(url.lastPathComponent) to the library: \(error.localizedDescription)")
            }
        }
        return imported
    }

    // MARK: - Header repair

    /// Rewrite the RIFF and `data` sizes of `url` from its length when they
    /// disagree. Chunks before `data` may come in any order (AVAudioFile
    /// writes JUNK, fmt, FLLR); the format may be PCM, IEEE float or
    /// WAVE_FORMAT_EXTENSIBLE — only `blockAlign` and the sample rate are
    /// needed. The data size is trimmed to whole frames (a partial trailing
    /// frame is cut off the file). Past 4 GB the 32-bit fields can't hold the
    /// length: the sizes are clamped to the largest whole-frame value that
    /// fits and the bytes beyond stay on disk untouched.
    static func repair(_ url: URL) -> Outcome {
        guard let handle = try? FileHandle(forUpdating: url) else { return .unrepairable("cannot open") }
        defer { try? handle.close() }
        guard let fileLength = try? handle.seekToEnd() else { return .unrepairable("cannot size") }
        guard fileLength >= 12,
              let head = read(handle, at: 0, count: 12), head.count == 12 else { return .unrepairable("too short") }
        let magic = String(decoding: head[0..<4], as: UTF8.self)
        guard String(decoding: head[8..<12], as: UTF8.self) == "WAVE" else { return .unrepairable("not a WAVE file") }
        guard magic == "RIFF" else { return .unrepairable(magic == "RF64" ? "RF64 is not handled" : "not a RIFF file") }
        let riffSize = UInt64(u32(head, 4))

        var blockAlign: UInt64 = 0
        var sampleRate: Double = 0
        var dataHeader: UInt64?
        var declaredData: UInt64 = 0
        var pos: UInt64 = 12
        while pos + 8 <= fileLength, let hdr = read(handle, at: pos, count: 8), hdr.count == 8 {
            let id = String(decoding: hdr[0..<4], as: UTF8.self)
            let size = UInt64(u32(hdr, 4))
            if id == "fmt ", size >= 16, let fmt = read(handle, at: pos + 8, count: 16), fmt.count == 16 {
                sampleRate = Double(u32(fmt, 4))
                blockAlign = UInt64(fmt[fmt.startIndex + 12]) | UInt64(fmt[fmt.startIndex + 13]) << 8
            }
            if id == "data" {
                dataHeader = pos
                declaredData = size
                break
            }
            let next = pos + 8 + size + (size & 1)
            guard next <= fileLength else { break }
            pos = next
        }
        guard let dataHeader else { return .unrepairable("no data chunk") }
        guard blockAlign > 0, sampleRate > 0 else { return .unrepairable("no usable fmt chunk") }

        let dataOffset = dataHeader + 8
        let available = fileLength - dataOffset
        // The declared size stands when it fits the file and whatever follows
        // it is a well-formed chunk run to EOF (a LIST after the audio, say).
        // A zero size with audio behind it is the crash signature itself.
        let declaredEnd = dataOffset + declaredData + (declaredData & 1)
        let dataOK = declaredData <= available
            && !(declaredData == 0 && available >= blockAlign)
            && chunkRunReachesEOF(handle, from: declaredEnd, fileLength: fileLength)

        let maxRIFF = UInt64(UInt32.max)
        if dataOK {
            let wantRIFF = min(fileLength - 8, maxRIFF)
            guard riffSize != wantRIFF else { return .healthy }
            guard write(handle, UInt32(wantRIFF), at: 4) else { return .unrepairable("write failed") }
            return .riffSizeFixed
        }

        var newData = available - available % blockAlign
        let maxData = maxRIFF - (dataOffset - 8)
        let clamped = newData > maxData
        if clamped { newData = maxData - maxData % blockAlign }
        let newEnd = dataOffset + newData
        guard write(handle, UInt32(newData), at: dataHeader + 4),
              write(handle, UInt32(newEnd - 8), at: 4) else { return .unrepairable("write failed") }
        if !clamped, newEnd < fileLength {
            try? handle.truncate(atOffset: newEnd)
        }
        try? handle.synchronize()
        let frames = Int64(newData / blockAlign)
        return .repaired(frames: frames, seconds: Double(frames) / sampleRate)
    }

    /// Whether the bytes from `start` to EOF parse as whole RIFF chunks with
    /// printable ids. Raw samples essentially never do.
    private static func chunkRunReachesEOF(_ handle: FileHandle, from start: UInt64, fileLength: UInt64) -> Bool {
        var p = start
        while p < fileLength {
            guard p + 8 <= fileLength, let hdr = read(handle, at: p, count: 8), hdr.count == 8,
                  hdr[hdr.startIndex..<hdr.startIndex + 4].allSatisfy({ (0x20...0x7E).contains($0) })
            else { return false }
            let size = UInt64(u32(hdr, 4))
            p += 8 + size + (size & 1)
        }
        return p == fileLength
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return try? handle.read(upToCount: count)
    }

    private static func write(_ handle: FileHandle, _ value: UInt32, at offset: UInt64) -> Bool {
        var le = value.littleEndian
        let bytes = Data(bytes: &le, count: 4)
        do {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: bytes)
            return true
        } catch {
            return false
        }
    }

    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        let i = d.startIndex + at
        return UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }
}
