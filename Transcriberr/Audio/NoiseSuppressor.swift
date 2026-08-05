import Foundation
@preconcurrency import AVFoundation

/// Offline noise suppression. Feeds a pre-decoded 16 kHz mono Float32
/// buffer through an `AVAudioEngine` in manual rendering mode with the
/// system's voice-processing unit at the head of the graph. Returns the
/// cleaned-up buffer (same length, same rate).
///
/// Used by `AudioDecoder` when `RecorderSettings.preprocessImports == true`.
enum NoiseSuppressor {
    /// Convenience: take a [Float] at `sourceRate`, return a noise-suppressed
    /// [Float] at the same rate. Returns the original input on failure.
    static func process(samples: [Float], sampleRate: Double) -> [Float] {
        guard !samples.isEmpty else { return samples }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        // 1. Pack input into a single AVAudioPCMBuffer.
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return samples }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        memcpy(inputBuffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)

        // 2. Engine in manual rendering mode. We feed the buffer via a
        //    player node connected to the main mixer, render in 4096-sample
        //    blocks, and collect the output.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)

        // Voice processing on the output side — works in offline render too,
        // applied to whatever signal flows through the chain. We must enable
        // before `enableManualRenderingMode`.
        do {
            try engine.outputNode.setVoiceProcessingEnabled(true)
        } catch {
            AppLog.warn("noisesup", "couldn't enable voice processing: \(error.localizedDescription)")
            return samples
        }

        let blockSize: AVAudioFrameCount = 4096
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: blockSize)
            try engine.start()
        } catch {
            AppLog.warn("noisesup", "engine setup failed: \(error.localizedDescription)")
            return samples
        }

        player.scheduleBuffer(inputBuffer, at: nil, options: [], completionHandler: nil)
        player.play()

        // 3. Render loop.
        guard let outBlock = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize) else {
            engine.stop()
            return samples
        }

        var output: [Float] = []
        output.reserveCapacity(samples.count)
        let totalFrames: AVAudioFramePosition = AVAudioFramePosition(samples.count)

        while engine.manualRenderingSampleTime < totalFrames {
            let remaining = totalFrames - engine.manualRenderingSampleTime
            let request = AVAudioFrameCount(min(Int64(blockSize), remaining))
            do {
                let status = try engine.renderOffline(request, to: outBlock)
                if status != .success { break }
                let count = Int(outBlock.frameLength)
                if count > 0, let ptr = outBlock.floatChannelData?[0] {
                    output.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
                }
                if count == 0 { break }
            } catch {
                AppLog.warn("noisesup", "renderOffline failed: \(error.localizedDescription)")
                break
            }
        }

        player.stop()
        engine.stop()

        // If the engine produced way less (or no) data, fall back to original.
        if output.count < samples.count / 4 {
            AppLog.warn("noisesup", "output too short (\(output.count) / \(samples.count)) — falling back")
            return samples
        }
        return output
    }
}
