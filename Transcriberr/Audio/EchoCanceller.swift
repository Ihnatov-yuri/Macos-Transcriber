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
    /// NLMS step. 0.5 diverged under heavy crosstalk — measured on a
    /// Ukrainian split-track meeting: the filter's output came out 7.3 dB
    /// LOUDER than the raw mic, so the suppressor below, fed a garbage echo
    /// estimate, muted the user's own words (43 of 404 lost to one slice).
    /// 0.1: that meeting +9.9 dB, the English ones 4.7 / 13.8 dB (was 4.8 / 11.2).
    static let stepSize: Float = 0.1
    static let maxDelaySamples = 4000      // up to 250 ms output latency + air
    static let delayGuard = 256            // 16 ms of slack ahead of the estimate
    static let warmupSamples = 16_000 * 5  // far-end audio before doubletalk gating
    static let minCorrelation: Float = 0.1 // below this there is no echo path
    static let nlpFrame = 320              // 20 ms suppressor decision window
    // Residual/predicted echo meaning "user is here too". Was 3: with the
    // step fixed, 1.5 lost 12 of the user's words across the reference
    // slices where 3 lost 21 (and 0.5-step + 3 lost 58), for ~the same echo.
    static let nlpNearEndRatio: Float = 1.5
    static let nlpFloor: Float = 0        // echo-only frames go to silence
    // Below this the suppressor is working from noise. Median per-second
    // linear ERLE measured: 18.7-19.5 dB on three real calls and 22.7 dB on
    // synthetic echo, against 4.0 dB on the meeting with no linear path.
    static let minLinearERLE: Double = 8

    /// Starts of the `k` loudest, non-overlapping `span`-sample stretches of
    /// `ref`, loudest first. The delay search needs the far side to actually
    /// be TALKING; picking by energy rather than taking the first minute is
    /// what keeps a quiet lead-in from deciding the estimate.
    static func loudestWindowStarts(ref: [Float], count: Int, span: Int, k: Int) -> [Int] {
        guard count > span else { return [0] }
        let step = 16_000                          // 1 s hop
        var scored: [(start: Int, energy: Float)] = []
        var start = 0
        while start + span <= count {
            var e: Float = 0
            ref.withUnsafeBufferPointer { rp in
                vDSP_svesq(rp.baseAddress! + start, 1, &e, vDSP_Length(span))
            }
            scored.append((start, e))
            start += step
        }
        var picked: [Int] = []
        for w in scored.sorted(by: { $0.energy > $1.energy }) where picked.count < k {
            if picked.allSatisfy({ abs($0 - w.start) >= span }) { picked.append(w.start) }
        }
        return picked.isEmpty ? [0] : picked
    }

    /// Normalized cross-correlation peak between `mic` and `ref` over one
    /// window (8× decimated), for lags 0…`maxDelaySamples`.
    static func correlationPeak(mic: [Float], ref: [Float], start: Int, span: Int) -> (delay: Int, corr: Float) {
        let dec = 8
        func decimate(_ x: [Float]) -> [Float] {
            var out: [Float] = []
            out.reserveCapacity(span / dec + 1)
            var i = start
            let end = min(x.count, start + span)
            while i < end { out.append(x[i]); i += dec }
            return out
        }
        let md = decimate(mic), rd = decimate(ref)
        let maxLagD = maxDelaySamples / dec
        let len = min(md.count, rd.count) - maxLagD
        var delay = 0
        var bestCorr: Float = 0
        guard len > 1000 else { return (0, 0) }
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
        return (delay, bestCorr)
    }

    static func cancel(mic: [Float], ref: [Float]) -> [Float] {
        cancelDetailed(mic: mic, ref: ref).samples
    }

    /// What `cancel` did with the mic track.
    enum Outcome: Equatable {
        /// Echo subtracted; the samples are the cleaned mic.
        case cancelled
        /// No echo to remove (headphones, no echo path, nothing subtracted,
        /// or too short to tell); the samples are the original mic.
        case noEcho
        /// An echo path exists but the linear filter could not remove it;
        /// the samples are the original mic, WITH its echo. Mixing them
        /// back with the far side plays the far side twice.
        case echoKept
    }

    static func cancelDetailed(mic: [Float], ref: [Float]) -> (samples: [Float], outcome: Outcome) {
        let n = min(mic.count, ref.count)
        guard n > 16_000 else { return (mic, .noEcho) }

        // ---- 1. Bulk delay via cross-correlation (8× decimated, ≤60 s) ----
        // Searched inside the LOUDEST stretches of the reference, not the
        // first 60 s. A call whose opening minute is digital silence — nobody
        // has joined the meeting yet — gave the estimator nothing to lock
        // onto, and the junk lag it returned parked the filter's 64 ms window
        // thousands of samples away from the real echo path.
        // Several windows, not one: on a real 32-minute call the loudest
        // minute of the far side read 0.065 — "no echo path", nothing
        // cancelled — while 100-160 s held a 52 ms echo at 0.36. The best of
        // the four loudest non-overlapping minutes decides.
        let span = min(n, 16_000 * 60)
        var searchStart = 0
        var delay = 0
        var bestCorr: Float = 0
        var tried: [String] = []
        for start in loudestWindowStarts(ref: ref, count: n, span: span, k: 4) {
            let peak = correlationPeak(mic: mic, ref: ref, start: start, span: span)
            tried.append(String(format: "%.0fs:%.3f", Double(start) / 16_000, peak.corr))
            if peak.corr > bestCorr { bestCorr = peak.corr; delay = peak.delay; searchStart = start }
        }
        AppLog.info("aec", "delay search windows \(tried.joined(separator: " "))")
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
            return (mic, .noEcho)
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
        let mu = stepSize
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
                    guard j >= 0 else {
                        // No reference history yet, so no echo prediction:
                        // count the raw mic as residual, or the suppressor
                        // reads these frames as 0 > 0 and mutes them.
                        framePe[i / nlpFrame] += mic[i] * mic[i]
                        continue
                    }
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
        // The suppressor decides from the filter's echo PREDICTION. When the
        // linear stage explains next to nothing, there is no linear echo path
        // (see `minLinearERLE`) and that prediction is noise: muting on it deleted the
        // user's own words. Hand back the raw mic instead; the far side's
        // words are then removed downstream by timing
        // (`EnsembleBackend.echoFiltered`) — that slice: 19.9 → 16.7% WER.
        // Measured as the MEDIAN over 1 s blocks where the far side talks,
        // not over the whole file: the user's own speech is (rightly) never
        // cancelled, so a few seconds of doubletalk dragged a whole-file
        // figure for a textbook echo down to 2.8 dB.
        do {
            let block = 16_000
            var blockERLE: [Double] = []
            var b = delay
            while b + block <= n {
                var m = 0.0, o = 0.0, farActive = 0
                for i in b..<(b + block) {
                    m += Double(mic[i] * mic[i]); o += Double(out[i] * out[i])
                    if abs(ref[max(0, i - delay)]) > 0.01 { farActive += 1 }
                }
                if farActive > block / 4, m > 1e-6 { blockERLE.append(10 * log10(m / max(o, 1e-12))) }
                b += block
            }
            let linearERLE = blockERLE.isEmpty ? 0 : blockERLE.sorted()[blockERLE.count / 2]
            AppLog.info("aec", String(format: "linear stage: median %.1f dB over %d far-end seconds", linearERLE, blockERLE.count))
            if !blockERLE.isEmpty, linearERLE < minLinearERLE {
                AppLog.info("aec", String(format: "linear stage removed only %.1f dB (median of %d far-end seconds, corr %.3f) — no usable echo path, keeping raw mic for echo-by-timing",
                                          linearERLE, blockERLE.count, bestCorr))
                return (mic, .echoKept)
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
            return (mic, .noEcho)
        }
        return (out, .cancelled)
    }
}
