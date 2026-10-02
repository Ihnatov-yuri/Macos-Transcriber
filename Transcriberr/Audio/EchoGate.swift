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
/// Two real calls on that setup: echo 10.1 → 24.1 dB and 7.8 → 19.8 dB
/// under the far side; the user talking alone keeps 99.9% of their energy.
/// The price is doubletalk: the user talking OVER a loud far side loses
/// much of what they say (a per-band suppressor kept more but let 10 dB
/// more echo through).
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
    /// The mic's own noise floor: expected echo below it is inaudible and
    /// leaves the gate open; above it the mic must clear echo + floor.
    static let noiseFloor: Float = 0.003
    /// Frames the gate stays open after the user's last loud frame, so the
    /// quiet ends of words are not chopped off.
    static let holdFrames = 5
    /// Gain while closed (-30 dB), not zero: echo ends up ~40 dB under the
    /// far side either way, and the mic's room tone no longer switches off
    /// and on with every far-side phrase.
    static let closedGain: Float = 0.03

    /// One gain per 20 ms frame of `mic`: 1 where the user is heard,
    /// `closedGain` where the mic only carries the far side's echo. `delay`
    /// is the speaker→mic delay in samples. Empty when `mic` is shorter
    /// than a frame.
    static func frameGains(mic: [Float], ref: [Float], delay: Int) -> [Float] {
        let frames = min(mic.count, ref.count) / frame
        guard frames > 0 else { return [] }
        let m = frameRMS(mic, frames: frames)
        let s = frameRMS(ref, frames: frames)
        let env = farEnvelope(s, delayFrames: Int((Double(delay) / Double(frame)).rounded()))
        let echo = echoLevel(mic: m, env: env)
        let states = m.indices.map { f -> FrameState in
            let expected = margin * echo * env[f]
            if expected < noiseFloor { return .noEcho }
            return m[f] > expected + noiseFloor ? .user : .echo
        }
        return smooth(states)
    }

    /// Multiplies `x` in place by `g`, ramped linearly between frame
    /// centres (a gain that steps every 20 ms clicks). Samples past the
    /// last frame take its gain; an empty `g` leaves `x` alone.
    static func applyGains(_ g: [Float], to x: inout [Float]) {
        guard let last = g.last, !x.isEmpty else { return }
        let half = frame / 2
        x.withUnsafeMutableBufferPointer { p in
            func scale(_ from: Int, _ to: Int, _ gain: Float) {
                guard to > from else { return }
                var v = gain
                vDSP_vsmul(p.baseAddress! + from, 1, &v, p.baseAddress! + from, 1, vDSP_Length(to - from))
            }
            scale(0, min(half, p.count), g[0])
            for k in 0..<(g.count - 1) {
                let lo = k * frame + half
                guard lo < p.count else { return }
                let len = min(frame, p.count - lo)
                var start = g[k]
                var step = (g[k + 1] - g[k]) / Float(frame)
                vDSP_vrampmul(p.baseAddress! + lo, 1, &start, &step, p.baseAddress! + lo, 1, vDSP_Length(len))
            }
            scale((g.count - 1) * frame + half, p.count, last)
        }
    }

    /// Mutes `mic`'s echo-only stretches, in place: a whole-meeting buffer
    /// is hundreds of MB, and the rebuild already holds three.
    static func apply(_ mic: inout [Float], ref: [Float], delay: Int) {
        applyGains(frameGains(mic: mic, ref: ref, delay: delay), to: &mic)
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
    /// talks. Most of those are echo only; frames where the user talks over
    /// the far side sit far above the rest and would drag the percentile
    /// up — muting more of the user the more they interject — so a second
    /// pass drops what the first estimate already calls the user.
    static func echoLevel(mic: [Float], env: [Float]) -> Float {
        var ratios: [Float] = []
        for f in mic.indices where env[f] > farActive { ratios.append(mic[f] / env[f]) }
        guard !ratios.isEmpty else { return 0 }
        func percentile(_ r: [Float]) -> Float {
            r.sorted()[min(r.count - 1, Int(Float(r.count) * echoPercentile))]
        }
        let first = percentile(ratios)
        let echoOnly = ratios.filter { $0 <= margin * first }
        return echoOnly.isEmpty ? first : percentile(echoOnly)
    }

    enum FrameState {
        /// The mic is clearly louder than the echo could be.
        case user
        /// No audible echo is expected (the far side and its tail are quiet).
        case noEcho
        /// The mic is at most the far side's echo.
        case echo
    }

    /// Per-frame gain: fast attack; after the user's speech a hold and a
    /// gentle release, so the ends of words survive; after a quiet far side
    /// no hold and a fast close, so the echo of their next phrase is not let
    /// in. The envelope already rises `spread` frames before that echo
    /// reaches the mic.
    static func smooth(_ states: [FrameState]) -> [Float] {
        var g = [Float](repeating: 0, count: states.count)
        var hold = 0
        var cur: Float = 1
        var openedByUser = false
        for f in states.indices {
            if states[f] == .user { hold = holdFrames; openedByUser = true }
            if states[f] == .noEcho { openedByUser = false }
            let target: Float = hold > 0 || states[f] == .noEcho ? 1 : closedGain
            let rate: Float = target > cur ? 0.8 : (openedByUser ? 0.4 : 0.8)
            if hold > 0 { hold -= 1 }
            cur += rate * (target - cur)
            g[f] = cur
        }
        return g
    }
}
