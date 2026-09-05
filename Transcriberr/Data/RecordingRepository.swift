import Foundation
import SwiftData
import AVFoundation

/// Mirror of `data/RecordingRepository.kt`.
/// Speaker-name persistence across re-transcription is preserved via an in-DB
/// snapshot built before `replaceSegments(...)` and a JSON sidecar.
final class RecordingRepository: @unchecked Sendable {
    private let context: ModelContext
    private let postProcessTracker: AudioPostProcessTracker

    init(context: ModelContext, postProcessTracker: AudioPostProcessTracker = AudioPostProcessTracker()) {
        self.context = context
        self.postProcessTracker = postProcessTracker
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

    // MARK: Shared merge()/split() audio helpers

    /// `<base>.<ext>` sibling of `path` — e.g. the `.mic.wav` or `.me.json`
    /// sidecar path for a recording's main audio file.
    private func sidecarPath(_ path: String, _ ext: String) -> URL {
        URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension(ext)
    }

    /// Pad with silence or truncate `samples` to exactly `count` — sidecar
    /// tracks are independently recorded streams and can drift a handful of
    /// samples from the mix they're meant to align with.
    private func aligned(_ samples: [Float], to count: Int) -> [Float] {
        if samples.count == count { return samples }
        if samples.count > count { return Array(samples.prefix(count)) }
        return samples + [Float](repeating: 0, count: count - samples.count)
    }

    /// Concatenates `parts` (in order) into a fresh mono WAV at `target`.
    /// The AVAudioFile writer is GUARANTEED closed — by definite function-
    /// return, not by hoping ARC releases a local at its last use — before
    /// anything downstream (AudioCompressor, a caller re-reading the file)
    /// tries to read it back. AVAudioFile only finalizes a WAV's header (the
    /// data-chunk size) when the writer deallocates; reading it any earlier
    /// sees a truncated/zero-length file. Empirically reproduced: reading
    /// immediately after write(), with the writer still in scope, reports
    /// length 0 until the writer is released.
    private func writeWav(_ parts: [ArraySlice<Float>], to target: URL, format fmt: AVAudioFormat) throws {
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

    /// Extracts `[startSeconds, endSeconds)` from `source` into a fresh file
    /// and atomically swaps it in for whatever is currently at `replacing`
    /// — WITHOUT decoding or re-encoding, a bitstream-level trim (`.passthrough`
    /// export). Only usable when `source` is itself already AAC-compressed;
    /// see the call site's doc comment for why this exists and the measured
    /// quality difference. Returns `false` (never throws) on any failure —
    /// export unavailable for this asset, a corrupt/unusual source file,
    /// disk error — leaving the file at `replacing` completely untouched:
    /// the swap only happens via `FileManager.replaceItemAt`, and only
    /// after the trimmed file is fully written to a scratch path, so a
    /// failure partway through can never leave `replacing` missing OR
    /// leave an orphaned scratch file behind.
    private func losslessTrim(source: URL, startSeconds: Double, endSeconds: Double, replacing path: String) async -> Bool {
        let target = URL(fileURLWithPath: path)
        // Only ever swap AAC bytes into an AAC-named file. If the half's own
        // compression failed it is still `<name>.wav` — replacing that with
        // an m4a payload would leave a WAV-named file with AAC inside, which
        // AVAudioFile refuses to open by extension and a later migration
        // would try to "compress" again.
        guard target.pathExtension.lowercased() == "m4a" else { return false }
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough)
        else { return false }
        let scratch = target.deletingLastPathComponent()
            .appendingPathComponent(".lossless-\(UUID().uuidString.prefix(8)).m4a")
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 16_000),
            end: CMTime(seconds: endSeconds, preferredTimescale: 16_000))
        do {
            try await export.export(to: scratch, as: .m4a)
        } catch {
            AppLog.warn("repo", "lossless trim export failed, keeping decode+recompress result: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: scratch)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: scratch)
            return true
        } catch {
            AppLog.warn("repo", "lossless trim produced but couldn't swap in: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: scratch)
            return false
        }
    }

    /// A short (20ms) linear ramp toward silence at one end of `samples`.
    /// Any join or cut point in raw PCM — merge()'s concatenation seam,
    /// split()'s cut — hands the AAC encoder audio that starts or ends at
    /// full, mid-utterance amplitude instead of easing up from/down to
    /// silence like a real recording's natural start/end does. Confirmed by
    /// direct sample analysis of a real split: the encoded boundary frame
    /// carries a dense burst of erratic sample-to-sample jumps in its first
    /// ~10ms — audible as a "robotic"/clicking artifact — that the
    /// recording's own true start, encoded through the exact same pipeline,
    /// does not have. Fading the raw samples before they ever reach the
    /// encoder removes the hard discontinuity the artifact comes from.
    private func fadeEdge(_ samples: ArraySlice<Float>, fadingIn: Bool) -> [Float] {
        var out = Array(samples)
        let n = out.count
        guard n > 0 else { return out }
        for i in 0..<n {
            let t = Float(i) / Float(n)
            out[i] *= fadingIn ? t : (1 - t)
        }
        return out
    }

    /// Frame count for `fadeEdge`'s 20ms ramp, clamped so it never exceeds
    /// the shortest side of a boundary sitting inside a very short recording.
    private func fadeFrameCount(_ sideLengths: Int...) -> Int {
        min(sideLengths.min() ?? 0, Int(0.02 * AudioDecoder.sampleRate))
    }

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
        // A just-stopped recording is saved and mergeable before its
        // background echo-cancel rebuild / AAC compression finishes — wait
        // either source out so this doesn't read a file mid rebuild/delete.
        await postProcessTracker.waitUntilIdle(a.id)
        await postProcessTracker.waitUntilIdle(b.id)
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
        // Fade across the join (see fadeEdge's doc comment) — a then b
        // meet at full amplitude on both sides otherwise.
        let mainFade = fadeFrameCount(sa.count, sb.count)
        try writeWav([
            sa[..<(sa.count - mainFade)],
            fadeEdge(sa[(sa.count - mainFade)...], fadingIn: false)[...],
            fadeEdge(sb[..<mainFade], fadingIn: true)[...],
            sb[mainFade...],
        ], to: url, format: fmt)

        // Carry the meeting machinery. If BOTH sources have split tracks,
        // the merged recording is itself a full meeting: concatenate the
        // mic and sys tracks (padded/truncated to each half's mix length so
        // the shared timeline stays sample-exact) — a re-run then keeps ME
        // ground truth AND lets global diarization unify a colleague who
        // appears in both halves into one speaker.
        for kind in AudioCompressor.sidecarKinds {
            // AudioCompressor may have already transcoded either source's
            // sidecar to .m4a — check that before the pre-migration .wav.
            guard let ua = AudioCompressor.sidecarURL(for: URL(fileURLWithPath: a.audioPath), kind: kind),
                  let ub = AudioCompressor.sidecarURL(for: URL(fileURLWithPath: b.audioPath), kind: kind)
            else { continue }
            do {
                let ta = aligned(try await decoder.decodeAll(file: ua), to: sa.count)
                let tb = aligned(try await decoder.decodeAll(file: ub), to: sb.count)
                let trackFade = fadeFrameCount(ta.count, tb.count)
                try writeWav([
                    ta[..<(ta.count - trackFade)],
                    fadeEdge(ta[(ta.count - trackFade)...], fadingIn: false)[...],
                    fadeEdge(tb[..<trackFade], fadingIn: true)[...],
                    tb[trackFade...],
                ], to: url.deletingPathExtension().appendingPathExtension("\(kind).wav"), format: fmt)
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
        if let d = try? Data(contentsOf: sidecarPath(a.audioPath, "me.json")),
           let iv = try? JSONDecoder().decode([[Double]].self, from: d) {
            meAll += iv.filter { $0.count == 2 }
        }
        if let d = try? Data(contentsOf: sidecarPath(b.audioPath, "me.json")),
           let iv = try? JSONDecoder().decode([[Double]].self, from: d) {
            meAll += iv.filter { $0.count == 2 }.map { [$0[0] + offsetSeconds, $0[1] + offsetSeconds] }
        }
        if !meAll.isEmpty, let data = try? JSONEncoder().encode(meAll) {
            try? data.write(to: sidecarPath(url.path, "me.json"))
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

    /// Split one recording into two NEW recordings at `atSeconds` (measured
    /// from the start of the audio). The inverse of `merge()`, and the same
    /// contract: the source recording is left completely untouched — callers
    /// that want it gone (the normal "cut this in two" flow) call
    /// `delete(_:)` themselves once the two halves look right.
    enum SplitError: LocalizedError {
        case pointOutsideRecording
        var errorDescription: String? {
            "Split point must be inside the recording, away from either end."
        }
    }

    @MainActor
    func split(_ recording: Recording, atSeconds: Double) async throws -> (first: Recording, second: Recording) {
        // Same race merge() guards against: a just-stopped recording is
        // saved and splittable before its background echo-cancel rebuild /
        // AAC compression finishes.
        await postProcessTracker.waitUntilIdle(recording.id)
        // Snapshotted before the (multi-second) work below so a live
        // transcription job racing this call — clearSegments/appendSegments
        // on the SAME recording, from a Cancel that flipped the UI's
        // "isRunning" gate off while the job itself kept streaming — gets
        // caught instead of silently splitting a half-overwritten transcript.
        let sourceSegmentCount = recording.segments.count
        let decoder = AudioDecoder()
        let samples = try await decoder.decodeAll(file: URL(fileURLWithPath: recording.audioPath))
        let totalSeconds = Double(samples.count) / AudioDecoder.sampleRate
        // Keep both halves non-trivial — also rules out a point outside the
        // recording entirely.
        let minHalfSeconds = 0.25
        guard atSeconds >= minHalfSeconds, atSeconds <= totalSeconds - minHalfSeconds else {
            throw SplitError.pointOutsideRecording
        }
        let cutSample = min(samples.count, Int(atSeconds * AudioDecoder.sampleRate))
        let cutSeconds = Double(cutSample) / AudioDecoder.sampleRate

        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: AudioDecoder.sampleRate,
                                      channels: 1, interleaved: false) else {
            throw NSError(domain: "Split", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Audio format setup failed."])
        }
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriberr/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let urlA = dir.appendingPathComponent("split_\(stamp)_a_\(UUID().uuidString.prefix(8)).wav")
        let urlB = dir.appendingPathComponent("split_\(stamp)_b_\(UUID().uuidString.prefix(8)).wav")
        // Fade across the cut (see fadeEdge's doc comment) — otherwise both
        // halves meet the cut at whatever amplitude the source happened to
        // be at, not silence.
        let mainFade = fadeFrameCount(cutSample, samples.count - cutSample)
        try writeWav([
            samples[..<(cutSample - mainFade)],
            fadeEdge(samples[(cutSample - mainFade)..<cutSample], fadingIn: false)[...],
        ], to: urlA, format: fmt)
        try writeWav([
            fadeEdge(samples[cutSample..<(cutSample + mainFade)], fadingIn: true)[...],
            samples[(cutSample + mainFade)...],
        ], to: urlB, format: fmt)

        // mic/sys sidecars and me.json, written BEFORE either Recording row
        // exists — same reasoning as merge(): a DB row must never point at
        // not-yet-finished on-disk state. The two sidecar kinds are fully
        // independent files, so decode them concurrently (same shape as the
        // AAC-compress step further down).
        let sourceAudioPath = recording.audioPath
        let sidecarSamples: [String: [Float]] = await withTaskGroup(of: (String, [Float]?).self) { group in
            for kind in AudioCompressor.sidecarKinds {
                group.addTask {
                    guard let sidecar = AudioCompressor.sidecarURL(
                        for: URL(fileURLWithPath: sourceAudioPath), kind: kind) else { return (kind, nil) }
                    return (kind, try? await decoder.decodeAll(file: sidecar))
                }
            }
            var out: [String: [Float]] = [:]
            for await (kind, decoded) in group {
                if let decoded { out[kind] = decoded }
            }
            return out
        }
        for kind in AudioCompressor.sidecarKinds {
            guard let raw = sidecarSamples[kind] else { continue }
            let full = aligned(raw, to: samples.count)
            do {
                let trackFade = fadeFrameCount(cutSample, full.count - cutSample)
                try writeWav([
                    full[..<(cutSample - trackFade)],
                    fadeEdge(full[(cutSample - trackFade)..<cutSample], fadingIn: false)[...],
                ], to: urlA.deletingPathExtension().appendingPathExtension("\(kind).wav"), format: fmt)
                try writeWav([
                    fadeEdge(full[cutSample..<(cutSample + trackFade)], fadingIn: true)[...],
                    full[(cutSample + trackFade)...],
                ], to: urlB.deletingPathExtension().appendingPathExtension("\(kind).wav"), format: fmt)
            } catch {
                // A bad sidecar must not fail the whole split — the mix is
                // the recording; tracks are an optimization.
                AppLog.warn("repo", "skipping \(kind) tracks in split: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: urlA.deletingPathExtension().appendingPathExtension("\(kind).wav"))
                try? FileManager.default.removeItem(at: urlB.deletingPathExtension().appendingPathExtension("\(kind).wav"))
            }
        }

        // ME-timeline: partition at the cut, clipping any interval that
        // straddles it. Unlike a transcript segment, this is acoustic data
        // with no text to lose — an exact clip is lossless.
        if let d = try? Data(contentsOf: sidecarPath(recording.audioPath, "me.json")),
           let iv = try? JSONDecoder().decode([[Double]].self, from: d) {
            var meA: [[Double]] = []
            var meB: [[Double]] = []
            for pair in iv where pair.count == 2 {
                let (s, e) = (pair[0], pair[1])
                if e <= cutSeconds {
                    meA.append([s, e])
                } else if s >= cutSeconds {
                    meB.append([s - cutSeconds, e - cutSeconds])
                } else {
                    meA.append([s, cutSeconds])
                    meB.append([0, e - cutSeconds])
                }
            }
            if !meA.isEmpty, let data = try? JSONEncoder().encode(meA) {
                try? data.write(to: sidecarPath(urlA.path, "me.json"))
            }
            if !meB.isEmpty, let data = try? JSONEncoder().encode(meB) {
                try? data.write(to: sidecarPath(urlB.path, "me.json"))
            }
        }

        // Two independent recordings from here on — give "(2)" a later
        // createdAtMillis than "(1)" so the library list (sorted newest
        // first) shows them in their natural order, not clock-jitter order.
        let stampNow = Int64(Date().timeIntervalSince1970 * 1000)
        let first = Recording(
            title: "\(recording.title) (1)", audioPath: urlA.path,
            createdAtMillis: stampNow + 1, durationSeconds: cutSeconds,
            sourceLanguage: recording.sourceLanguage,
            transcribedWithBackend: recording.transcribedWithBackend,
            transcribedWithModel: recording.transcribedWithModel,
            translateToEnglish: recording.translateToEnglish)
        let second = Recording(
            title: "\(recording.title) (2)", audioPath: urlB.path,
            createdAtMillis: stampNow, durationSeconds: totalSeconds - cutSeconds,
            sourceLanguage: recording.sourceLanguage,
            transcribedWithBackend: recording.transcribedWithBackend,
            transcribedWithModel: recording.transcribedWithModel,
            translateToEnglish: recording.translateToEnglish)
        for half in [first, second] {
            // Stay where the source lives, and keep its tags/run settings —
            // both halves are still the same underlying material.
            half.folder = recording.folder
            half.tags = recording.tags
            half.runBackend = recording.runBackend
            half.runLanguages = recording.runLanguages
            half.runDiarize = recording.runDiarize
            half.runHybridDiarize = recording.runHybridDiarize
            half.runExpectedSpeakers = recording.runExpectedSpeakers
            half.runSpeakersExact = recording.runSpeakersExact
        }

        // Nothing past this point has any user-visible history yet — on any
        // failure, discard both freshly-created recordings rather than
        // strand them half-finished in the library.
        await postProcessTracker.markBusy(first.id)
        await postProcessTracker.markBusy(second.id)
        do {
            try save(first)
            try save(second)

            // Reclaim disk space now that every WAV involved is fully
            // written AND both recordings are safely persisted. A failure
            // here must never cost the recording — AudioCompressor already
            // deleted the pre-compression WAV on success, so swallow (not
            // propagate), same as merge().
            async let ca = AudioCompressor.compressRecordingFiles(mainURL: urlA, includeSidecars: true)
            async let cb = AudioCompressor.compressRecordingFiles(mainURL: urlB, includeSidecars: true)
            let (finalA, finalB) = await (ca, cb)
            if finalA != urlA { try? updateAudioPath(finalA, for: first) }
            if finalB != urlB { try? updateAudioPath(finalB, for: second) }

            guard recording.segments.count == sourceSegmentCount else {
                throw NSError(domain: "Split", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "The recording changed while splitting (a transcription may still be running) — try again."
                ])
            }
            // Segments: whichever half contains an utterance's MIDPOINT gets
            // it whole (text can't be sliced). No speaker remap needed,
            // unlike merge — both halves share the source's own speaker keys.
            var segsA: [Segment] = []
            var segsB: [Segment] = []
            for seg in recording.segments.sorted(by: { $0.startSeconds < $1.startSeconds }) {
                let mid = (seg.startSeconds + seg.endSeconds) / 2
                if mid < cutSeconds {
                    segsA.append(Segment(startSeconds: seg.startSeconds,
                                         endSeconds: min(seg.endSeconds, cutSeconds),
                                         text: seg.text, language: seg.language,
                                         speaker: seg.speaker, speakerName: seg.speakerName))
                } else {
                    segsB.append(Segment(startSeconds: max(0, seg.startSeconds - cutSeconds),
                                         endSeconds: max(0, seg.endSeconds - cutSeconds),
                                         text: seg.text, language: seg.language,
                                         speaker: seg.speaker, speakerName: seg.speakerName))
                }
            }
            // Scoped to each half's OWN speakers, not the source's full map:
            // a name only still applies if that speaker key means the same
            // person, which a re-transcribed half — a DIFFERENT, truncated
            // audio range whose diarization can assign keys differently —
            // can no longer guarantee.
            func nameMap(for segs: [Segment]) -> [String: String] {
                var map: [String: String] = [:]
                for seg in segs {
                    if let k = seg.speaker, let n = seg.speakerName, map[k] == nil { map[k] = n }
                }
                return map
            }
            if let data = try? JSONEncoder().encode(nameMap(for: segsA)) {
                first.speakerNamesJSON = String(decoding: data, as: UTF8.self)
            }
            if let data = try? JSONEncoder().encode(nameMap(for: segsB)) {
                second.speakerNamesJSON = String(decoding: data, as: UTF8.self)
            }
            if !segsA.isEmpty { try appendSegments(segsA, to: first) }
            if !segsB.isEmpty { try appendSegments(segsB, to: second) }
            // appendSegments deliberately skips this (see its own doc
            // comment) on the assumption a later transcription run's
            // snapshotVersion will capture it — but these two recordings
            // may never get one, especially once the source is deleted.
            BackupService.backupRecording(first)
            BackupService.backupRecording(second)

            // Best-effort quality upgrade, main audio only: when the SOURCE
            // was itself already compressed, everything above just paid a
            // SECOND lossy AAC pass on top of the source's own first one —
            // measured on a real recording at ~6% RMS distortion against the
            // source (a single pass alone measures under 1%), audible as
            // "robotic"/clicking artifacts right where they'd be most
            // noticeable, since both halves start or end at whatever
            // amplitude the source happened to be at, never silence.
            // losslessTrim sidesteps re-encoding entirely via a bitstream
            // trim of the ORIGINAL file — confirmed lossless (0% distortion)
            // in the same test. Runs after everything else so a failure
            // here (source still a .wav, or export unavailable) can't cost
            // anything already committed — first/second already have a
            // fully valid, correct (just potentially lossier) audio file
            // either way.
            if URL(fileURLWithPath: recording.audioPath).pathExtension.lowercased() == "m4a" {
                async let upgradedA = losslessTrim(
                    source: URL(fileURLWithPath: recording.audioPath),
                    startSeconds: 0, endSeconds: cutSeconds, replacing: first.audioPath)
                async let upgradedB = losslessTrim(
                    source: URL(fileURLWithPath: recording.audioPath),
                    startSeconds: cutSeconds, endSeconds: totalSeconds, replacing: second.audioPath)
                let (didA, didB) = await (upgradedA, upgradedB)
                if didA || didB {
                    AppLog.info("repo", "split: lossless trim upgraded main audio (first=\(didA), second=\(didB))")
                }
            }

            AppLog.info("repo", "split '\(recording.title)' at \(cutSeconds)s → "
                + "\(first.title) (\(segsA.count) segs) + \(second.title) (\(segsB.count) segs)")
        } catch {
            await postProcessTracker.markIdle(first.id)
            await postProcessTracker.markIdle(second.id)
            try? delete(first)
            try? delete(second)
            for url in [urlA, urlB] {
                for ext in ["wav", "m4a", "mic.wav", "mic.m4a", "sys.wav", "sys.m4a", "me.json"] {
                    try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension(ext))
                }
            }
            throw error
        }
        await postProcessTracker.markIdle(first.id)
        await postProcessTracker.markIdle(second.id)
        return (first, second)
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
