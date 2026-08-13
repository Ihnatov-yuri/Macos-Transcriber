import Foundation

/// Global FIFO gate that serializes heavy native inference across engines
/// while a LiteRT engine is live.
///
/// Why: LiteRT's Metal path wedges — the native call never returns — when
/// another engine (WhisperKit on GPU, Parakeet on ANE) runs inference
/// concurrently in the same process. Proven empirically on the same
/// 30-chunk meeting: solo Gemma completed clean, while every concurrent
/// dual-engine pairing containing Gemma wedged ~3 times per run regardless
/// of the partner engine. Upstream (LiteRT-LM 0.15/0.16) has no fix.
///
/// The gate is generation-stamped like GemmaLiteRTBackend's engine lock:
/// a wedged native call never runs its release, so `reset()` (called from
/// wedge recovery) evicts the zombie holder and hands the gate to exactly
/// one queued waiter — never all of them, which would recreate the very
/// concurrency the gate exists to prevent. Recovery paths need the same
/// care as happy paths.
actor InferenceGate {
    static let shared = InferenceGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Int, Never>] = []
    private var generation = 0

    /// True while any GemmaLiteRTBackend holds a live engine. When false,
    /// `acquire()` is a no-op pass-through — pairs without Gemma keep full
    /// cross-engine parallelism.
    private(set) var litertActive = false

    func setLitertActive(_ on: Bool) {
        litertActive = on
        if !on { reset() }
    }

    /// Returns a stamp to pass to `release`. Waiters are resumed with the
    /// generation current at hand-off time, so a reset while queued still
    /// yields a valid stamp. A stale stamp releases nothing.
    func acquire() async -> Int {
        guard litertActive else { return -1 }
        if busy {
            return await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        return generation
    }

    func release(_ stamp: Int) {
        guard stamp == generation, busy else { return }
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume(returning: generation)
        }
    }

    /// Evict a zombie holder (wedged native call): invalidate its stamp and
    /// hand the gate to the next queued waiter, if any.
    func reset() {
        generation += 1
        if waiters.isEmpty {
            busy = false
        } else {
            busy = true
            waiters.removeFirst().resume(returning: generation)
        }
    }
}
