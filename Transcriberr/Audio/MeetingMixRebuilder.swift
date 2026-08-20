import Foundation
import AVFoundation

/// Replaces a meeting recording's live-gated main mix with one built from
/// offline echo cancellation. `MeetingRecorder`'s live mix only *gates* the
/// mic while the far side talks — a cheap, imperfect defense against room
/// echo — because a live CoreAudio IO callback is the wrong place to run an
/// adaptive filter. `EchoCanceller` does the real job, but offline, from the
/// `.mic`/`.sys` sidecars. This stitches the two together after recording
/// stops: cancel, remix, and swap the result in for the file the user
/// actually plays back.
///
/// Sidecars are located via `AudioCompressor.sidecarURL` (checks `.m4a`
/// before falling back to `.wav`) rather than a literal `.wav` path, and the
/// rebuilt mix always lands at `<base>.wav` rather than assuming that's
/// `mainURL` — that makes this equally usable right after a fresh recording
/// stops (`mainURL` IS already the `.wav`, before `AudioCompressor` ever
/// touches it) and as a one-time backfill over ALREADY-compressed older
/// recordings (`mainURL` is a `.m4a`; the stale one gets removed once the
/// rebuilt `.wav` is safely in place — never before).
enum MeetingMixRebuilder {
    /// `nil` for anything that isn't a meeting recording with both
    /// `.mic`/`.sys` sidecars still on disk, or if the rebuild fails for any
    /// reason — callers fall back to `mainURL` unchanged. On success, returns
    /// the rebuilt file's URL, which the caller must use as the recording's
    /// new `audioPath` when it differs from `mainURL` (the migration case).
    static func rebuildMix(mainURL: URL) async -> URL? {
        guard let micURL = AudioCompressor.sidecarURL(for: mainURL, kind: "mic"),
              let sysURL = AudioCompressor.sidecarURL(for: mainURL, kind: "sys")
        else { return nil }
        let outputURL = mainURL.deletingPathExtension().appendingPathExtension("wav")

        do {
            let decoder = AudioDecoder()
            async let rawMicTask = decoder.decodeAll(file: micURL)
            async let sysTask = decoder.decodeAll(file: sysURL)
            let rawMic = try await rawMicTask
            let sys = try await sysTask
            let cleanedMic = EchoCanceller.cancel(mic: rawMic, ref: sys)

            let n = min(cleanedMic.count, sys.count)
            guard n > 0 else { return nil }
            var mix = [Float](repeating: 0, count: n)
            for i in 0..<n {
                mix[i] = max(-1, min(1, cleanedMic[i] + sys[i]))
            }

            guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: AudioDecoder.sampleRate,
                                          channels: 1, interleaved: false) else { return nil }
            let tmp = mainURL.deletingLastPathComponent()
                .appendingPathComponent(".rebuild-\(UUID().uuidString).wav")
            // Written via a nested function (not inline) so the AVAudioFile
            // writer is GUARANTEED closed by definite function-return before
            // the file is moved into place — see RecordingRepository.merge's
            // writeWav for the same empirically-forced pattern (a WAV's
            // header only finalizes when the writer deallocates).
            func write(_ samples: [Float], to url: URL) throws {
                let f = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                        commonFormat: .pcmFormatFloat32, interleaved: false)
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                                 frameCapacity: AVAudioFrameCount(samples.count)) else {
                    throw NSError(domain: "MeetingMixRebuilder", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Buffer allocation failed."])
                }
                buf.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { src in
                    buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
                }
                try f.write(from: buf)
            }
            try write(mix, to: tmp)

            // outputURL == mainURL for a fresh recording (still a .wav,
            // rebuild runs before AudioCompressor) — swap in place. For an
            // already-compressed older recording (mainURL is a .m4a),
            // outputURL is a new sibling .wav; only remove the stale .m4a
            // AFTER the rebuilt file is safely on disk at its own path.
            if outputURL == mainURL {
                try FileManager.default.removeItem(at: mainURL)
            }
            try FileManager.default.moveItem(at: tmp, to: outputURL)
            if outputURL != mainURL {
                try? FileManager.default.removeItem(at: mainURL)
            }
            AppLog.info("aec", "rebuilt meeting mix from cancelled mic + sys (\(n) samples)")
            return outputURL
        } catch {
            AppLog.warn("aec", "mix rebuild failed, keeping live-gated mix: \(error.localizedDescription)")
            return nil
        }
    }
}
