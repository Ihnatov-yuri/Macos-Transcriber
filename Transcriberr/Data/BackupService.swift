import Foundation

/// Best-effort, file-based shadow of every recording's transcript content —
/// independent of the single SwiftData store file so a corrupted/lost store
/// isn't the only copy of anything. Human-readable JSON, one folder per
/// recording, written additively (versions/outputs are immutable and never
/// overwritten) and NEVER pruned — including on Recording delete, since
/// surviving an accidental delete is exactly the point.
///
/// A write failure here must never fail the caller's real operation — every
/// entry point swallows its own errors and logs a warning.
enum BackupService {
    static let schemaVersion = 1

    /// A sibling of the project/recordings folder, not nested inside it —
    /// so losing or wiping ~/Documents/Transcriberr (code + live audio)
    /// doesn't take the transcript backups with it.
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["TRANSCRIBERR_BACKUP_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriberr Backups", isDirectory: true)
    }

    static func dir(for recordingId: UUID) -> URL {
        root.appendingPathComponent(recordingId.uuidString, isDirectory: true)
    }

    // MARK: - DTOs (self-contained; independent of the live schema so a
    // future model change can't silently break old backups)

    struct SegmentDTO: Codable {
        var startSeconds: Double
        var endSeconds: Double
        var text: String
        var language: String?
        var speaker: String?
        var speakerName: String?
    }

    struct RecordingDTO: Codable {
        var schemaVersion: Int
        var id: UUID
        var title: String
        var audioPath: String
        var createdAtMillis: Int64
        var durationSeconds: Double
        var sourceLanguage: String?
        var transcribedWithBackend: String?
        var transcribedWithModel: String?
        var translateToEnglish: Bool
        var speakerNamesJSON: String?
        var folderName: String?
        var tagNames: [String]
        var segments: [SegmentDTO]
    }

    struct VersionDTO: Codable {
        var schemaVersion: Int
        var id: UUID
        var recordingId: UUID
        var engineId: String
        var engineLabel: String
        var createdAtMillis: Int64
        var segments: [SegmentDTO]
    }

    struct OutputDTO: Codable {
        var schemaVersion: Int
        var id: UUID
        var recordingId: UUID
        var presetId: String
        var title: String
        var markdown: String
        var createdAtMillis: Int64
    }

    // MARK: - Write

    static func backupRecording(_ r: Recording) {
        let dto = RecordingDTO(
            schemaVersion: schemaVersion, id: r.id, title: r.title, audioPath: r.audioPath,
            createdAtMillis: r.createdAtMillis, durationSeconds: r.durationSeconds,
            sourceLanguage: r.sourceLanguage, transcribedWithBackend: r.transcribedWithBackend,
            transcribedWithModel: r.transcribedWithModel, translateToEnglish: r.translateToEnglish,
            speakerNamesJSON: r.speakerNamesJSON, folderName: r.folder?.name,
            tagNames: r.tags.map(\.name).sorted(),
            segments: r.segments.sorted { $0.startSeconds < $1.startSeconds }.map {
                SegmentDTO(startSeconds: $0.startSeconds, endSeconds: $0.endSeconds, text: $0.text,
                           language: $0.language, speaker: $0.speaker, speakerName: $0.speakerName)
            })
        write(dto, to: dir(for: r.id).appendingPathComponent("recording.json"))
    }

    /// Versions are immutable once snapshotted — skip if this id is already
    /// backed up rather than rewriting.
    static func backupVersion(id: UUID, recordingId: UUID, engineId: String, engineLabel: String,
                               createdAtMillis: Int64, segments: [RecordingRepository.VersionSegment]) {
        let url = dir(for: recordingId).appendingPathComponent("versions")
            .appendingPathComponent("\(id.uuidString).json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let dto = VersionDTO(
            schemaVersion: schemaVersion, id: id, recordingId: recordingId,
            engineId: engineId, engineLabel: engineLabel, createdAtMillis: createdAtMillis,
            segments: segments.map {
                SegmentDTO(startSeconds: $0.start, endSeconds: $0.end, text: $0.text,
                           language: nil, speaker: $0.speaker, speakerName: $0.speakerName)
            })
        write(dto, to: url)
    }

    static func backupOutput(_ doc: OutputDoc, recordingId: UUID) {
        let dto = OutputDTO(
            schemaVersion: schemaVersion, id: doc.id, recordingId: recordingId,
            presetId: doc.presetId, title: doc.title, markdown: doc.markdown,
            createdAtMillis: doc.createdAtMillis)
        write(dto, to: dir(for: recordingId).appendingPathComponent("outputs")
            .appendingPathComponent("\(doc.id.uuidString).json"))
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(value)
            // Atomic: a crash mid-write must never leave a half-written,
            // unparseable backup file behind.
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.warn("backup", "write failed for \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Read (used by the restore CLI command)

    static func allRecordingBackups() -> [RecordingDTO] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        return dirs.compactMap { d -> RecordingDTO? in
            let url = d.appendingPathComponent("recording.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(RecordingDTO.self, from: data)
        }
    }

    static func versionBackups(for recordingId: UUID) -> [VersionDTO] {
        let versionsDir = dir(for: recordingId).appendingPathComponent("versions")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: versionsDir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        return files.compactMap { try? decoder.decode(VersionDTO.self, from: Data(contentsOf: $0)) }
    }

    static func outputBackups(for recordingId: UUID) -> [OutputDTO] {
        let outputsDir = dir(for: recordingId).appendingPathComponent("outputs")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: outputsDir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        return files.compactMap { try? decoder.decode(OutputDTO.self, from: Data(contentsOf: $0)) }
    }
}
