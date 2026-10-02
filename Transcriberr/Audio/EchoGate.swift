import Foundation
import Accelerate

/// Offline echo gate for the playback mix, used when `EchoCanceller` finds
/// an echo path its linear filter cannot follow.
///
/// Measured on a real call (2026-10-02, Bluetooth speaker + USB webcam mic):
/// the speaker→mic path ran ~124 ms and drifted by ~7 ms over 13 minutes,
/// the NLMS stage removed 5-7 dB, and the canceller rightly gave up. The mix
/// then fell back to the live gate, which let 100% of the echo through: it
/// opens on any mic level above 0.02 RMS, and a loud speaker's echo alone
/// clears that. Every word of the far side played twice, 124 ms apart.
///
/// The far side's voice is already pristine in the system track, so while
/// only they talk the mic adds nothing but echo and can be muted outright.
/// The question is per 20 ms frame: is the mic louder than the echo can
/// be? The gate learns the echo level from the recording itself (mic level
/// over the delayed far-side level while the far side talks), compares
/// against the far side's envelope at the measured delay with a reverb
/// tail, and opens only on a clear margin over it. Levels, not waveforms,
/// so a drifting or nonlinear path does not matter.
///
/// Same file: echo 12.4 dB under the far side → 25-30 dB under; the user
/// talking alone keeps 99.7% of their energy. The price is doubletalk: the
/// user talking OVER a loud far side keeps about a third of their energy
/// (a per-band suppressor kept more but let 10 dB more echo through).
enum EchoGate {
    static let frame = 320                 // 20 ms @16 kHz
    /// Frames either side of the delay to take the far-side peak from:
    /// covers the delay estimate's error and its drift over a long call.
    static let spread = 2
    /// Per-frame decay of the far-side envelope: the room keeps ringing
    /// after the far side stops, and the tail must not reopen the gate.
    static let tailDecay: Float = 0.6
    /// Far-side frames louder than this calibrate the echo level.
    static let farActive: Float = 0.01
    /// Percentile of mic/far-side level ratios taken as the echo level.
    /// The spread is wide (12 dB between the median and the 95th on the
    /// measured call), so a median would leave half the echo frames open.
    static let echoPercentile: Float = 0.75
    /// Mic must exceed the expected echo by this factor (6 dB) to open.
    static let margin: Float = 2
    /// Absolute slack over the expected echo — the mic's own noise floor.
    static let noiseFloor: Float = 0.003
    /// Frames the gate stays open after the user's last loud frame, so the
    /// quiet ends of words are not chopped off.
    static let holdFrames = 5

    /// Per-sample gain for `mic` (same length): 1 where the user is heard,
    /// 0 where the mic only carries the far side's echo. `delay` is the
    /// speaker→mic delay in samples.
    static func gains(mic: [Float], ref: [Float], delay: Int) -> [Float] {
        let n = min(mic.count, ref.count)
        let frames = n / frame
        guard frames > 0 else { return [Float](repeating: 1, count: mic.count) }
        let m = frameRMS(mic, frames: frames)
        let s = frameRMS(ref, frames: frames)
        let env = farEnvelope(s, delayFrames: Int((Double(delay) / Double(frame)).rounded()))
        let echo = echoLevel(mic: m, env: env)
        let open = m.indices.map { m[$0] > margin * echo * env[$0] + noiseFloor }
        let g = smooth(open)

        // Ramp between frame centres: a gain that steps every 20 ms clicks.
        var out = [Float](repeating: g.last ?? 1, count: mic.count)
        let half = frame / 2
        for i in 0..<min(n, frames * frame) {
            let pos = Float(i - half) / Float(frame)
            let f = max(0, min(frames - 1, Int(pos.rounded(.down))))
            let next = min(frames - 1, f + 1)
            let t = max(0, min(1, pos - Float(f)))
            out[i] = g[f] + (g[next] - g[f]) * t
        }
        return out
    }

    /// `mic` with the echo-only stretches muted.
    static func apply(mic: [Float], ref: [Float], delay: Int) -> [Float] {
        let g = gains(mic: mic, ref: ref, delay: delay)
        var out = [Float](repeating: 0, count: mic.count)
        vDSP_vmul(mic, 1, g, 1, &out, 1, vDSP_Length(mic.count))
        return out
    }

    static func frameRMS(_ x: [Float], frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        x.withUnsafeBufferPointer { p in
            for f in 0..<frames {
                var v: Float = 0
                vDSP_rmsqv(p.baseAddress! + f * frame, 1, &v, vDSP_Length(frame))
                out[f] = v
            }
        }
        return out
    }

    /// The far side's level as the mic hears it: peak of the delayed
    /// window, held with a decaying tail.
    static func farEnvelope(_ s: [Float], delayFrames: Int) -> [Float] {
        var env = [Float](repeating: 0, count: s.count)
        var held: Float = 0
        for f in s.indices {
            let lo = max(0, f - delayFrames - spread)
            let hi = min(s.count, max(0, f - delayFrames + spread + 1))
            var peak: Float = 0
            if hi > lo { for k in lo..<hi { peak = max(peak, s[k]) } }
            held = max(peak, held * tailDecay)
            env[f] = held
        }
        return env
    }

    /// Echo return as a level ratio, from the frames where the far side
    /// talks. Most of those are echo only; the user's own speech in them
    /// only pushes the estimate up, which errs towards muting echo.
    static func echoLevel(mic: [Float], env: [Float]) -> Float {
        var ratios: [Float] = []
        for f in mic.indices where env[f] > farActive { ratios.append(mic[f] / env[f]) }
        guard !ratios.isEmpty else { return 0 }
        ratios.sort()
        return ratios[min(ratios.count - 1, Int(Float(ratios.count) * echoPercentile))]
    }

    /// Hold, then fast attack / gentler release, per frame.
    static func smooth(_ open: [Bool]) -> [Float] {
        var g = [Float](repeating: 0, count: open.count)
        var hold = 0
        var cur: Float = 1
        for f in open.indices {
            if open[f] { hold = holdFrames }
            let target: Float = hold > 0 ? 1 : 0
            hold = max(0, hold - 1)
            cur += (target > cur ? 0.8 : 0.4) * (target - cur)
            g[f] = cur
        }
        return g
    }
}
