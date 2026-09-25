import Foundation
import AVFoundation
import Accelerate

/// Extracts a bucketed peak amplitude array from an audio file for display
/// in the player bar / detail view scrubber. Mirror of the Android app's
/// 200-bucket waveform extraction.
enum WaveformLoader {
    /// Reads the audio file, downsamples to 16 kHz mono Float32, then groups
    /// samples into `buckets` peak buckets. Returns values in [0, 1]; empty
    /// when the calling task is cancelled (the player loaded another file).
    static func extractPeaks(from file: URL, buckets: Int = 200) async -> [Float] {
        do {
            return try await runExtract(file: file, buckets: buckets)
        } catch is CancellationError {
            return []
        } catch {
            AppLog.warn("waveform", "extract failed for \(file.lastPathComponent): \(error.localizedDescription)")
            return []
        }
    }

    /// Streams the decode instead of holding it: the whole file used to be
    /// collected into one array (plus a Data copy per sample buffer) just to
    /// keep 200 numbers — ~230 MB for an hour-long meeting, per recording
    /// opened. Now each decoded buffer is folded into fine-grained block
    /// peaks as it arrives (block size from the asset's duration, ~16 per
    /// output bucket) and the blocks are bucketed at the end, so memory is
    /// bounded by the bucket count, not the recording length. The duration
    /// only sizes the blocks — the final bucketing uses the real count, so
    /// an estimate that is off never drops or pads audio. (No duration at
    /// all falls back to one-sample blocks: the old memory, still correct.)
    private static func runExtract(file: URL, buckets: Int) async throws -> [Float] {
        guard buckets > 0 else { return [] }
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return []
        }
        var blockSize = 1
        if let d = try? await asset.load(.duration), d.isValid, d.seconds.isFinite, d.seconds > 0 {
            blockSize = max(1, Int(d.seconds * 16_000) / (buckets * 16))
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
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return [] }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var blockPeaks: [Float] = []
        var blockMax: Float = 0
        var inBlock = 0
        var scratch: [Float] = []
        while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
            // A newer load replaced this file — stop decoding it.
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
            scratch.withUnsafeMutableBytes { ptr in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                               destination: ptr.baseAddress!)
            }
            CMSampleBufferInvalidate(sample)
            // Use vDSP for fast per-block peak (max(abs)).
            scratch.withUnsafeBufferPointer { ptr in
                var i = 0
                while i < count {
                    let n = min(blockSize - inBlock, count - i)
                    var maxAbs: Float = 0
                    vDSP_maxmgv(ptr.baseAddress!.advanced(by: i), 1, &maxAbs, vDSP_Length(n))
                    blockMax = max(blockMax, maxAbs)
                    inBlock += n
                    i += n
                    if inBlock == blockSize {
                        blockPeaks.append(blockMax)
                        blockMax = 0
                        inBlock = 0
                    }
                }
            }
        }
        if inBlock > 0 { blockPeaks.append(blockMax) }

        guard !blockPeaks.isEmpty else { return [] }
        // Proportional bucket edges: every block lands in exactly one of
        // min(buckets, blocks) buckets, none dropped at the tail.
        let outCount = min(buckets, blockPeaks.count)
        var peaks = [Float](repeating: 0, count: outCount)
        for (i, v) in blockPeaks.enumerated() {
            let b = i * outCount / blockPeaks.count
            peaks[b] = max(peaks[b], v)
        }

        // Normalize to [0, 1] for display.
        let maxPeak = peaks.max() ?? 1
        guard maxPeak > 0 else { return peaks }
        return peaks.map { $0 / maxPeak }
    }
}
