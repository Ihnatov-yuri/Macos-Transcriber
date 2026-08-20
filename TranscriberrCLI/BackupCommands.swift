import Foundation
import SwiftData

// `transcriberrcli restore-backups [--dry-run]` — re-inject every backup
// under BackupService.root into the live SwiftData store. Safe to re-run:
// a recording/version/output already present by id is left untouched, so
// this only ever fills in what's missing (after a corrupted store, an
// accidental delete, or a fresh machine).
//
// Unlike KBService, this opens the store WRITABLE (allowsSave: true) — it
// exists specifically to write, not just read.

@MainActor
func cmdRestoreBackups(dryRun: Bool) -> Int32 {
    let backups = BackupService.allRecordingBackups()
    guard !backups.isEmpty else {
        print("[restore] no backups found at \(BackupService.root.path)")
        return 0
    }

    let storeURL = KBService.defaultStoreURL()
    guard FileManager.default.fileExists(atPath: storeURL.path) else {
        print("[restore] ❌ no store at \(storeURL.path) — nothing to restore into")
        return 1
    }
    let schema = Schema(TranscriberrSchema.models)
    let config = ModelConfiguration("Transcriberr", schema: schema, url: storeURL, allowsSave: true)
    let container: ModelContainer
    do {
        container = try ModelContainer(for: schema, configurations: config)
    } catch {
        print("[restore] ❌ failed to open store: \(error.localizedDescription)")
        return 1
    }
    let context = ModelContext(container)

    func existingRecording(_ id: UUID) -> Recording? {
        (try? context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })))?.first
    }
    func existingVersion(_ id: UUID) -> Bool {
        (try? context.fetch(FetchDescriptor<TranscriptVersion>(predicate: #Predicate { $0.id == id })))?.isEmpty == false
    }
    func existingOutput(_ id: UUID) -> Bool {
        (try? context.fetch(FetchDescriptor<OutputDoc>(predicate: #Predicate { $0.id == id })))?.isEmpty == false
    }
    func findOrCreateFolder(named name: String) -> Folder {
        if let existing = (try? context.fetch(FetchDescriptor<Folder>()))?
            .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let sortOrder = ((try? context.fetch(FetchDescriptor<Folder>()))?.map(\.sortOrder).max() ?? -1) + 1
        let folder = Folder(name: name, sortOrder: sortOrder)
        context.insert(folder)
        return folder
    }
    func findOrCreateTag(named name: String) -> Tag {
        if let existing = (try? context.fetch(FetchDescriptor<Tag>()))?
            .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let tag = Tag(name: name)
        context.insert(tag)
        return tag
    }

    var recordingsRestored = 0, recordingsSkipped = 0
    var versionsRestored = 0, versionsSkipped = 0
    var outputsRestored = 0, outputsSkipped = 0

    for dto in backups.sorted(by: { $0.createdAtMillis < $1.createdAtMillis }) {
        var recording = existingRecording(dto.id)
        if recording == nil {
            recordingsRestored += 1
            print("[restore] \(dryRun ? "would restore" : "restoring") recording '\(dto.title)' (\(dto.id))")
            if !dryRun {
                let r = Recording(
                    id: dto.id, title: dto.title, audioPath: dto.audioPath,
                    createdAtMillis: dto.createdAtMillis, durationSeconds: dto.durationSeconds,
                    sourceLanguage: dto.sourceLanguage, transcribedWithBackend: dto.transcribedWithBackend,
                    transcribedWithModel: dto.transcribedWithModel, translateToEnglish: dto.translateToEnglish)
                r.speakerNamesJSON = dto.speakerNamesJSON
                if let folderName = dto.folderName { r.folder = findOrCreateFolder(named: folderName) }
                r.tags = dto.tagNames.map { findOrCreateTag(named: $0) }
                context.insert(r)
                for seg in dto.segments {
                    let s = Segment(startSeconds: seg.startSeconds, endSeconds: seg.endSeconds,
                                    text: seg.text, language: seg.language,
                                    speaker: seg.speaker, speakerName: seg.speakerName)
                    s.recording = r
                    context.insert(s)
                    r.segments.append(s)
                }
                recording = r
            }
        } else {
            recordingsSkipped += 1
        }

        for v in BackupService.versionBackups(for: dto.id) {
            if existingVersion(v.id) {
                versionsSkipped += 1
                continue
            }
            versionsRestored += 1
            print("[restore]   \(dryRun ? "would restore" : "restoring") version \(v.engineId) (\(v.id))")
            if !dryRun, let recording {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let payload = v.segments.map {
                    RecordingRepository.VersionSegment(start: $0.startSeconds, end: $0.endSeconds,
                                                        text: $0.text, speaker: $0.speaker,
                                                        speakerName: $0.speakerName)
                }
                let json = (try? encoder.encode(payload)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
                let tv = TranscriptVersion(id: v.id, engineId: v.engineId, engineLabel: v.engineLabel,
                                           createdAtMillis: v.createdAtMillis, segmentCount: v.segments.count,
                                           segmentsJSON: json)
                tv.recording = recording
                context.insert(tv)
                recording.versions.append(tv)
            }
        }

        // Outputs are backed up under a NEW id every time a preset is
        // regenerated (replaceOutput deletes the old live row but its
        // backup file is never pruned), so a preset regenerated more than
        // once leaves several outputs/*.json behind for the same presetId.
        // Restoring all of them would violate the app's own "one output per
        // preset" invariant (duplicate/stale entries in the outputs list) —
        // so only the newest backup per presetId is ever a restore
        // candidate, mirroring replaceOutput's delete-old-then-insert-new.
        let newestPerPreset = Dictionary(
            grouping: BackupService.outputBackups(for: dto.id), by: \.presetId
        ).compactMapValues { $0.max { $0.createdAtMillis < $1.createdAtMillis } }
        let alreadyHasPreset = Set((recording?.outputs ?? []).map(\.presetId))
        for o in newestPerPreset.values.sorted(by: { $0.createdAtMillis < $1.createdAtMillis }) {
            if existingOutput(o.id) || alreadyHasPreset.contains(o.presetId) {
                outputsSkipped += 1
                continue
            }
            outputsRestored += 1
            print("[restore]   \(dryRun ? "would restore" : "restoring") output \(o.presetId) (\(o.id))")
            if !dryRun, let recording {
                let od = OutputDoc(id: o.id, presetId: o.presetId, title: o.title,
                                   markdown: o.markdown, createdAtMillis: o.createdAtMillis)
                od.recording = recording
                context.insert(od)
                recording.outputs.append(od)
            }
        }
    }

    if !dryRun {
        do {
            try context.save()
        } catch {
            print("[restore] ❌ save failed: \(error.localizedDescription)")
            return 1
        }
    }

    print("""
    [restore] \(dryRun ? "DRY RUN — " : "")done.
      recordings: \(recordingsRestored) restored, \(recordingsSkipped) already present
      versions:   \(versionsRestored) restored, \(versionsSkipped) already present
      outputs:    \(outputsRestored) restored, \(outputsSkipped) already present
    """)
    return 0
}
