import Accelerate
import Foundation

/// 80 Kaldi filterbank features, as WeSpeaker's models are trained on:
/// `torchaudio.compliance.kaldi.fbank` with 25 ms frames every 10 ms, no
/// dither, a Hamming window and energy_floor 0, on samples scaled to 16-bit
/// range, then the mean of each band over the window subtracted (CMN).
///
/// Kaldi's defaults apply where WeSpeaker leaves them: frames cut inside the
/// signal (snip_edges), DC removed per frame, pre-emphasis 0.97, a 512-point
/// power spectrum, mel bands from 20 Hz to Nyquist on 1127·ln(1 + f/700),
/// and the log floored at Float.ulpOfOne. Checked against the reference
/// written by scripts/voice-model/convert_simam.py (KaldiFbankTests).
struct KaldiFbank: Sendable {
    static let sampleRate = 16_000.0
    static let frameLength = 400
    static let frameShift = 160
    static let fftSize = 512
    static let bins = fftSize / 2 + 1
    static let melBins = 80
    static let preemphasis: Float = 0.97

    static let shared = KaldiFbank()

    /// Hamming, symmetric: 0.54 - 0.46·cos(2πn / (N - 1)).
    private let window: [Float]
    /// The real DFT of a 400-sample frame zero-padded to 512, as two
    /// matrices (frameLength × bins): the padding adds nothing.
    private let cosines: [Float]
    private let sines: [Float]
    /// bins × melBins, Kaldi's triangles; the Nyquist bin has no weight.
    private let mel: [Float]

    init() {
        let n = Self.frameLength, b = Self.bins
        window = (0..<n).map { Float(0.54 - 0.46 * cos(2 * Double.pi * Double($0) / Double(n - 1))) }
        var c = [Float](repeating: 0, count: n * b), s = c
        for t in 0..<n {
            for k in 0..<b {
                let angle = 2 * Double.pi * Double(t * k % Self.fftSize) / Double(Self.fftSize)
                c[t * b + k] = Float(cos(angle))
                s[t * b + k] = Float(sin(angle))
            }
        }
        cosines = c
        sines = s
        mel = Self.melBanks()
    }

    static func melScale(_ hz: Double) -> Double { 1127 * log(1 + hz / 700) }

    /// Kaldi's mel triangles over the first fftSize/2 bins.
    static func melBanks() -> [Float] {
        let lowMel = melScale(20), highMel = melScale(sampleRate / 2)
        let delta = (highMel - lowMel) / Double(melBins + 1)
        let binWidth = sampleRate / Double(fftSize)
        var out = [Float](repeating: 0, count: bins * melBins)
        for m in 0..<melBins {
            let left = lowMel + Double(m) * delta, center = left + delta, right = center + delta
            for k in 0..<(fftSize / 2) {
                let f = melScale(binWidth * Double(k))
                let up = (f - left) / (center - left), down = (right - f) / (right - center)
                out[k * melBins + m] = Float(max(0, min(up, down)))
            }
        }
        return out
    }

    static func frameCount(_ samples: Int) -> Int {
        samples < frameLength ? 0 : 1 + (samples - frameLength) / frameShift
    }

    /// frames × 80, row-major, CMN applied. `samples` are 16 kHz in -1…1.
    func features(_ samples: ArraySlice<Float>) -> [Float] {
        let frames = Self.frameCount(samples.count)
        guard frames > 0 else { return [] }
        let n = Self.frameLength, b = Self.bins, m = Self.melBins
        let base = samples.startIndex
        var framed = [Float](repeating: 0, count: frames * n)
        for f in 0..<frames {
            let start = base + f * Self.frameShift
            var frame = (0..<n).map { samples[start + $0] * 32768 }
            let mean = frame.reduce(0, +) / Float(n)
            for i in 0..<n { frame[i] -= mean }
            // Pre-emphasis; the first sample is set against itself.
            for i in stride(from: n - 1, to: 0, by: -1) { frame[i] -= Self.preemphasis * frame[i - 1] }
            frame[0] -= Self.preemphasis * frame[0]
            for i in 0..<n { framed[f * n + i] = frame[i] * window[i] }
        }
        var re = [Float](repeating: 0, count: frames * b), im = re
        vDSP_mmul(framed, 1, cosines, 1, &re, 1, vDSP_Length(frames), vDSP_Length(b), vDSP_Length(n))
        vDSP_mmul(framed, 1, sines, 1, &im, 1, vDSP_Length(frames), vDSP_Length(b), vDSP_Length(n))
        var power = [Float](repeating: 0, count: frames * b)
        vDSP_vmma(re, 1, re, 1, im, 1, im, 1, &power, 1, vDSP_Length(frames * b))
        var out = [Float](repeating: 0, count: frames * m)
        vDSP_mmul(power, 1, mel, 1, &out, 1, vDSP_Length(frames), vDSP_Length(m), vDSP_Length(b))
        for i in out.indices { out[i] = log(max(out[i], Float.ulpOfOne)) }
        // CMN: each band's mean over the window.
        for j in 0..<m {
            var sum: Float = 0
            for f in 0..<frames { sum += out[f * m + j] }
            let mean = sum / Float(frames)
            for f in 0..<frames { out[f * m + j] -= mean }
        }
        return out
    }
}
