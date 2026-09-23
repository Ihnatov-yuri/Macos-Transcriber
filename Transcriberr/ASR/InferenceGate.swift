import Foundation

/// Global gate that keeps LiteRT inference from overlapping any other
/// engine's inference while a LiteRT engine is live.
///
/// Why: LiteRT's Metal path wedges — the native call never returns — when
/// another engine (WhisperKit on GPU, Parakeet on ANE) runs inference
/// concurrently in the same process. Proven empirically on the same
/// 30-chunk meeting: solo Gemma completed clean, while every concurrent
/// dual-engine pairing containing Gemma wedged ~3 times per run regardless
/// of the partner engine. Upstream (LiteRT-LM 0.15/0.16) has no fix.
///
/// A readers-writer lock, not a single file: LiteRT takes it EXCLUSIVE,
/// every other engine takes it SHARED. The first version serialized every
/// engine against every other engine for as long as a LiteRT engine was
/// merely loaded — and Super loads its Gemma arbiter up front, so the whole
/// first pass (where Gemma does nothing) ran one Whisper call at a time:
/// measured on a 42-min meeting, 26.7 min of first pass with the three
/// pipelined chunks queued behind each other. What wedges is LiteRT running
/// at the same time as another engine; Whisper next to Parakeet is the
/// ordinary no-Gemma pipeline and was always fine.
///
/// Waiting exclusive requests block new shared ones, so a Gemma call
/// between pipelined chunks is not starved by a stream of Whisper calls.
///
/// The gate is generation-stamped like GemmaLiteRTBackend's engine lock:
/// a wedged native call never runs its release, so `reset()` (called from
/// wedge recovery) evicts the zombie holders and admits the next waiters
/// by the same rules — never an exclusive holder next to anything else,
/// which would recreate the very concurrency the gate exists to prevent.
/// Recovery paths need the same care as happy paths.
actor InferenceGate {
    static let shared = InferenceGate()

    private struct Waiter {
        let exclusive: Bool
        let continuation: CheckedContinuation<Int, Never>
    }

    private var exclusiveHeld = false
    private var sharedHolders = 0
    private var waiters: [Waiter] = []
    private var generation = 0

    /// True while any GemmaLiteRTBackend holds a live engine. When false,
    /// `acquire()` is a no-op pass-through — pairs without Gemma keep full
    /// cross-engine parallelism.
    private(set) var litertActive = false

    func setLitertActive(_ on: Bool) {
        litertActive = on
        if !on { reset() }
    }

    /// Returns a stamp to pass to `release`. `exclusive` is for LiteRT
    /// only; every other engine shares. Waiters are resumed with the
    /// generation current at hand-off time, so a reset while queued still
    /// yields a valid stamp. A stale stamp releases nothing.
    func acquire(exclusive: Bool = false) async -> Int {
        guard litertActive else { return -1 }
        if waiters.isEmpty, canAdmit(exclusive: exclusive) {
            admit(exclusive: exclusive)
            return generation
        }
        return await withCheckedContinuation {
            waiters.append(Waiter(exclusive: exclusive, continuation: $0))
        }
    }

    func release(_ stamp: Int, exclusive: Bool = false) {
        guard stamp == generation else { return }
        if exclusive {
            guard exclusiveHeld else { return }
            exclusiveHeld = false
        } else {
            guard sharedHolders > 0 else { return }
            sharedHolders -= 1
        }
        admitWaiters()
    }

    /// Evict zombie holders (a wedged native call): invalidate their stamps
    /// and admit queued waiters under the normal rules.
    func reset() {
        generation += 1
        exclusiveHeld = false
        sharedHolders = 0
        admitWaiters()
    }

    private func canAdmit(exclusive: Bool) -> Bool {
        exclusive ? !exclusiveHeld && sharedHolders == 0 : !exclusiveHeld
    }

    private func admit(exclusive: Bool) {
        if exclusive { exclusiveHeld = true } else { sharedHolders += 1 }
    }

    /// FIFO: admit from the head while the head fits, so an exclusive
    /// waiter holds back every shared request queued behind it.
    private func admitWaiters() {
        while let head = waiters.first, canAdmit(exclusive: head.exclusive) {
            waiters.removeFirst()
            admit(exclusive: head.exclusive)
            head.continuation.resume(returning: generation)
        }
    }
}
