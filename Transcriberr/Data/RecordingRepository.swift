import Foundation
import SwiftData

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
