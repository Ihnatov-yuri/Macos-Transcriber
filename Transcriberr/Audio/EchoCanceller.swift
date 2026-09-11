import Foundation
import Accelerate

/// Offline acoustic echo cancellation over the meeting track pair.
///
/// Conditions here are textbook-perfect: the mic (near-end) and system tap
/// (far-end reference) are sample-aligned on ONE clock (the aggregate
/// device), and processing is offline. Three stages:
///
///  1. A bulk-delay estimate aligns the speaker→mic path, gated on the
///     mic and reference actually being correlated at all.
///  2. An NLMS adaptive filter predicts the echo from the reference and
///     SUBTRACTS it — unlike a gate, the user's speech survives doubletalk
///     untouched. A freeze keeps the filter from adapting while the user
///     talks over the far side.
///  3. A residual suppressor mutes the frames the filter could fully
///     explain. Subtraction alone leaves the far side attenuated but
///     intelligible, and an ASR will happily transcribe that as the user.
enum EchoCanceller {
    static let taps = 1024                 // 64 ms echo tail @16 kHz
    static let maxDelaySamples = 4000      // up to 250 ms output latency + air
    static let delayGuard = 256            // 16 ms of slack ahead of the estimate
    static let warmupSamples = 16_000 * 5  // far-end audio before doubletalk gating
    static let minCorrelation: Float = 0.1 // below this there is no echo path
    static let nlpFrame = 320              // 20 ms suppressor decision window
    static let nlpNearEndRatio: Float = 3  // residual/predicted echo meaning "user is here too"
    static let nlpFloor: Float = 0        // echo-only frames go to silence

    /// Start of the `span`-sample stretch of `ref` carrying the most energy.
    /// The delay search needs the far side to actually be TALKING; picking
    /// the window by energy rather than taking the first one is what keeps a
    /// quiet lead-in from deciding the estimate.
    static func loudestWindowStart(ref: [Float], count: Int, span: Int) -> Int {
        guard count > span else { return 0 }
        let step = 16_000                          // 1 s hop
        var best = 0
        var bestE: Double = -1
        var start = 0
        while start + span <= count {
            var e: Float = 0
            ref.withUnsafeBufferPointer { rp in
                vDSP_svesq(rp.baseAddress! + start, 1, &e, vDSP_Length(span))
            }
            if Double(e) > bestE { bestE = Double(e); best = start }
            start += step
        }
        return best
    }

    static func cancel(mic: [Float], ref: [Float]) -> [Float] {
        let n = min(mic.count, ref.count)
        guard n > 16_000 else { return mic }

        // ---- 1. Bulk delay via cross-correlation (8× decimated, ≤60 s) ----
        // Searched inside the LOUDEST 60 s of the reference, not the first
        // 60 s. A call whose opening minute is digital silence — nobody has
        // joined the meeting yet — gave the estimator nothing to lock onto,
        // and the junk lag it returned parked the filter's 64 ms window
        // thousands of samples away from the real echo path. ERLE then came
        // out negative, the do-no-harm guard handed back the raw mic, and the
        // far side reached the ASR as the user's own words.
        let dec = 8
        let span = min(n, 16_000 * 60)
        let searchStart = loudestWindowStart(ref: ref, count: n, span: span)
        func decimate(_ x: [Float], from: Int, count: Int) -> [Float] {
            var out: [Float] = []
            out.reserveCapacity(count / dec + 1)
            var i = from
            let end = from + count
            while i < end { out.append(x[i]); i += dec }
            return out
        }
        let md = decimate(mic, from: searchStart, count: span)
        let rd = decimate(ref, from: searchStart, count: span)
        let maxLagD = maxDelaySamples / dec
        let len = md.count - maxLagD
        var delay = 0
        var bestCorr: Float = 0
        if len > 1000 {
            var refEnergy: Float = 0
            rd.withUnsafeBufferPointer { rp in
                vDSP_svesq(rp.baseAddress!, 1, &refEnergy, vDSP_Length(len))
            }
            let refNorm = refEnergy.squareRoot()
            md.withUnsafeBufferPointer { mp in
                rd.withUnsafeBufferPointer { rp in
                    var micEnergy: Float = 0
                    vDSP_svesq(mp.baseAddress!, 1, &micEnergy, vDSP_Length(len))
                    for lag in 0...maxLagD {
                        var v: Float = 0
                        vDSP_dotpr(rp.baseAddress!, 1, mp.baseAddress! + lag, 1, &v, vDSP_Length(len))
                        // NORMALIZED. A raw dot product just tracks whichever
                        // lag lines up with the loudest stretch of mic, and
                        // leaves no way to tell "found the echo" from "found
                        // nothing at all".
                        let c = abs(v) / (refNorm * micEnergy.squareRoot() + 1e-9)
                        if c > bestCorr { bestCorr = c; delay = lag * dec }
                        if lag < maxLagD {          // slide the mic window on
                            let drop = mp[lag], add = mp[lag + len]
                            micEnergy += add * add - drop * drop
                        }
                    }
                }
            }
        }
        // Mic and reference aren't related: headphones, or a mic the speakers
        // don't reach. Measured peaks — 0.32 on a real call recorded over
        // speakers and 1.0 on synthetic echo, against 0.03 for uncorrelated
        // speech-like noise and 0.0005 for two unrelated tones. Bail out
        // before the filter gets a chance to "explain" the user's own voice
        // with whatever the far side happened to be playing: 1024 taps can
        // turn one sustained tone into another and post 17 dB of ERLE doing
        // it, which the energy check at the end would wave straight through.
        guard bestCorr >= minCorrelation else {
            AppLog.info("aec", String(format: "no echo path (peak correlation %.3f) — keeping original mic track", bestCorr))
            return mic
        }

        // The taps reach only FORWARD from `delay`, covering lags
        // [delay+1, delay+taps]. An unwhitened correlation peak on speech is
        // broad and lands a few dozen samples LATE (measured: 440 against a
        // true direct path at 397), which drops the strongest tap off the
        // near edge of the window — 12 dB of achievable ERLE collapsed to 3.
        // Back the window off so the direct path always sits inside it.
        delay = max(0, delay - delayGuard)

        // ---- 2. NLMS ----
        var w = [Float](repeating: 0, count: taps)
        var out = mic
        // The filter reads the `taps` reference samples ending at j, i.e.
        // ref[j-taps ..< j]. For the first `taps` positions that window
        // starts before the reference does, so a small zero-padded head
        // (`taps` zeros then the first `taps` samples) serves those; every
        // later position reads the reference in place. This used to be a
        // full zero-padded COPY of the reference — one more whole-meeting
        // buffer at the memory peak of a split-track run.
        var head = [Float](repeating: 0, count: taps)
        head.append(contentsOf: ref.prefix(taps))
        if head.count < 2 * taps {
            head.append(contentsOf: repeatElement(0, count: 2 * taps - head.count))
        }
        let mu: Float = 0.5
        // The doubletalk test only applies once the filter has seen
        // `warmupSamples` of far-end audio. It compares the residual against
        // the filter's OWN prediction, so before convergence it can't tell
        // "the user is talking" from "the filter hasn't learned yet": with
        // w ≈ 0 the prediction is ~0, every sample reads as doubletalk, and
        // the filter freezes at its initial value for the rest of the file
        // (measured: 1023 adaptations in a 12 s clip, then nothing). What
        // used to get it moving was the `yhat != 0` clause, which stops
        // applying the moment any tap goes nonzero — so whether it ever
        // bootstrapped came down to whether the delay estimate happened to
        // land right on the echo. Adapting freely through warm-up makes
        // convergence unconditional; the strict test then refines it
        // (measured on a real call: 5.5 dB of echo removed by warm-up alone,
        // 11.2 dB once the strict test takes over).
        var farActiveSamples = 0
        var num = 0.0, den = 0.0
        // Per-frame residual and predicted-echo power, for the suppressor below.
        let frames = n / nlpFrame + 1
        var framePe = [Float](repeating: 0, count: frames)
        var framePy = [Float](repeating: 0, count: frames)
        head.withUnsafeBufferPointer { hp in
        ref.withUnsafeBufferPointer { rp in
            w.withUnsafeMutableBufferPointer { wp in
                for i in 0..<n {
                    let j = i - delay
                    guard j >= 0 else { continue }
                    let win = j < taps ? hp.baseAddress! + j : rp.baseAddress! + (j - taps)
                    var yhat: Float = 0
                    vDSP_dotpr(win, 1, wp.baseAddress!, 1, &yhat, vDSP_Length(taps))
                    let e = mic[i] - yhat
                    out[i] = e
                    var en: Float = 0
                    vDSP_dotpr(win, 1, win, 1, &en, vDSP_Length(taps))
                    let farActive = en > 1e-4
                    if farActive { farActiveSamples += 1 }
                    // Residual ≫ predicted echo means the user is talking over
                    // the far side — subtract, but do not adapt.
                    let doubletalk = farActiveSamples > warmupSamples
                        && e * e > 4 * yhat * yhat
                    if farActive && !doubletalk {
                        var g = mu * e / (en + 1e-6)
                        vDSP_vsma(win, 1, &g, wp.baseAddress!, 1, wp.baseAddress!, 1, vDSP_Length(taps))
                    }
                    let f = i / nlpFrame
                    framePe[f] += e * e
                    framePy[f] += yhat * yhat
                }
            }
        }
        }
        // ---- 3. Residual echo suppressor ----
        // The linear filter alone is not enough for ASR. Measured on a real
        // call: 11 dB of echo removed, and Parakeet still transcribed the far
        // side's entire half of the conversation off the mic track — only
        // garbled, which is worse, because the text-level echo scrub
        // downstream matches degraded copies less well than clean ones.
        //
        // So decide per 20 ms frame whether anything the filter COULDN'T
        // explain is left. Residual well under the predicted echo means the
        // frame was echo and nothing else; residual at or above it means the
        // user is in there too. That ratio is self-normalizing — it never has
        // to know the echo return loss, which varies with speaker volume and
        // how far the mic sits from them. Frames where the far side is silent
        // predict no echo and pass through untouched.
        var gain: Float = 1
        for f in 0..<frames {
            let target: Float = framePe[f] > nlpNearEndRatio * framePy[f] ? 1 : nlpFloor
            // Open fast so the user's first syllable is never clipped, close
            // slower so a gap between words doesn't chop the tail off.
            gain += (target > gain ? 0.6 : 0.5) * (target - gain)
            if gain < 0.999 {
                let lo = f * nlpFrame
                let hi = min(n, lo + nlpFrame)
                if lo < hi {
                    var g = gain
                    out.withUnsafeMutableBufferPointer { op in
                        vDSP_vsmul(op.baseAddress! + lo, 1, &g, op.baseAddress! + lo, 1, vDSP_Length(hi - lo))
                    }
                }
            }
        }
        // Measure BOTH sides over the SAME span. The adaptation loop skips
        // the first `delay` samples (no reference history yet, so `out`
        // there is just the raw mic), but the energy sums used to cover
        // different ranges — signal from `delay` onward, residual over all
        // n. That biased ERLE down by up to about a dB on a short track with
        // a long delay, which is enough to trip the do-no-harm guard below
        // and hand back the uncancelled mic — putting the far side into the
        // user's own transcript, the very thing this filter exists to stop.
        num = 0
        den = 0
        for i in delay..<n {
            num += Double(mic[i] * mic[i])
            den += Double(out[i] * out[i])
        }

        let erle = 10 * log10(num / max(den, 1e-12))
        AppLog.info("aec", String(format: "NLMS done: n=%d, search window @%.0fs, corr %.3f, delay=%d smp (%.0f ms), ERLE %.1f dB",
                                  n, Double(searchStart) / 16_000.0, bestCorr, delay, Double(delay) / 16.0, erle))
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
