import Foundation
import SwiftData
import AVFoundation

// `transcriberrcli migrate-echo [--dry-run]` — one-time backfill: reruns
// offline echo cancellation (EchoCanceller via MeetingMixRebuilder) against
// every meeting recording whose .mic/.sys sidecars are still on disk,
// replacing the live-gated mix (recorded before v2.5.2) with a properly
// echo-cancelled one. Recordings made AFTER v2.5.2 already went through this
// at record time — rerunning it on them is a safe no-op, since
// EchoCanceller declines to touch audio it can't measurably improve (its own
// ERLE check), so this is safe to run more than once.

@MainActor
func cmdMigrateEcho(dryRun: Bool) async -> Int32 {
    let storeURL = KBService.defaultStoreURL()
    guard FileManager.default.fileExists(atPath: storeURL.path) else {
        print("[migrate-echo] ❌ no store at \(storeURL.path)")
        return 1
    }
    let schema = Schema(TranscriberrSchema.models)
    let config = ModelConfiguration("Transcriberr", schema: schema, url: storeURL, allowsSave: true)
    let container: ModelContainer
    do {
        container = try ModelContainer(for: schema, configurations: config)
    } catch {
        print("[migrate-echo] ❌ failed to open store: \(error.localizedDescription)")
        return 1
    }
    let context = ModelContext(container)
    guard let allRecordings = try? context.fetch(FetchDescriptor<Recording>()) else {
        print("[migrate-echo] ❌ failed to fetch recordings")
        return 1
    }

    let meetingRecordings = allRecordings
        .filter { rec in
            let mainURL = URL(fileURLWithPath: rec.audioPath)
            return AudioCompressor.sidecarURL(for: mainURL, kind: "mic") != nil
                && AudioCompressor.sidecarURL(for: mainURL, kind: "sys") != nil
        }
        .sorted { $0.createdAtMillis < $1.createdAtMillis }

    guard !meetingRecordings.isEmpty else {
        print("[migrate-echo] nothing to do — no recording has both mic/sys sidecars on disk")
        return 0
    }

    print("[migrate-echo] \(meetingRecordings.count) meeting recording(s) found\(dryRun ? " — DRY RUN" : "")")

    var rebuilt = 0, failed = 0

    for rec in meetingRecordings {
        let mainURL = URL(fileURLWithPath: rec.audioPath)
        guard FileManager.default.fileExists(atPath: mainURL.path) else {
            print("[migrate-echo]   ⚠️ '\(rec.title)' — audioPath doesn't exist on disk, skipping")
            failed += 1
            continue
        }
        if dryRun {
            print("[migrate-echo]   would rebuild '\(rec.title)'")
            continue
        }
        guard let rebuiltURL = await MeetingMixRebuilder.rebuildMix(mainURL: mainURL) else {
            print("[migrate-echo]   ✗ '\(rec.title)' — rebuild failed, left as-is (see ~/Library/Logs/Transcriberr)")
            failed += 1
            continue
        }
        // Re-reclaim disk space: rebuildMix always leaves a fresh .wav
        // behind (the old .m4a, if any, is already gone by the time this
        // returns), same as a fresh recording goes through at record time.
        let finalURL = await AudioCompressor.compressRecordingFiles(mainURL: rebuiltURL, includeSidecars: true)
        if finalURL.path != rec.audioPath {
            rec.audioPath = finalURL.path
            do {
                try context.save()
            } catch {
                print("[migrate-echo] ❌ failed to save '\(rec.title)': \(error.localizedDescription) — stopping")
                return 1
            }
        }
        rebuilt += 1
        print("[migrate-echo]   ✓ '\(rec.title)' rebuilt with offline echo cancellation")
    }

    if dryRun {
        print("[migrate-echo] DRY RUN — would rebuild \(meetingRecordings.count) recording(s)")
    } else {
        print("[migrate-echo] done — \(rebuilt) rebuilt, \(failed) failed")
    }
    return failed > 0 ? 1 : 0
}
