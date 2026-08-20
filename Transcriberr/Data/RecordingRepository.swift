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
    @MainActor
    func merge(_ a: Recording, _ b: Recording) async throws -> Recording {
        // Chronological, not click order: the earlier-created recording is
        // the first half of the merged timeline — merging 9:03 "with" 9:01
        // must still play 9:01 first.
        var a = a, b = b
        if b.createdAtMillis < a.createdAtMillis { swap(&a, &b) }
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
        // Written via the writeWav(...) helper below (not inline) so the
        // AVAudioFile writer is GUARANTEED closed — by definite function-
        // return, not by hoping ARC releases a local at its last use —
        // before anything downstream (AudioCompressor) tries to read the
        // file back. AVAudioFile only finalizes a WAV's header (the
        // data-chunk size) when the writer deallocates; reading it any
        // earlier sees a truncated/zero-length file. Empirically
        // reproduced: reading immediately after write(), with the writer
        // still in scope, reports length 0 until the writer is released.
        try writeWav([sa, sb], to: url)

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
        for kind in ["mic", "sys"] {
            // AudioCompressor may have already transcoded either source's
            // sidecar to .m4a — check that before the pre-migration .wav.
            guard let ua = AudioCompressor.sidecarURL(for: URL(fileURLWithPath: a.audioPath), kind: kind),
                  let ub = AudioCompressor.sidecarURL(for: URL(fileURLWithPath: b.audioPath), kind: kind)
            else { continue }
            do {
                let ta = aligned(try await decoder.decodeAll(file: ua), to: sa.count)
                let tb = aligned(try await decoder.decodeAll(file: ub), to: sb.count)
                try writeWav([ta, tb], to: url.deletingPathExtension().appendingPathExtension("\(kind).wav"))
            } catch {
                // A bad sidecar must not fail the whole merge — the mix is
                // the recording; tracks are an optimization.
                AppLog.warn("repo", "skipping \(kind) tracks in merge: \(error.localizedDescription)")
                try? FileManager.default.removeItem(
                    at: url.deletingPathExtension().appendingPathExtension("\(kind).wav"))
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

        // Save with the WAV path FIRST — compressing before the row exists
        // would widen the crash/quit window between "audio written to
        // disk" and "the DB knows about it" from a few statements to a
        // real, multi-second async transcode.
        let merged = Recording(
            title: "\(a.title) + \(b.title)",
            audioPath: url.path,
            durationSeconds: Double(sa.count + sb.count) / AudioDecoder.sampleRate
        )
        // Stay where the sources live: merging inside a folder must not eject
        // the result to the unfiled root (a is the recording the merge was
        // initiated from, so its folder wins when the two disagree).
        merged.folder = a.folder ?? b.folder
        try save(merged)

        // Reclaim disk space now that every WAV involved is fully written
        // AND the recording is safely persisted.
        let finalURL = await AudioCompressor.compressRecordingFiles(mainURL: url, includeSidecars: true)
        if finalURL != url {
            try? updateAudioPath(finalURL, for: merged)
        }

        // Remap b's SPEAKER_NN keys past a's highest index.
        var maxIdx = -1
        for seg in a.segments {
            if let key = seg.speaker, key.hasPrefix("SPEAKER_"),
               let n = Int(key.dropFirst("SPEAKER_".count)) {
                maxIdx = max(maxIdx, n)
            }
        }
        var bMaxIdx = -1
        for seg in b.segments {
            if let key = seg.speaker, key.hasPrefix("SPEAKER_"),
               let n = Int(key.dropFirst("SPEAKER_".count)) {
                bMaxIdx = max(bMaxIdx, n)
            }
        }
        func remap(_ key: String?) -> String? {
            guard let key else { return nil }
            if key == "ME" { return key }               // same user in both
            if key.hasPrefix("SPEAKER_"), let n = Int(key.dropFirst("SPEAKER_".count)) {
                return String(format: "SPEAKER_%02d", n + maxIdx + 1)
            }
            if key == "GUEST" {
                // b's guest is (usually) a different human than a's guest —
                // give them a fresh key past everyone.
                return String(format: "SPEAKER_%02d", maxIdx + 1 + bMaxIdx + 1)
            }
            return key
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
        AppLog.info("repo", "merged '\(a.title)' + '\(b.title)' → \(finalURL.lastPathComponent) (\(copies.count) segments)")
        return merged
    }

    func save(_ recording: Recording) throws {
        context.insert(recording)
        try context.save()
        BackupService.backupRecording(recording)
    }

    /// Repoints an already-saved recording at a post-write compression
    /// result (WAV → AAC). Always called AFTER `save(_:)` for that
    /// recording, never before — compressing before the row exists would
    /// widen the crash window between "audio written to disk" and "the DB
    /// knows about it" from a few synchronous statements to a real,
    /// multi-second async transcode.
    func updateAudioPath(_ url: URL, for recording: Recording) throws {
        recording.audioPath = url.path
        try context.save()
        BackupService.backupRecording(recording)
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
        // No BackupService call here: this runs on @MainActor once per
        // transcription CHUNK (JobManager's stream loop) — a codebase this
        // sensitive to main-thread SwiftData work (see the @MainActor
        // comment on JobManager.runOne) shouldn't also pay a synchronous
        // JSON-encode-and-atomic-write per chunk. context.save() above
        // already gives the live DB the same crash durability every chunk;
        // the file backup only needs to capture the FINISHED, authoritative
        // transcript, which snapshotVersion's backupVersion call does at
        // the end of every run.
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
        // No BackupService call here either — same per-chunk MainActor hot
        // path as appendSegments (the refinement pass's second-pass swap).
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
        BackupService.backupRecording(recording)
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
        BackupService.backupOutput(doc, recordingId: recording.id)
    }

    // MARK: - Transcript versions

    /// Codable shape for TranscriptVersion.segmentsJSON.
    struct VersionSegment: Codable, Equatable {
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
        // A run calls this at most twice (rescue-snapshot the outgoing
        // transcript, then snapshot the finished one) — unlike
        // appendSegments/replaceSegmentsInRange, it's never a per-chunk hot
        // path, so it's the right place to also refresh recording.json with
        // the transcript's CURRENT state (title/folder/tags/segments),
        // independent of whether this particular version turns out to be a
        // dedup no-op below.
        defer { BackupService.backupRecording(recording) }
        let payload = sorted.map {
            VersionSegment(start: $0.startSeconds, end: $0.endSeconds, text: $0.text,
                           speaker: $0.speaker, speakerName: $0.speakerName)
        }
        // Canonical key order for storage. JSONEncoder's default key order is
        // NOT stable across encodes of the same value (it varies with heap
        // layout) — proven by a standalone reproduction: 131/150 duplicate
        // saves with string-compare dedup, 0/300 with content compare. That
        // instability — not SwiftData view staleness, as previously believed —
        // was the source of both the full-suite test flake and the
        // same-second duplicate versions in production logs.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(payload), as: UTF8.self)
        // Dedup by DECODED content, never by string equality: legacy rows
        // were stored with arbitrary key order and would never string-match.
        // Checked against both the relationship array and a store fetch
        // (tolerating a nil-hydrated inverse) — either view seeing the
        // duplicate is enough.
        let recID = recording.persistentModelID
        let fetched = (try? context.fetch(FetchDescriptor<TranscriptVersion>())) ?? []
        let dup = recording.versions.contains { decodeVersion($0) == payload }
            || fetched.contains {
                ($0.recording == nil || $0.recording?.persistentModelID == recID)
                    && decodeVersion($0) == payload
            }
        if dup {
            AppLog.info("repo", "version snapshot skipped — identical version exists")
            return
        }
        let version = TranscriptVersion(
            engineId: engineId,
            engineLabel: engineLabel,
            segmentCount: payload.count,
            segmentsJSON: json
        )
        version.recording = recording
        context.insert(version)
        recording.versions.append(version)
        try context.save()
        BackupService.backupVersion(id: version.id, recordingId: recording.id, engineId: engineId,
                                     engineLabel: engineLabel, createdAtMillis: version.createdAtMillis,
                                     segments: payload)
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
        BackupService.backupRecording(recording)
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
        BackupService.backupRecording(recording)
    }

    // MARK: - Folders

    enum OrganizeError: LocalizedError {
        case emptyName
        case duplicateName(String)

        var errorDescription: String? {
            switch self {
            case .emptyName: return "Name cannot be empty."
            case .duplicateName(let n): return "'\(n)' already exists."
            }
        }
    }

    func folders() throws -> [Folder] {
        let descriptor = FetchDescriptor<Folder>(
            sortBy: [.init(\.sortOrder), .init(\.name)]
        )
        return try context.fetch(descriptor)
    }

    @discardableResult
    func createFolder(named name: String) throws -> Folder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OrganizeError.emptyName }
        let existing = try folders()
        if existing.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw OrganizeError.duplicateName(trimmed)
        }
        let folder = Folder(name: trimmed,
                            sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1)
        context.insert(folder)
        try context.save()
        return folder
    }

    func renameFolder(_ folder: Folder, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OrganizeError.emptyName }
        if try folders().contains(where: {
            $0.id != folder.id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            throw OrganizeError.duplicateName(trimmed)
        }
        folder.name = trimmed
        try context.save()
    }

    /// Recordings survive (nullify delete rule clears their `folder`).
    func deleteFolder(_ folder: Folder) throws {
        context.delete(folder)
        try context.save()
    }

    /// nil = remove from its folder.
    func move(_ recording: Recording, to folder: Folder?) throws {
        recording.folder = folder
        try context.save()
        BackupService.backupRecording(recording)
    }

    // MARK: - Tags

    func tags() throws -> [Tag] {
        let descriptor = FetchDescriptor<Tag>(sortBy: [.init(\.name)])
        return try context.fetch(descriptor)
    }

    /// Find-or-create by trimmed, case-insensitive name; no-op if already applied.
    @discardableResult
    func addTag(named name: String, to recording: Recording) throws -> Tag {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OrganizeError.emptyName }
        let tag: Tag
        if let existing = try tags().first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            tag = existing
        } else {
            tag = Tag(name: trimmed)
            context.insert(tag)
        }
        if !recording.tags.contains(where: { $0.id == tag.id }) {
            recording.tags.append(tag)
        }
        try context.save()
        BackupService.backupRecording(recording)
        return tag
    }

    /// Removing the last usage deletes the orphaned Tag so the tag namespace
    /// stays tidy.
    func removeTag(_ tag: Tag, from recording: Recording) throws {
        recording.tags.removeAll { $0.id == tag.id }
        if tag.recordings.isEmpty {
            context.delete(tag)
        }
        try context.save()
        BackupService.backupRecording(recording)
    }

    /// Diff-based bulk edit: applies exactly `names` (find-or-create each),
    /// removing anything else and pruning orphans.
    func setTags(_ names: [String], on recording: Recording) throws {
        let wanted = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let current = recording.tags
        let stale = current.filter { tag in
            !wanted.contains { $0.caseInsensitiveCompare(tag.name) == .orderedSame }
        }
        for tag in stale {
            try removeTag(tag, from: recording)
        }
        for name in wanted {
            try addTag(named: name, to: recording)
        }
    }
}
