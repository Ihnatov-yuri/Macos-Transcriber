import Foundation
import AVFoundation
import Accelerate

/// Mirror of Android's `audio/AudioDecoder.kt`.
///
/// Decodes any AVAsset-readable file (WAV / MP3 / M4A / AAC / FLAC / OGG-via-AVF)
/// to 16 kHz mono Float32 PCM, scans for VAD silences, snaps chunk boundaries
/// to the nearest silence within ±2 s.
struct AudioDecoder: Sendable {
    static let sampleRate: Double = 16_000
    static let chunkSeconds: Double = 28
    static let overlapSeconds: Double = 1
    static let alignFlexSeconds: Double = 2.0
    static let silenceMinSeconds: Double = 0.25
    static let silenceRMS: Float = 0.005

    struct Silence: Sendable, Equatable {
        let startSeconds: Double
        let endSeconds: Double
    }

    struct Chunk: Sendable {
        let samples: [Float]
        let startSeconds: Double
        let endSeconds: Double
    }

    init() {}

    // MARK: - Full-file decode (single shot)

    /// Read the entire file into a 16 kHz mono Float32 buffer.
    /// Streams via `AVAssetReader` with an `AVAudioConverter` so the entire
    /// raw float buffer never has to live in memory before resampling.
    func decodeAll(file: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw DecoderError.noAudioTrack
        }

        let outSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outSettings)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else {
                throw DecoderError.readerStartFailed(reader.error?.localizedDescription ?? "unknown")
            }

            var floats: [Float] = []
            floats.reserveCapacity(Int(Self.sampleRate * 60))

            while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var data = Data(count: length)
                data.withUnsafeMutableBytes { ptr in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
                }
                data.withUnsafeBytes { raw in
                    let buf = raw.bindMemory(to: Float.self)
                    floats.append(contentsOf: buf)
                }
                CMSampleBufferInvalidate(sample)
            }

            if reader.status == .failed {
                throw DecoderError.readerFailed(reader.error?.localizedDescription ?? "unknown")
            }
            return floats
        } catch {
            // AVAssetReader refuses some containers/codecs (notably Opus from
            // Teams/Discord, and our own freshly-written WAVs). AVAudioFile +
            // AVAudioConverter reads the format-registry set instead — a much
            // wider net — and resamples to 16 kHz mono itself.
            AppLog.warn("decoder", "AVAssetReader failed (\(error.localizedDescription)) — AVAudioFile fallback")
            return try Self.decodeViaAudioFile(file)
        }
    }

    /// Format-registry decode path: opens with AVAudioFile (handles Opus, m4a,
    /// caf, aiff, our WAVs…) and converts to 16 kHz mono Float32.
    static func decodeViaAudioFile(_ file: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: file)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: f.processingFormat, to: target) else {
            throw DecoderError.readerFailed("AVAudioConverter setup failed")
        }
        let inCap: AVAudioFrameCount = 1 << 16
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: inCap) else {
            throw DecoderError.readerFailed("input buffer alloc failed")
        }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(f.length) * Self.sampleRate / f.processingFormat.sampleRate) + 1024)
        var reachedEOF = false
        while !reachedEOF {
            let outCap = AVAudioFrameCount(Double(inCap) * Self.sampleRate / f.processingFormat.sampleRate) + 512
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { break }
            var convErr: NSError?
            let status = converter.convert(to: outBuf, error: &convErr) { _, inStatus in
                do {
                    try f.read(into: inBuf)
                    if inBuf.frameLength == 0 { reachedEOF = true; inStatus.pointee = .endOfStream; return nil }
                    inStatus.pointee = .haveData
                    return inBuf
                } catch { reachedEOF = true; inStatus.pointee = .endOfStream; return nil }
            }
            if status == .error { throw DecoderError.readerFailed(convErr?.localizedDescription ?? "convert failed") }
            if let p = outBuf.floatChannelData?[0], outBuf.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream { break }
        }
        AppLog.info("decoder", "AVAudioFile fallback decoded \(out.count) samples from \(file.lastPathComponent)")
        return out
    }

    // MARK: - Silence scan + chunking

    /// Energy-VAD silence scan. Returns regions where RMS ≤ `silenceRMS` for
    /// at least `silenceMinSeconds`. Uses 25 ms windows with 10 ms hop.
    func scanSilences(samples: [Float]) -> [Silence] {
        let sr = Int(Self.sampleRate)
        let win = sr / 40           // 25 ms
        let hop = sr / 100          // 10 ms
        guard samples.count >= win else { return [] }

        var rmsTrack: [Float] = []
        rmsTrack.reserveCapacity(samples.count / hop)
        var i = 0
        while i + win <= samples.count {
            var rms: Float = 0
            samples.withUnsafeBufferPointer { ptr in
                vDSP_rmsqv(ptr.baseAddress!.advanced(by: i), 1, &rms, vDSP_Length(win))
            }
            rmsTrack.append(rms)
            i += hop
        }

        var silences: [Silence] = []
        let minHops = Int(Self.silenceMinSeconds * Double(sr) / Double(hop))
        var runStart: Int? = nil
        for (idx, val) in rmsTrack.enumerated() {
            if val <= Self.silenceRMS {
                if runStart == nil { runStart = idx }
            } else if let start = runStart {
                if idx - start >= minHops {
                    silences.append(Silence(
                        startSeconds: Double(start * hop) / Self.sampleRate,
                        endSeconds: Double(idx * hop) / Self.sampleRate
                    ))
                }
                runStart = nil
            }
        }
        if let start = runStart, rmsTrack.count - start >= minHops {
            silences.append(Silence(
                startSeconds: Double(start * hop) / Self.sampleRate,
                endSeconds: Double(rmsTrack.count * hop) / Self.sampleRate
            ))
        }
        return silences
    }

    /// Snap nominal `chunkSeconds` boundaries to the midpoint of the nearest
    /// silence within ±`alignFlexSeconds`. Falls back to a fixed-time cut
    /// when no qualifying silence is in range.
    func computeCutPoints(silences: [Silence], durationSeconds: Double) -> [Double] {
        var cuts: [Double] = []
        var t = Self.chunkSeconds
        while t < durationSeconds {
            let nearest = silences.min { a, b in
                abs((a.startSeconds + a.endSeconds) / 2 - t) <
                abs((b.startSeconds + b.endSeconds) / 2 - t)
            }
            if let s = nearest,
               abs((s.startSeconds + s.endSeconds) / 2 - t) <= Self.alignFlexSeconds
            {
                cuts.append((s.startSeconds + s.endSeconds) / 2)
            } else {
                cuts.append(t)
            }
            t += Self.chunkSeconds
        }
        return cuts
    }

    /// Slice a pre-decoded float buffer into overlapping chunks at cut points.
    /// Includes `overlapSeconds` of recap at the start of every chunk after
    /// the first, so the model can re-anchor.
    func slice(samples: [Float], cuts: [Double]) -> [Chunk] {
        let sr = Self.sampleRate
        let durationSeconds = Double(samples.count) / sr

        var boundaries: [Double] = [0]
        boundaries.append(contentsOf: cuts)
        boundaries.append(durationSeconds)

        var out: [Chunk] = []
        out.reserveCapacity(boundaries.count - 1)
        for i in 0 ..< (boundaries.count - 1) {
            let rawStart = boundaries[i]
            let end = boundaries[i + 1]
            let start = i == 0 ? rawStart : max(0, rawStart - Self.overlapSeconds)
            let s = Int(start * sr)
            let e = min(samples.count, Int(end * sr))
            guard e > s else { continue }
            out.append(Chunk(
                samples: Array(samples[s ..< e]),
                startSeconds: start,
                endSeconds: end
            ))
        }
        return out
    }

    // MARK: - Convenience

    func decodeAndChunk(file: URL) async throws -> (samples: [Float], chunks: [Chunk], duration: Double) {
        var pcm = try await decodeAll(file: file)
        // Optional Apple-DSP noise suppression for imported files.
        // (Live-recorded WAVs were already cleaned at capture time.)
        if RecorderSettings.shared.preprocessImports {
            AppLog.info("decoder", "applying offline noise suppression to \(file.lastPathComponent) (\(pcm.count) samples)")
            pcm = NoiseSuppressor.process(samples: pcm, sampleRate: Self.sampleRate)
        }
        let duration = Double(pcm.count) / Self.sampleRate
        let silences = scanSilences(samples: pcm)
        let cuts = computeCutPoints(silences: silences, durationSeconds: duration)
        let chunks = slice(samples: pcm, cuts: cuts)
        return (pcm, chunks, duration)
    }

    enum DecoderError: LocalizedError {
        case noAudioTrack
        case readerStartFailed(String)
        case readerFailed(String)
        var errorDescription: String? {
            switch self {
            case .noAudioTrack:               return "No audio track found in file."
            case .readerStartFailed(let m):   return "AVAssetReader could not start: \(m)"
            case .readerFailed(let m):        return "AVAssetReader failed: \(m)"
            }
        }
    }
}
