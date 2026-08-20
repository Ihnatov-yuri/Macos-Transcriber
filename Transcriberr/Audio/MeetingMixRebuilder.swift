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
enum MeetingMixRebuilder {
    /// No-op (returns `mainURL` unchanged) for anything that isn't a meeting
    /// recording with both raw sidecars still present as WAV — i.e. call
    /// this BEFORE `AudioCompressor` touches the sidecars, not after.
    static func rebuildMix(mainURL: URL) async -> URL {
        let micURL = mainURL.deletingPathExtension().appendingPathExtension("mic.wav")
        let sysURL = mainURL.deletingPathExtension().appendingPathExtension("sys.wav")
        guard FileManager.default.fileExists(atPath: micURL.path),
              FileManager.default.fileExists(atPath: sysURL.path)
        else { return mainURL }

        do {
            let decoder = AudioDecoder()
            let rawMic = try await decoder.decodeAll(file: micURL)
            let sys = try await decoder.decodeAll(file: sysURL)
            let cleanedMic = EchoCanceller.cancel(mic: rawMic, ref: sys)

            let n = min(cleanedMic.count, sys.count)
            guard n > 0 else { return mainURL }
            var mix = [Float](repeating: 0, count: n)
            for i in 0..<n {
                mix[i] = max(-1, min(1, cleanedMic[i] + sys[i]))
            }

            guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: AudioDecoder.sampleRate,
                                          channels: 1, interleaved: false) else { return mainURL }
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

            try FileManager.default.removeItem(at: mainURL)
            try FileManager.default.moveItem(at: tmp, to: mainURL)
            AppLog.info("aec", "rebuilt meeting mix from cancelled mic + sys (\(n) samples)")
            return mainURL
        } catch {
            AppLog.warn("aec", "mix rebuild failed, keeping live-gated mix: \(error.localizedDescription)")
            return mainURL
        }
    }
}
