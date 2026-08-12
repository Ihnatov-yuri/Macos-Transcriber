import Foundation

/// Offline cleanup for IMPORTED files (live recordings are cleaned by the
/// voice-processing unit at capture time).
///
/// v1 used an offline AVAudioEngine render with Apple's voice-processing AU
/// — it failed engine.start() on every invocation (40 failures in the field
/// log) and silently returned the input. Replaced with deterministic DSP
/// that cannot fail: a one-pole 80 Hz high-pass (kills rumble/hum the ASR
/// mistakes for speech onset) + peak normalization.
enum NoiseSuppressor {
    static func process(samples: [Float], sampleRate: Double) -> [Float] {
        guard !samples.isEmpty else { return samples }
        // High-pass, fc = 80 Hz.
        let rc = 1.0 / (2.0 * .pi * 80.0)
        let dt = 1.0 / sampleRate
        let a = Float(rc / (rc + dt))
        var out = [Float](repeating: 0, count: samples.count)
        out[0] = samples[0]
        for i in 1..<samples.count {
            out[i] = a * (out[i - 1] + samples[i] - samples[i - 1])
        }
        // Peak normalize to -0.5 dBFS.
        var peak: Float = 0
        for v in out { peak = max(peak, abs(v)) }
        if peak > 0.001 {
            let g = 0.95 / peak
            if g < 4 {   // never boost noise floors by more than 12 dB
                for i in 0..<out.count { out[i] *= g }
            }
        }
        AppLog.info("noisesup", "HPF+normalize applied (peak \(String(format: "%.3f", peak)))")
        return out
    }
}
