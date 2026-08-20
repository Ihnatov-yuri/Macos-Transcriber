import Foundation
import SwiftData
import AVFoundation

// `transcriberrcli migrate-audio [--dry-run]` — one-time migration of
// existing WAV recordings (made before v2.5.0 introduced post-record AAC
// compression) to .m4a, reusing the same verify-then-delete
// AudioCompressor.compressRecordingFiles path new recordings already go
// through. Opens the store WRITABLE (unlike KBService's read-only access)
// since it updates Recording.audioPath.

@MainActor
func cmdMigrateAudio(dryRun: Bool) async -> Int32 {
    let storeURL = KBService.defaultStoreURL()
    guard FileManager.default.fileExists(atPath: storeURL.path) else {
        print("[migrate] ❌ no store at \(storeURL.path)")
        return 1
    }
    let schema = Schema(TranscriberrSchema.models)
    let config = ModelConfiguration("Transcriberr", schema: schema, url: storeURL, allowsSave: true)
    let container: ModelContainer
    do {
        container = try ModelContainer(for: schema, configurations: config)
    } catch {
        print("[migrate] ❌ failed to open store: \(error.localizedDescription)")
        return 1
    }
    let context = ModelContext(container)
    guard let allRecordings = try? context.fetch(FetchDescriptor<Recording>()) else {
        print("[migrate] ❌ failed to fetch recordings")
        return 1
    }

    let wavRecordings = allRecordings
        .filter { URL(fileURLWithPath: $0.audioPath).pathExtension.lowercased() == "wav" }
        .sorted { $0.createdAtMillis < $1.createdAtMillis }

    guard !wavRecordings.isEmpty else {
        print("[migrate] nothing to do — no recordings reference a .wav file")
        reportOrphans(referencedPaths: Set(allRecordings.map(\.audioPath)))
        return 0
    }

    print("[migrate] \(wavRecordings.count) recording(s) reference a .wav file\(dryRun ? " — DRY RUN" : "")")

    var migrated = 0, failed = 0, missing = 0
    var bytesBefore: Int64 = 0, bytesAfter: Int64 = 0

    for rec in wavRecordings {
        let mainURL = URL(fileURLWithPath: rec.audioPath)
        guard FileManager.default.fileExists(atPath: mainURL.path) else {
            // Self-heal: the WAV may already have been migrated (its DB
            // update lost for some reason — e.g. a previous run against a
            // different store copy) while a valid .m4a with the same base
            // name sits right there. Verify it actually decodes before
            // trusting it, then just repoint — no need to re-transcode
            // something already done.
            let m4a = mainURL.deletingPathExtension().appendingPathExtension("m4a")
            if FileManager.default.fileExists(atPath: m4a.path),
               let d = try? await AVURLAsset(url: m4a).load(.duration), d.isValid, d.seconds > 0 {
                if dryRun {
                    print("[migrate]   would repoint '\(rec.title)' — WAV already gone, valid .m4a exists")
                    continue
                }
                rec.audioPath = m4a.path
                do {
                    try context.save()
                    print("[migrate]   ✓ '\(rec.title)' — WAV already gone, repointed to existing verified .m4a")
                    migrated += 1
                } catch {
                    print("[migrate]   ❌ '\(rec.title)' — found valid .m4a but failed to save: \(error.localizedDescription)")
                    failed += 1
                }
                continue
            }
            print("[migrate]   ⚠️ '\(rec.title)' — audioPath doesn't exist on disk, skipping")
            missing += 1
            continue
        }
        let sizeBefore = totalSize(for: mainURL)
        if dryRun {
            print("[migrate]   would migrate '\(rec.title)' (\(formatBytes(sizeBefore)))")
            bytesBefore += sizeBefore
            continue
        }
        let finalURL = await AudioCompressor.compressRecordingFiles(mainURL: mainURL, includeSidecars: true)
        if finalURL != mainURL {
            rec.audioPath = finalURL.path
            // Save after EVERY recording, not batched at the end: the files
            // are already transcoded-and-deleted on disk at this point, so
            // if the process is interrupted before a final save, an
            // end-of-loop-only save would lose every audioPath update made
            // so far while the underlying files are already gone as WAV —
            // a permanent DB/disk mismatch. Per-recording save keeps the
            // two in lockstep no matter when this gets interrupted.
            do {
                try context.save()
            } catch {
                print("[migrate] ❌ failed to save '\(rec.title)': \(error.localizedDescription) — stopping")
                return 1
            }
            let sizeAfter = totalSize(for: finalURL)
            bytesBefore += sizeBefore
            bytesAfter += sizeAfter
            migrated += 1
            print("[migrate]   ✓ '\(rec.title)' \(formatBytes(sizeBefore)) → \(formatBytes(sizeAfter))")
        } else {
            failed += 1
            bytesBefore += sizeBefore
            bytesAfter += sizeBefore
            print("[migrate]   ✗ '\(rec.title)' — compression failed, left as WAV (see ~/Library/Logs/Transcriberr)")
        }
    }

    if dryRun {
        print("[migrate] DRY RUN — would migrate \(wavRecordings.count) recording(s), \(formatBytes(bytesBefore)) of WAV audio")
    } else {
        let reclaimed = bytesBefore - bytesAfter
        print("[migrate] done — \(migrated) migrated, \(failed) failed, \(missing) missing on disk. \(formatBytes(bytesBefore)) → \(formatBytes(bytesAfter)) (reclaimed \(formatBytes(reclaimed)))")
    }

    reportOrphans(referencedPaths: Set(allRecordings.map(\.audioPath)))
    return failed > 0 ? 1 : 0
}

/// Every Recording's audioPath is tracked, but the Recordings folder can
/// hold .wav files nothing points at any more (an aborted merge, a stray
/// leftover) — report them for visibility without touching them; deleting
/// unreferenced files is a distinct, riskier decision this command doesn't
/// make on its own.
private func reportOrphans(referencedPaths: Set<String>) {
    let dir = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Transcriberr/Recordings", isDirectory: true)
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return }
    var orphanBytes: Int64 = 0
    var orphanCount = 0
    for f in files where f.pathExtension.lowercased() == "wav" {
        guard !referencedPaths.contains(f.path) else { continue }
        // Also not a sidecar of a referenced main file.
        let isSidecar = referencedPaths.contains { ref in
            AudioCompressor.sidecarKinds.contains { kind in
                URL(fileURLWithPath: ref).deletingPathExtension()
                    .appendingPathExtension("\(kind).wav").path == f.path
            }
        }
        guard !isSidecar else { continue }
        orphanCount += 1
        orphanBytes += fileSize(f)
    }
    if orphanCount > 0 {
        print("[migrate] note: \(orphanCount) .wav file(s) in Recordings (\(formatBytes(orphanBytes))) aren't referenced by any recording — left untouched; review manually if you want them gone.")
    }
}

private func totalSize(for mainURL: URL) -> Int64 {
    var total = fileSize(mainURL)
    for kind in AudioCompressor.sidecarKinds {
        if let sidecar = AudioCompressor.sidecarURL(for: mainURL, kind: kind) {
            total += fileSize(sidecar)
        }
    }
    return total
}

private func fileSize(_ url: URL) -> Int64 {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
    return (attrs[.size] as? Int64) ?? 0
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
