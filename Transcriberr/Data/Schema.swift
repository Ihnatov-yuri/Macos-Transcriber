import Foundation
import SwiftData

/// SwiftData equivalents of the Android Room entities in `data/Recording.kt`.
/// Field names and semantics are intentionally identical so the JSON / SRT
/// sidecars (and their `speakerName` round-trip) stay compatible.

/// Single source of truth for the model list — the app container, tests, and
/// the read-only KB layer must all open the store with the same schema.
enum TranscriberrSchema {
    static let models: [any PersistentModel.Type] = [
        Recording.self,
        Segment.self,
        OutputDoc.self,
        TranscriptVersion.self,
        PendingTask.self,
        Folder.self,
        Tag.self,
    ]
}

@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var title: String
    var audioPath: String
    var createdAtMillis: Int64
    var durationSeconds: Double
    var sourceLanguage: String?
    var transcribedWithBackend: String?
    var transcribedWithModel: String?
    var translateToEnglish: Bool

    // Per-recording RUN settings (nil = fall back to app defaults). Without
    // these, the run panel re-seeded from GLOBAL prefs on every open, so
    // tuning one recording silently changed what every other showed.
    var runBackend: String?
    var runLanguages: String?     // comma-joined
    var runDiarize: Bool?
    var runHybridDiarize: Bool?
    var runExpectedSpeakers: Int?
    var runSpeakersExact: Bool?
    /// User-entered speaker names (speakerKey → name), persisted so re-runs
    /// and version restores re-apply them automatically.
    var speakerNamesJSON: String?

    @Relationship(deleteRule: .cascade, inverse: \Segment.recording)
    var segments: [Segment] = []

    @Relationship(deleteRule: .cascade, inverse: \OutputDoc.recording)
    var outputs: [OutputDoc] = []

    @Relationship(deleteRule: .cascade, inverse: \TranscriptVersion.recording)
    var versions: [TranscriptVersion] = []

    // Library organization. Inverses are declared on Folder/Tag, so both
    // sides default to .nullify — deleting a Recording never touches shared
    // Folders or Tags, and vice versa.
    var folder: Folder?
    var tags: [Tag] = []

    init(
        id: UUID = UUID(),
        title: String,
        audioPath: String,
        createdAtMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        durationSeconds: Double = 0,
        sourceLanguage: String? = nil,
        transcribedWithBackend: String? = nil,
        transcribedWithModel: String? = nil,
        translateToEnglish: Bool = false
    ) {
        self.id = id
        self.title = title
        self.audioPath = audioPath
        self.createdAtMillis = createdAtMillis
        self.durationSeconds = durationSeconds
        self.sourceLanguage = sourceLanguage
        self.transcribedWithBackend = transcribedWithBackend
        self.transcribedWithModel = transcribedWithModel
        self.translateToEnglish = translateToEnglish
    }
}

@Model
final class Segment {
    @Attribute(.unique) var id: UUID
    var recording: Recording?
    var startSeconds: Double
    var endSeconds: Double
    var text: String
    var language: String?
    var speaker: String?       // "SPEAKER_00" etc.
    var speakerName: String?   // user-edited display name

    init(
        id: UUID = UUID(),
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        language: String? = nil,
        speaker: String? = nil,
        speakerName: String? = nil
    ) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.language = language
        self.speaker = speaker
        self.speakerName = speakerName
    }
}

/// Immutable snapshot of one completed transcription run — kept so different
/// engines' outputs on the same audio can be compared and restored.
@Model
final class TranscriptVersion {
    @Attribute(.unique) var id: UUID
    var recording: Recording?
    /// BackendFactory.Kind.rawValue that produced this version.
    var engineId: String
    /// Human label at snapshot time ("Parakeet v3 (local, ANE)", …).
    var engineLabel: String
    var createdAtMillis: Int64
    var segmentCount: Int
    /// JSON-encoded [VersionSegment] — see RecordingRepository.
    var segmentsJSON: String

    init(
        id: UUID = UUID(),
        engineId: String,
        engineLabel: String,
        createdAtMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        segmentCount: Int,
        segmentsJSON: String
    ) {
        self.id = id
        self.engineId = engineId
        self.engineLabel = engineLabel
        self.createdAtMillis = createdAtMillis
        self.segmentCount = segmentCount
        self.segmentsJSON = segmentsJSON
    }
}

@Model
final class OutputDoc {
    @Attribute(.unique) var id: UUID
    var recording: Recording?
    var presetId: String
    var title: String
    var markdown: String
    var createdAtMillis: Int64

    init(
        id: UUID = UUID(),
        presetId: String,
        title: String,
        markdown: String,
        createdAtMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.id = id
        self.presetId = presetId
        self.title = title
        self.markdown = markdown
        self.createdAtMillis = createdAtMillis
    }
}

/// Flat user-created folder; a recording lives in at most one.
/// `name` uniqueness is enforced case-insensitively in the repository, NOT
/// with `@Attribute(.unique)` — SwiftData unique constraints turn inserts
/// into silent upserts.
@Model
final class Folder {
    @Attribute(.unique) var id: UUID
    var name: String
    var sortOrder: Int
    var createdAtMillis: Int64

    @Relationship(deleteRule: .nullify, inverse: \Recording.folder)
    var recordings: [Recording] = []

    init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int = 0,
        createdAtMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAtMillis = createdAtMillis
    }
}

/// Free-form tag; many-to-many with Recording. Same repository-enforced
/// case-insensitive name uniqueness as Folder.
@Model
final class Tag {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAtMillis: Int64

    @Relationship(deleteRule: .nullify, inverse: \Recording.tags)
    var recordings: [Recording] = []

    init(
        id: UUID = UUID(),
        name: String,
        createdAtMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.id = id
        self.name = name
        self.createdAtMillis = createdAtMillis
    }
}

@Model
final class PendingTask {
    @Attribute(.unique) var recordingId: UUID
    var backend: String
    var languages: String          // CSV
    var translateTo: String?
    var diarize: Bool
    var expectedSpeakers: Int
    var hybridDiarize: Bool
    var waitForCharger: Bool       // kept for parity; unused on Mac
    var queuedAtMillis: Int64

    init(
        recordingId: UUID,
        backend: String,
        languages: String = "",
        translateTo: String? = nil,
        diarize: Bool = false,
        expectedSpeakers: Int = 0,
        hybridDiarize: Bool = false,
        waitForCharger: Bool = false,
        queuedAtMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.recordingId = recordingId
        self.backend = backend
        self.languages = languages
        self.translateTo = translateTo
        self.diarize = diarize
        self.expectedSpeakers = expectedSpeakers
        self.hybridDiarize = hybridDiarize
        self.waitForCharger = waitForCharger
        self.queuedAtMillis = queuedAtMillis
    }
}
