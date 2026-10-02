import Foundation
import AVFoundation

/// Replaces a meeting recording's live-gated main mix with one built from
/// offline echo cancellation (or, failing that, an offline echo gate). `MeetingRecorder`'s live mix only *gates* the
/// mic while the far side talks — a cheap, imperfect defense against room
/// echo — because a live CoreAudio IO callback is the wrong place to run an
/// adaptive filter. `EchoCanceller` does the real job, but offline, from the
/// `.mic`/`.sys` sidecars. This stitches the two together after recording
/// stops: cancel, remix, and swap the result in for the file the user
/// actually plays back. When the echo path is beyond the canceller,
/// `EchoGate` mutes the mic's echo-only stretches instead.
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
    /// `.mic`/`.sys` sidecars still on disk, or if the rebuild fails —
    /// callers fall back to `mainURL` unchanged. On success, returns
    /// the rebuilt file's URL, which the caller must use as the recording's
    /// new `audioPath` when it differs from `mainURL` (the migration case).
    /// The mix the user plays back: the echo-cancelled (or, when the echo is
    /// beyond the canceller, echo-gated) mic plus the far side.
    static func playbackMix(mic rawMic: [Float], sys: [Float]) -> [Float] {
        let (cleanedMic, outcome, echoDelay) = EchoCanceller.cancelDetailed(mic: rawMic, ref: sys)
        return playbackMix(cleanedMic: cleanedMic, outcome: outcome, echoDelay: echoDelay, sys: sys)
    }

    /// The same from a canceller result already in hand.
    static func playbackMix(cleanedMic: [Float], outcome: EchoCanceller.Outcome,
                            echoDelay: Int, sys: [Float]) -> [Float] {
        var mic = cleanedMic
        // The canceller gave up on an echo it could not remove: a mix of
        // the raw mic and the far side plays every far-side word twice.
        // This used to keep the live-gated mix instead, on the theory that
        // it was the better file. It was not: with a loud speaker the live
        // gate passed the echo in full (see EchoGate). Gate the raw mic
        // offline, where the echo level and delay are known. (The
        // transcript is not affected: it reads the sidecars and removes
        // that echo by timing.)
        if outcome == .echoKept {
            EchoGate.apply(&mic, ref: sys, delay: echoDelay)
            AppLog.info("aec", "echo not cancellable — mix built from the echo-gated mic (delay \(echoDelay) smp)")
        }
        let n = min(mic.count, sys.count)
        var mix = [Float](repeating: 0, count: n)
        for i in 0..<n {
            mix[i] = max(-1, min(1, mic[i] + sys[i]))
        }
        return mix
    }

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
            let mix = playbackMix(mic: rawMic, sys: sys)
            guard !mix.isEmpty else { return nil }

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
            // Clean up the temp on any failure below — it is dot-prefixed,
            // so a leaked one is invisible in Finder and never noticed.
            defer { try? FileManager.default.removeItem(at: tmp) }
            try write(mix, to: tmp)

            // NEVER delete-then-move: the old code removed `mainURL` first,
            // and a failed move then left the recording's row pointing at a
            // file that no longer existed — playback and re-transcription
            // both dead, the audio surviving only in the sidecars. Replace
            // atomically instead, exactly as AudioCompressor's header
            // demands ("never delete then fail").
            //
            // outputURL == mainURL for a fresh recording (still a .wav,
            // rebuild runs before AudioCompressor) — swap in place. For an
            // already-compressed older recording (mainURL is a .m4a),
            // outputURL is a new sibling .wav; only remove the stale .m4a
            // AFTER the rebuilt file is safely on disk at its own path.
            if outputURL == mainURL {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: outputURL)
                try? FileManager.default.removeItem(at: mainURL)
            }
            AppLog.info("aec", "rebuilt meeting mix from mic + sys sidecars (\(mix.count) samples)")
            return outputURL
        } catch {
            AppLog.warn("aec", "mix rebuild failed, keeping live-gated mix: \(error.localizedDescription)")
            return nil
        }
    }
}
