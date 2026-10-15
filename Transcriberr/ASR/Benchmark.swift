import AVFoundation
import Foundation

/// The user's corrections, kept as a test set.
///
/// Every line the user edits and every transcript they mark as checked
/// becomes a reference: the audio of that stretch, cut to its own 16 kHz
/// WAVs so it survives re-runs, audio compression and deletion, next to the
/// text as the user left it and the text the engine wrote before anyone
/// touched it. Over weeks that is a set of real conversational speech in the
/// user's languages, checked by a human, which no public benchmark has for
/// Ukrainian meetings. Switching one disputed word does NOT make a line
/// checked: the user read one word, not the line.
///
/// A line from a split-track meeting keeps all three tracks of its stretch
/// (<clip>.wav, <clip>.mic.wav, <clip>.sys.wav), so a scoring run goes
/// through the same echo cancellation and split transcription as the real
/// meeting, and only the line's own side is scored.
///
/// Stored outside the database, next to the transcript backups (a re-run
/// wipes and re-creates a recording's segments, and a reference must
/// outlive that). `transcriberrcli bench` reads and scores it.
struct BenchmarkItem: Codable, Sendable, Identifiable, Equatable {
    /// The segment's id at the time it was checked.
    var id: UUID
    var recordingId: UUID
    var recordingTitle: String
    var language: String?
    var speaker: String?
    var start: Double
    var end: Double
    /// The text as the user approved it.
    var reference: String
    /// The text the engine wrote, before the first correction.
    var machine: String
    /// The backend that wrote `machine` ("ensemble", "parakeet-v3"…).
    var engine: String?
    /// Which side of a split-track clip the line is: "mic" (the user) or
    /// "sys" (everyone else); "mix" when the recording had one track.
    var track: String
    var checkedAt: Date
    /// File name of the clip, next to the item's JSON.
    var clip: String
}

enum Benchmark {
    static let padding = 0.25

    /// Inside the transcript backups' folder (Documents/Transcriberr
    /// Backups): never pruned, outside the live store and recordings, and
    /// in whatever backs up Documents.
    static var root: URL {
        BackupService.root.appendingPathComponent("benchmark", isDirectory: true)
    }

    static func url(for id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).json") }

    static func items(in dir: URL = root) -> [BenchmarkItem] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(BenchmarkItem.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.checkedAt, $0.start) < ($1.checkedAt, $1.start) }
    }

    static func existing(_ id: UUID, in dir: URL = root) -> BenchmarkItem? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: dir.appendingPathComponent("\(id.uuidString).json")))
            .flatMap { try? dec.decode(BenchmarkItem.self, from: $0) }
    }

    /// What `record` needs to know about one segment, copied off the
    /// SwiftData model on the main actor (the model must not cross threads).
    struct Source: Sendable {
        var segmentId: UUID
        var recordingId: UUID
        var recordingTitle: String
        var audioPath: String
        var language: String?
        var speaker: String?
        var start: Double
        var end: Double
        var text: String
        var engine: String?
    }

    @MainActor
    static func source(_ seg: Segment, in rec: Recording) -> Source {
        Source(segmentId: seg.id, recordingId: rec.id, recordingTitle: rec.title, audioPath: rec.audioPath,
               language: seg.language ?? rec.sourceLanguage, speaker: seg.speaker,
               start: seg.startSeconds, end: seg.endSeconds, text: seg.text, engine: rec.transcribedWithBackend)
    }

    /// Adds or updates the reference for one segment. `machine` is the text
    /// before this correction; for a segment already in the set the first
    /// machine text is kept, so later edits never turn the user's own words
    /// into "what the engine wrote". The clip is cut once.
    @discardableResult
    static func record(_ s: Source, machine: String, in dir: URL = root) async -> BenchmarkItem? {
        let reference = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty, s.end > s.start else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prior = existing(s.segmentId, in: dir)
        let tracks = clipSources(audioPath: s.audioPath)
        let track = tracks.count == 1 ? "mix" : (s.speaker == "ME" ? "mic" : "sys")
        var item = BenchmarkItem(
            id: s.segmentId, recordingId: s.recordingId, recordingTitle: s.recordingTitle,
            language: s.language, speaker: s.speaker, start: s.start, end: s.end,
            reference: reference, machine: prior?.machine ?? machine,
            engine: prior?.engine ?? s.engine, track: prior?.track ?? track,
            checkedAt: Date(), clip: prior?.clip ?? "\(s.segmentId.uuidString).wav")
        let clipURL = dir.appendingPathComponent(item.clip)
        if !FileManager.default.fileExists(atPath: clipURL.path) {
            // The same sample range of every track: the sidecars are kept
            // aligned with the mix, so the cut clips stay aligned too.
            let cut = await Task.detached(priority: .utility) { () -> [(String, [Float])]? in
                var out: [(String, [Float])] = []
                for (suffix, url) in tracks {
                    guard let clip = readRange(url, from: s.start - padding, to: s.end + padding), !clip.isEmpty
                    else { return nil }
                    out.append((suffix, clip))
                }
                return out
            }.value
            guard let cut else {
                AppLog.warn("bench", "could not cut a clip for segment @\(Int(s.start))s from \(URL(fileURLWithPath: s.audioPath).lastPathComponent)")
                return nil
            }
            let base = clipURL.deletingPathExtension()
            do {
                for (suffix, samples) in cut {
                    try writeWAV(samples, to: suffix.isEmpty ? clipURL : base.appendingPathExtension("\(suffix).wav"))
                }
            } catch { return nil }
            item.track = track
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(item) else { return nil }
        try? data.write(to: dir.appendingPathComponent("\(item.id.uuidString).json"), options: .atomic)
        return item
    }

    static func remove(_ id: UUID, in dir: URL = root) {
        guard let item = existing(id, in: dir) else { return }
        let clip = dir.appendingPathComponent(item.clip)
        for url in [clip, clip.deletingPathExtension().appendingPathExtension("mic.wav"),
                    clip.deletingPathExtension().appendingPathExtension("sys.wav")] {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id.uuidString).json"))
    }

    /// The tracks to cut, as (clip suffix, source): the mix alone, or for a
    /// split-track meeting the mix plus its "mic" and "sys" sidecars.
    static func clipSources(audioPath: String) -> [(String, URL)] {
        let main = URL(fileURLWithPath: audioPath)
        guard let mic = AudioCompressor.sidecarURL(for: main, kind: "mic"),
              let sys = AudioCompressor.sidecarURL(for: main, kind: "sys") else { return [("", main)] }
        return [("", main), ("mic", mic), ("sys", sys)]
    }

    /// Whether a scoring run's segment belongs to the item's side: on a
    /// split-track clip the other side's speech is in the audio too.
    static func onSide(speakerKey: String?, track: String) -> Bool {
        switch track {
        case "mic": return speakerKey == "ME"
        case "sys": return speakerKey != "ME"
        default: return true
        }
    }

    /// The 16 kHz mono samples of `from`…`to` seconds of an audio file,
    /// read by seeking: marking an hour-long meeting as checked cuts a few
    /// hundred lines, and decoding the whole file for each one took minutes
    /// and ~230 MB per decode.
    static func readRange(_ url: URL, from: Double, to: Double) -> [Float]? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let rate = f.processingFormat.sampleRate
        let first = AVAudioFramePosition(max(0, from) * rate)
        guard first < f.length, to > from else { return nil }
        let count = AVAudioFrameCount(min(f.length - first, AVAudioFramePosition((to - max(0, from)) * rate)))
        guard count > 0,
              let input = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: count),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioDecoder.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: f.processingFormat, to: target) else { return nil }
        f.framePosition = first
        do { try f.read(into: input, frameCount: count) } catch { return nil }
        let outCap = AVAudioFrameCount(Double(input.frameLength) * AudioDecoder.sampleRate / rate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inStatus in
            if fed { inStatus.pointee = .endOfStream; return nil }
            fed = true
            inStatus.pointee = .haveData
            return input
        }
        guard status != .error, let p = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: p, count: Int(output.frameLength)))
    }

    static func writeWAV(_ samples: [Float], to url: URL, sampleRate: Int = Int(AudioDecoder.sampleRate)) throws {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        d.reserveCapacity(d.count + samples.count * 2)
        for v in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32767))) }
        try d.write(to: url, options: .atomic)
    }

    // MARK: - Scoring

    /// Word errors (substitutions + deletions + insertions) of `hyp`
    /// against `ref`, on the same normalized words the vote uses, and the
    /// reference's word count.
    static func wordErrors(ref: String, hyp: String) -> (errors: Int, words: Int) {
        let r = TranscriptHygiene.normWords(ref), h = TranscriptHygiene.normWords(hyp)
        guard !r.isEmpty else { return (h.count, 0) }
        guard !h.isEmpty else { return (r.count, r.count) }
        var row = Array(0...h.count)
        for i in 1...r.count {
            var prev = row[0]
            row[0] = i
            for j in 1...h.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (r[i - 1] == h[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return (row[h.count], r.count)
    }

    struct Summary: Sendable, Equatable {
        var language: String
        var items: Int
        var seconds: Double
        var words: Int
        var errors: Int
        var wer: Double { words == 0 ? 0 : Double(errors) / Double(words) }
    }

    /// Per language: how much checked speech there is and how far the
    /// engine's own text was from what the user approved.
    static func summary(_ items: [BenchmarkItem]) -> [Summary] {
        var by: [String: Summary] = [:]
        for it in items {
            let lang = it.language ?? "Unknown"
            var s = by[lang] ?? Summary(language: lang, items: 0, seconds: 0, words: 0, errors: 0)
            let e = wordErrors(ref: it.reference, hyp: it.machine)
            s.items += 1; s.seconds += it.end - it.start; s.words += e.words; s.errors += e.errors
            by[lang] = s
        }
        return by.values.sorted { $0.seconds > $1.seconds }
    }
}
