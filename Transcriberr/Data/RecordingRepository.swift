import Foundation
import SwiftData
import AVFoundation

/// Mirror of `data/RecordingRepository.kt`.
/// Speaker-name persistence across re-transcription is preserved via an in-DB
/// snapshot built before `replaceSegments(...)` and a JSON sidecar.
final class RecordingRepository: @unchecked Sendable {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Reads

    func all() throws -> [Recording] {
        let descriptor = FetchDescriptor<Recording>(
            sortBy: [.init(\.createdAtMillis, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    func get(id: UUID) throws -> Recording? {
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    func search(query: String) throws -> [Recording] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return try all() }
        // SwiftData predicates with cross-relationship `contains` get
        // tricky; for now we do an in-memory filter on title + segments.text.
        let all = try all()
        return all.filter { rec in
            if rec.title.lowercased().contains(q) { return true }
            return rec.segments.contains { $0.text.lowercased().contains(q) }
        }
    }

    // MARK: - Writes

    /// Merge two recordings into a NEW one: audio concatenated (a then b),
    /// segments copied with b's timeline shifted by a's audio length and b's
    /// speaker keys remapped past a's so different people never collide
    /// ("SPEAKER_00" in each file is usually two different humans). "ME" is
    /// exempt — it is the same user in both recordings by definition.
    /// Originals are left untouched.
    func merge(_ a: Recording, _ b: Recording) async throws -> Recording {
        let decoder = AudioDecoder()
        let sa = try await decoder.decodeAll(file: URL(fileURLWithPath: a.audioPath))
        let sb = try await decoder.decodeAll(file: URL(fileURLWithPath: b.audioPath))
        let offsetSeconds = Double(sa.count) / AudioDecoder.sampleRate

        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: AudioDecoder.sampleRate,
                                      channels: 1, interleaved: false) else {
            throw NSError(domain: "Merge", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Audio format setup failed."])
        }
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriberr/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(
            "merged_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8)).wav")
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        for part in [sa, sb] {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                             frameCapacity: AVAudioFrameCount(part.count)) else { continue }
            buf.frameLength = AVAudioFrameCount(part.count)
            part.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress!, count: part.count)
            }
            try file.write(from: buf)
        }

        // Carry the meeting machinery. If BOTH sources have split tracks,
        // the merged recording is itself a full meeting: concatenate the
        // mic and sys tracks (padded/truncated to each half's mix length so
        // the shared timeline stays sample-exact) — a re-run then keeps ME
        // ground truth AND lets global diarization unify a colleague who
        // appears in both halves into one speaker.
        func sidecarURL(_ path: String, _ ext: String) -> URL {
            URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension(ext)
        }
        func aligned(_ samples: [Float], to count: Int) -> [Float] {
            if samples.count == count { return samples }
            if samples.count > count { return Array(samples.prefix(count)) }
            return samples + [Float](repeating: 0, count: count - samples.count)
        }
        func writeWav(_ parts: [[Float]], to target: URL) throws {
            let f = try AVAudioFile(forWriting: target, settings: fmt.settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
            for part in parts where !part.isEmpty {
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                                 frameCapacity: AVAudioFrameCount(part.count)) else { continue }
                buf.frameLength = AVAudioFrameCount(part.count)
                part.withUnsafeBufferPointer { src in
                    buf.floatChannelData![0].update(from: src.baseAddress!, count: part.count)
                }
                try f.write(from: buf)
            }
        }
        let fm = FileManager.default
        for ext in ["mic.wav", "sys.wav"] {
            let ua = sidecarURL(a.audioPath, ext)
            let ub = sidecarURL(b.audioPath, ext)
            guard fm.fileExists(atPath: ua.path), fm.fileExists(atPath: ub.path) else { continue }
            do {
                let ta = aligned(try await decoder.decodeAll(file: ua), to: sa.count)
                let tb = aligned(try await decoder.decodeAll(file: ub), to: sb.count)
                try writeWav([ta, tb], to: url.deletingPathExtension().appendingPathExtension(ext))
            } catch {
                // A bad sidecar must not fail the whole merge — the mix is
                // the recording; tracks are an optimization.
                AppLog.warn("repo", "skipping \(ext) tracks in merge: \(error.localizedDescription)")
                try? FileManager.default.removeItem(
                    at: url.deletingPathExtension().appendingPathExtension(ext))
            }
        }
        // Me-timeline: union of whatever sides have one, b's shifted.
        var meAll: [[Double]] = []
        if let d = try? Data(contentsOf: sidecarURL(a.audioPath, "me.json")),
           let iv = try? JSONDecoder().decode([[Double]].self, from: d) {
            meAll += iv.filter { $0.count == 2 }
        }
        if let d = try? Data(contentsOf: sidecarURL(b.audioPath, "me.json")),
           let iv = try? JSONDecoder().decode([[Double]].self, from: d) {
            meAll += iv.filter { $0.count == 2 }.map { [$0[0] + offsetSeconds, $0[1] + offsetSeconds] }
        }
        if !meAll.isEmpty, let data = try? JSONEncoder().encode(meAll) {
            try? data.write(to: url.deletingPathExtension().appendingPathExtension("me.json"))
        }

        let merged = Recording(
            title: "\(a.title) + \(b.title)",
            audioPath: url.path,
            durationSeconds: Double(sa.count + sb.count) / AudioDecoder.sampleRate
        )
        try save(merged)

        // Remap b's SPEAKER_NN keys past a's highest index.
        var maxIdx = -1
        for seg in a.segments {
            if let key = seg.speaker, key.hasPrefix("SPEAKER_"),
               let n = Int(key.dropFirst("SPEAKER_".count)) {
                maxIdx = max(maxIdx, n)
            }
        }
        func remap(_ key: String?) -> String? {
            guard let key else { return nil }
            guard key != "ME", key.hasPrefix("SPEAKER_"),
                  let n = Int(key.dropFirst("SPEAKER_".count)) else { return key }
            return String(format: "SPEAKER_%02d", n + maxIdx + 1)
        }

        var copies: [Segment] = []
        for seg in a.segments.sorted(by: { $0.startSeconds < $1.startSeconds }) {
            copies.append(Segment(startSeconds: seg.startSeconds, endSeconds: seg.endSeconds,
                                  text: seg.text, speaker: seg.speaker, speakerName: seg.speakerName))
        }
        for seg in b.segments.sorted(by: { $0.startSeconds < $1.startSeconds }) {
            copies.append(Segment(startSeconds: seg.startSeconds + offsetSeconds,
                                  endSeconds: seg.endSeconds + offsetSeconds,
                                  text: seg.text, speaker: remap(seg.speaker),
                                  speakerName: seg.speakerName))
        }
        // Persist the name map (remapped keys) so names survive re-runs of
        // the merged recording the same way they do on originals.
        var nameMap: [String: String] = [:]
        for seg in copies {
            if let k = seg.speaker, let n = seg.speakerName, nameMap[k] == nil { nameMap[k] = n }
        }
        if !nameMap.isEmpty, let data = try? JSONEncoder().encode(nameMap) {
            merged.speakerNamesJSON = String(decoding: data, as: UTF8.self)
        }
        if !copies.isEmpty {
            try appendSegments(copies, to: merged)
        }
        AppLog.info("repo", "merged '\(a.title)' + '\(b.title)' → \(url.lastPathComponent) (\(copies.count) segments)")
        return merged
    }

    func save(_ recording: Recording) throws {
        context.insert(recording)
        try context.save()
    }

    func delete(_ recording: Recording) throws {
        context.delete(recording)
        try context.save()
    }

    /// Append a chunk's worth of new segments to a recording (live transcribe).
    /// Carries over speaker-name mappings already on the recording.
    func appendSegments(_ segments: [Segment], to recording: Recording) throws {
        // uniquingKeysWith, NOT uniqueKeysWithValues — every segment of a
        // named speaker yields the same key and duplicate keys TRAP.
        let speakerNames: [String: String] = Dictionary(
            recording.segments
                .compactMap { seg -> (String, String)? in
                    guard let key = seg.speaker, let name = seg.speakerName, !name.isEmpty
                    else { return nil }
                    return (key, name)
                },
            uniquingKeysWith: { first, _ in first }
        )
        var names = speakerNames
        mergeStoredNames(recording, into: &names)
        for seg in segments {
            if let key = seg.speaker, seg.speakerName == nil {
                seg.speakerName = names[key]
            }
            seg.recording = recording
            context.insert(seg)
            recording.segments.append(seg)
        }
        try context.save()
    }

    /// Drop existing segments before a fresh transcribe run.
    func clearSegments(of recording: Recording) throws {
        for old in recording.segments { context.delete(old) }
        recording.segments = []
        try context.save()
    }

    /// Replace any segments fully contained in [start, end] with the new ones.
    /// Used by the second-pass refinement loop.
    func replaceSegmentsInRange(
        _ start: Double,
        _ end: Double,
        with newSegments: [Segment],
        for recording: Recording
    ) throws {
        let toDelete = recording.segments.filter {
            $0.startSeconds >= start && $0.endSeconds <= end
        }
        for old in toDelete {
            context.delete(old)
        }
        recording.segments.removeAll {
            $0.startSeconds >= start && $0.endSeconds <= end
        }

        // Re-apply speaker-name mappings (same as appendSegments).
        // uniquingKeysWith, NOT uniqueKeysWithValues — every segment of a
        // named speaker yields the same key and duplicate keys TRAP.
        let speakerNames: [String: String] = Dictionary(
            recording.segments
                .compactMap { seg -> (String, String)? in
                    guard let key = seg.speaker, let name = seg.speakerName, !name.isEmpty
                    else { return nil }
                    return (key, name)
                },
            uniquingKeysWith: { first, _ in first }
        )
        var rangeNames = speakerNames
        mergeStoredNames(recording, into: &rangeNames)
        for seg in newSegments {
            if let key = seg.speaker, seg.speakerName == nil {
                seg.speakerName = rangeNames[key]
            }
            seg.recording = recording
            context.insert(seg)
            recording.segments.append(seg)
        }
        try context.save()
    }

    /// Replace the entire transcript while preserving per-speaker user-edited names.
    func replaceSegments(_ segments: [Segment], for recording: Recording) throws {
        // uniquingKeysWith, NOT uniqueKeysWithValues — every segment of a
        // named speaker yields the same key and duplicate keys TRAP.
        let speakerNames: [String: String] = Dictionary(
            recording.segments
                .compactMap { seg -> (String, String)? in
                    guard let key = seg.speaker, let name = seg.speakerName, !name.isEmpty
                    else { return nil }
                    return (key, name)
                },
            uniquingKeysWith: { first, _ in first }
        )
        var names = speakerNames
        mergeStoredNames(recording, into: &names)

        for old in recording.segments {
            context.delete(old)
        }
        recording.segments = []

        for seg in segments {
            if let key = seg.speaker, seg.speakerName == nil {
                seg.speakerName = names[key]
            }
            seg.recording = recording
            context.insert(seg)
            recording.segments.append(seg)
        }
        try context.save()
    }

    func replaceOutput(_ doc: OutputDoc, for recording: Recording) throws {
        // delete any existing output for the same preset
        for old in recording.outputs where old.presetId == doc.presetId {
            context.delete(old)
        }
        doc.recording = recording
        context.insert(doc)
        recording.outputs.append(doc)
        try context.save()
    }

    // MARK: - Transcript versions

    /// Codable shape for TranscriptVersion.segmentsJSON.
    struct VersionSegment: Codable {
        var start: Double
        var end: Double
        var text: String
        var speaker: String?
        var speakerName: String?
    }

    /// Snapshot the recording's CURRENT transcript as an immutable version
    /// tagged with the engine that produced it. Called after a run completes,
    /// and defensively BEFORE a new run wipes the previous transcript.
    /// Deduplicates: identical content to the newest stored version is skipped.
    func snapshotVersion(of recording: Recording, engineId: String, engineLabel: String) throws {
        let sorted = recording.segments.sorted { $0.startSeconds < $1.startSeconds }
        guard !sorted.isEmpty else { return }
        let payload = sorted.map {
            VersionSegment(start: $0.startSeconds, end: $0.endSeconds, text: $0.text,
                           speaker: $0.speaker, speakerName: $0.speakerName)
        }
        let data = try JSONEncoder().encode(payload)
        if let newest = recording.versions.max(by: { $0.createdAtMillis < $1.createdAtMillis }),
           newest.segmentsJSON == String(decoding: data, as: UTF8.self) {
            AppLog.info("repo", "version snapshot skipped — identical to newest version")
            return
        }
        let version = TranscriptVersion(
            engineId: engineId,
            engineLabel: engineLabel,
            segmentCount: payload.count,
            segmentsJSON: String(decoding: data, as: UTF8.self)
        )
        version.recording = recording
        context.insert(version)
        recording.versions.append(version)
        try context.save()
        AppLog.info("repo", "version saved: \(engineId) · \(payload.count) segments")
    }

    func decodeVersion(_ version: TranscriptVersion) -> [VersionSegment] {
        (try? JSONDecoder().decode([VersionSegment].self,
                                   from: Data(version.segmentsJSON.utf8))) ?? []
    }

    /// Swap a stored version back in as the live transcript.
    func restoreVersion(_ version: TranscriptVersion, to recording: Recording) throws {
        let segs = decodeVersion(version).map {
            Segment(startSeconds: $0.start, endSeconds: $0.end, text: $0.text,
                    speaker: $0.speaker, speakerName: $0.speakerName)
        }
        try replaceSegments(segs, for: recording)
    }

    /// Self-heal after an interrupted run: a run wipes segments up-front and
    /// streams new ones in; if the app quit mid-run (update, crash), the
    /// recording is left with ZERO segments while its versions still hold the
    /// last good transcript. Restore the newest version for every such
    /// recording. Returns how many were healed.
    @discardableResult
    func healEmptyTranscripts() -> Int {
        guard let all = try? self.all() else { return 0 }
        var healed = 0
        for rec in all where rec.segments.isEmpty {
            guard let newest = rec.versions.max(by: { $0.createdAtMillis < $1.createdAtMillis })
            else { continue }
            if (try? restoreVersion(newest, to: rec)) != nil {
                healed += 1
                AppLog.info("repo", "healed empty transcript for '\(rec.title)' from \(newest.engineId) version (\(newest.segmentCount) segments)")
            }
        }
        return healed
    }

    func deleteVersion(_ version: TranscriptVersion, from recording: Recording) throws {
        recording.versions.removeAll { $0.id == version.id }
        context.delete(version)
        try context.save()
    }

    /// Stored user-entered name map (survives wipes; keys are stable for the
    /// same audio because clustering is deterministic).
    func storedSpeakerNames(_ recording: Recording) -> [String: String] {
        guard let js = recording.speakerNamesJSON,
              let map = try? JSONDecoder().decode([String: String].self, from: Data(js.utf8))
        else { return [:] }
        return map
    }

    private func mergeStoredNames(_ recording: Recording, into names: inout [String: String]) {
        for (k, v) in storedSpeakerNames(recording) where names[k] == nil { names[k] = v }
    }

    /// Fold one diarized speaker into another: every segment relabeled, the
    /// target's display name applied, the stored name map cleaned up. The
    /// two-click cure for the clusterer's last stubborn split.
    func mergeSpeakers(_ from: String, into target: String, in recording: Recording) throws {
        guard from != target else { return }
        let targetName = storedSpeakerNames(recording)[target]
            ?? recording.segments.first(where: { $0.speaker == target && $0.speakerName?.isEmpty == false })?.speakerName
        for seg in recording.segments where seg.speaker == from {
            seg.speaker = target
            seg.speakerName = targetName
        }
        var map = storedSpeakerNames(recording)
        map.removeValue(forKey: from)
        if let targetName { map[target] = targetName }
        if let data = try? JSONEncoder().encode(map) {
            recording.speakerNamesJSON = String(decoding: data, as: UTF8.self)
        }
        try context.save()
        AppLog.info("repo", "merged speaker \(from) → \(target) in '\(recording.title)'")
    }

    func setSpeakerName(_ name: String?, for speakerKey: String, in recording: Recording) throws {
        var map = storedSpeakerNames(recording)
        map[speakerKey] = name
        if let data = try? JSONEncoder().encode(map) {
            recording.speakerNamesJSON = String(decoding: data, as: UTF8.self)
        }
        try setSpeakerNameLegacy(name, for: speakerKey, in: recording)
    }

    private func setSpeakerNameLegacy(_ name: String?, for speakerKey: String, in recording: Recording) throws {
        for seg in recording.segments where seg.speaker == speakerKey {
            seg.speakerName = name
        }
        try context.save()
    }
}
