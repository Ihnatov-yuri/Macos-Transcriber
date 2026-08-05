import Foundation
import AVFoundation
import Accelerate

/// Extracts a bucketed peak amplitude array from an audio file for display
/// in the player bar / detail view scrubber. Mirror of the Android app's
/// 200-bucket waveform extraction.
enum WaveformLoader {
    /// Reads the audio file, downsamples to 16 kHz mono Float32, then groups
    /// samples into `buckets` peak buckets. Returns values in [0, 1].
    static func extractPeaks(from file: URL, buckets: Int = 200) async -> [Float] {
        do {
            return try await runExtract(file: file, buckets: buckets)
        } catch {
            AppLog.warn("waveform", "extract failed for \(file.lastPathComponent): \(error.localizedDescription)")
            return []
        }
    }

    private static func runExtract(file: URL, buckets: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return []
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

        var allSamples: [Float] = []
        allSamples.reserveCapacity(16_000 * 60)
        while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { ptr in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
            }
            data.withUnsafeBytes { raw in
                let buf = raw.bindMemory(to: Float.self)
                allSamples.append(contentsOf: buf)
            }
            CMSampleBufferInvalidate(sample)
        }

        guard !allSamples.isEmpty else { return [] }
        let bucketSize = max(1, allSamples.count / buckets)
        var peaks: [Float] = []
        peaks.reserveCapacity(buckets)

        // Use vDSP for fast per-bucket peak (max(abs)).
        allSamples.withUnsafeBufferPointer { ptr in
            var i = 0
            while i + bucketSize <= allSamples.count, peaks.count < buckets {
                var maxAbs: Float = 0
                vDSP_maxmgv(ptr.baseAddress!.advanced(by: i), 1, &maxAbs, vDSP_Length(bucketSize))
                peaks.append(maxAbs)
                i += bucketSize
            }
        }

        // Normalize to [0, 1] for display.
        let maxPeak = peaks.max() ?? 1
        guard maxPeak > 0 else { return peaks }
        return peaks.map { $0 / maxPeak }
    }
}
