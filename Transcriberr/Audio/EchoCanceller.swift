import Foundation
import Accelerate

/// Offline acoustic echo cancellation over the meeting track pair.
///
/// Conditions here are textbook-perfect: the mic (near-end) and system tap
/// (far-end reference) are sample-aligned on ONE clock (the aggregate
/// device), and processing is offline. A bulk-delay estimate aligns the
/// speaker→mic path, then an NLMS adaptive filter predicts the echo from the
/// reference and SUBTRACTS it — unlike a gate, the user's speech survives
/// doubletalk untouched. Geigel-style freeze keeps the filter from adapting
/// while the user talks over the far side.
enum EchoCanceller {
    static let taps = 1024                 // 64 ms echo tail @16 kHz
    static let maxDelaySamples = 4000      // up to 250 ms output latency + air

    static func cancel(mic: [Float], ref: [Float]) -> [Float] {
        let n = min(mic.count, ref.count)
        guard n > 16_000 else { return mic }

        // ---- 1. Bulk delay via cross-correlation (8× decimated, ≤60 s) ----
        let dec = 8
        let span = min(n, 16_000 * 60)
        func decimate(_ x: [Float], upTo: Int) -> [Float] {
            var out: [Float] = []
            out.reserveCapacity(upTo / dec + 1)
            var i = 0
            while i < upTo { out.append(x[i]); i += dec }
            return out
        }
        let md = decimate(mic, upTo: span)
        let rd = decimate(ref, upTo: span)
        let maxLagD = maxDelaySamples / dec
        let len = md.count - maxLagD
        var delay = 0
        if len > 1000 {
            var bestV: Float = -.greatestFiniteMagnitude
            md.withUnsafeBufferPointer { mp in
                rd.withUnsafeBufferPointer { rp in
                    for lag in 0...maxLagD {
                        var v: Float = 0
                        vDSP_dotpr(rp.baseAddress!, 1, mp.baseAddress! + lag, 1, &v, vDSP_Length(len))
                        if v > bestV { bestV = v; delay = lag * dec }
                    }
                }
            }
        }

        // ---- 2. NLMS ----
        var w = [Float](repeating: 0, count: taps)
        var out = mic
        var refPad = [Float](repeating: 0, count: taps)
        refPad.append(contentsOf: ref)
        let mu: Float = 0.5
        var num = 0.0, den = 0.0
        refPad.withUnsafeBufferPointer { rp in
            w.withUnsafeMutableBufferPointer { wp in
                for i in 0..<n {
                    let j = i - delay
                    guard j >= 0 else { continue }
                    var yhat: Float = 0
                    vDSP_dotpr(rp.baseAddress! + j, 1, wp.baseAddress!, 1, &yhat, vDSP_Length(taps))
                    let e = mic[i] - yhat
                    out[i] = e
                    var en: Float = 0
                    vDSP_dotpr(rp.baseAddress! + j, 1, rp.baseAddress! + j, 1, &en, vDSP_Length(taps))
                    // Doubletalk freeze: residual ≫ predicted echo means the
                    // user is talking — subtract, but do not adapt.
                    let doubletalk = e * e > 4 * yhat * yhat && yhat != 0
                    if en > 1e-4 && !doubletalk {
                        var g = mu * e / (en + 1e-6)
                        vDSP_vsma(rp.baseAddress! + j, 1, &g, wp.baseAddress!, 1, wp.baseAddress!, 1, vDSP_Length(taps))
                    }
                    num += Double(mic[i] * mic[i])
                    den += Double(e * e)
                }
            }
        }
        let erle = 10 * log10(num / max(den, 1e-12))
        AppLog.info("aec", String(format: "NLMS done: n=%d delay=%d smp (%.0f ms), ERLE %.1f dB", n, delay, Double(delay) / 16.0, erle))
        // Do no harm: if subtraction didn't reduce energy, there was no echo
        // to cancel (post-v1.7 tracks are gate-cleaned at capture) — keep the
        // original rather than inject filter noise.
        guard erle > 0.5 else {
            AppLog.info("aec", "no echo to cancel — keeping original mic track")
            return mic
        }
        return out
    }
}
