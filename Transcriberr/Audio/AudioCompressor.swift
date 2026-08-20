import Foundation
import AVFoundation

/// Transcodes a finished recording from WAV to AAC (.m4a) to reclaim disk
/// space — 16 kHz mono AAC at 48 kbps is roughly a tenth the size of the
/// equivalent Float32 WAV, and every reader in the app (AudioDecoder,
/// WaveformLoader, AVPlayer playback) already accepts any AVFoundation-
/// supported format, so nothing downstream needs to change.
///
/// The live recorders (WavRecorder, MeetingRecorder) and RecordingRepository
/// merge() keep writing WAV exactly as before — real-time encoder work
/// inside a CoreAudio IO callback is not a risk worth taking with live
/// capture, and merge()'s alignment/concatenation math is proven and
/// shouldn't be touched to save disk space. This runs AFTER a WAV is fully
/// written and closed, and after the Recording row referencing it is
/// already saved, as a separate, independently-verified step.
enum AudioCompressor {
    private static let aacBitrate = 48_000
    /// Sidecar kinds MeetingRecorder/merge() ever produce alongside a main
    /// mix — the single source of truth other code should read from
    /// instead of repeating the literal list.
    static let sidecarKinds = ["mic", "sys"]

    enum CompressError: LocalizedError {
        case durationMismatch(original: Double, transcoded: Double)
        case invalidDuration
        case noAudioTrack

        var errorDescription: String? {
            switch self {
            case .durationMismatch(let o, let t):
                return "Transcoded duration (\(t)s) doesn't match original (\(o)s)."
            case .invalidDuration:
                return "Could not determine a valid duration — refusing to verify a transcode blind."
            case .noAudioTrack:
                return "No audio track to transcode."
            }
        }
    }

    /// Compresses a recording's main file and, when requested, its known
    /// sidecar kinds — concurrently (independent files, no reason to
    /// serialize) and logged on failure. Never throws: a compression
    /// failure must never cost the recording itself, so every file falls
    /// back to its original WAV URL on error. Returns the main file's
    /// final URL.
    static func compressRecordingFiles(mainURL: URL, includeSidecars: Bool) async -> URL {
        async let main = compressOrLog(mainURL, label: "main file")
        if includeSidecars {
            await withTaskGroup(of: Void.self) { group in
                for kind in sidecarKinds {
                    let sidecar = mainURL.deletingPathExtension().appendingPathExtension("\(kind).wav")
                    guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
                    group.addTask { _ = await compressOrLog(sidecar, label: "\(kind) sidecar") }
                }
            }
        }
        return await main
    }

    private static func compressOrLog(_ wav: URL, label: String) async -> URL {
        do {
            return try await compressAndReplace(wav)
        } catch {
            AppLog.warn("compressor", "\(label) compression failed for \(wav.lastPathComponent): \(error.localizedDescription)")
            return wav
        }
    }

    /// Transcodes `wav` to a sibling `.m4a`, verifies the decoded duration
    /// matches within tolerance, deletes `wav` ONLY on success, and returns
    /// the new URL. On any failure the original file is left untouched and
    /// no partial `.m4a` survives — never delete-then-fail, never leave an
    /// orphan behind either.
    static func compressAndReplace(_ wav: URL) async throws -> URL {
        let m4a = wav.deletingPathExtension().appendingPathExtension("m4a")
        let originalDuration = try await duration(of: wav)
        do {
            try await transcode(from: wav, to: m4a)
        } catch {
            try? FileManager.default.removeItem(at: m4a)
            throw error
        }
        let newDuration = try await duration(of: m4a)
        // Relative tolerance, not a flat absolute one: a fixed 0.5s window
        // gives essentially no protection on a short clip (a 0.3s clip
        // collapsing to 0.1s passes a flat 0.5s check) while being tighter
        // than necessary on a long one. The 0.15s floor covers normal
        // encoder frame-alignment jitter (AAC's 1024-sample frame size is
        // ~64ms at 16kHz) on very short clips.
        let tolerance = max(0.15, originalDuration * 0.02)
        guard abs(newDuration - originalDuration) < tolerance else {
            try? FileManager.default.removeItem(at: m4a)
            throw CompressError.durationMismatch(original: originalDuration, transcoded: newDuration)
        }
        do {
            try FileManager.default.removeItem(at: wav)
        } catch {
            // Couldn't remove the original — don't strand a duplicate on
            // disk (defeats the whole point); revert cleanly to
            // original-only rather than leaving both files around.
            try? FileManager.default.removeItem(at: m4a)
            throw error
        }
        return m4a
    }

    /// Locates a recording's `<base>.<kind>.{m4a,wav}` sidecar — checks the
    /// compressed extension first, falls back to the pre-migration WAV so
    /// recordings made before this shipped keep working unchanged.
    static func sidecarURL(for mainURL: URL, kind: String) -> URL? {
        let base = mainURL.deletingPathExtension()
        for ext in ["\(kind).m4a", "\(kind).wav"] {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func duration(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let d = try await asset.load(.duration)
        // A failed/invalid duration read must not be treated as "0 seconds
        // matches 0 seconds" by the caller's mismatch check — that would
        // let a completely unverified transcode through as if it passed.
        guard d.isValid, d.seconds.isFinite else { throw CompressError.invalidDuration }
        return d.seconds
    }

    private static func transcode(from src: URL, to dst: URL) async throws {
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        let inFile = try AVAudioFile(forReading: src)
        guard inFile.length > 0 else { throw CompressError.noAudioTrack }
        let inFormat = inFile.processingFormat
        let outSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inFormat.sampleRate,
            AVNumberOfChannelsKey: inFormat.channelCount,
            AVEncoderBitRateKey: aacBitrate,
        ]
        let outFile = try AVAudioFile(forWriting: dst, settings: outSettings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 32_768) else {
            throw NSError(domain: "AudioCompressor", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Buffer allocation failed."])
        }
        // AVAudioFile.read(into:) does NOT signal EOF by returning a
        // zero-length buffer — calling it again once framePosition has
        // already reached length THROWS ("nilError", empirically
        // reproduced) instead. Must check remaining frames before every
        // read, never rely on the read call itself to report EOF.
        while inFile.framePosition < inFile.length {
            try inFile.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try outFile.write(from: buffer)
        }
    }
}
