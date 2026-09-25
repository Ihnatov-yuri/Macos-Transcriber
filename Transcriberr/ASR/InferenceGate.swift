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
///
/// Dictation runs next to background jobs and must not queue behind them
/// (v3.12.1). Super's whole-track Whisper reading holds a shared slot for
/// half an hour on a long meeting; dictation's Gemma polish queued as an
/// exclusive waiter behind it, and — because waiting exclusive requests
/// block new shared ones — every following dictation Parakeet call queued
/// behind the polish. The polish's 45 s timeout abandoned the call but not
/// its place in the queue, so dictation stayed frozen until Super was
/// cancelled. Three rules since then:
///   - a queued request leaves the queue when its task is cancelled (a
///     timeout that gives up on a call now also gives up its place);
///   - `interactive` requests go ahead of background waiters, and a shared
///     interactive one never waits for a queued exclusive one — it only
///     waits while LiteRT is actually running;
///   - `patience` bounds the wait: past it the request throws `Busy`, and
///     dictation keeps its plain text instead of waiting for Gemma.
actor InferenceGate {
    static let shared = InferenceGate()

    /// Foreground work (dictation): served ahead of background waiters.
    @TaskLocal static var interactive = false
    /// How long a request may wait before giving up with `Busy`; nil waits.
    @TaskLocal static var patience: TimeInterval? = nil

    /// The gate stayed closed for longer than the caller's `patience`.
    struct Busy: Error, LocalizedError {
        var errorDescription: String? { "another transcription is using the engines" }
    }

    private struct Waiter {
        let id: Int
        let exclusive: Bool
        let interactive: Bool
        let continuation: CheckedContinuation<Int, Error>
    }

    private var exclusiveHeld = false
    private var sharedHolders = 0
    private var waiters: [Waiter] = []
    private var generation = 0
    private var nextWaiterId = 0

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
    ///
    /// Throws `CancellationError` when the calling task is cancelled while
    /// queued, and `Busy` once `patience` runs out; neither holds the gate.
    func acquire(exclusive: Bool = false) async throws -> Int {
        guard litertActive else { return -1 }
        let interactive = Self.interactive
        if canAdmit(exclusive: exclusive),
           waiters.isEmpty || (interactive && !waiters.contains { $0.interactive }) {
            admit(exclusive: exclusive)
            return generation
        }
        let id = nextWaiterId
        nextWaiterId += 1
        if let patience = Self.patience {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, patience) * 1_000_000_000))
                await self?.drop(id, with: Busy())
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
                // Runs synchronously on this actor, so a cancellation that
                // lands after this check is handled by `drop` below, which
                // can only run once the waiter is queued.
                if Task.isCancelled { c.resume(throwing: CancellationError()); return }
                let waiter = Waiter(id: id, exclusive: exclusive, interactive: interactive, continuation: c)
                if interactive {
                    // Behind earlier interactive requests, ahead of the rest.
                    let at = waiters.firstIndex { !$0.interactive } ?? waiters.endIndex
                    waiters.insert(waiter, at: at)
                } else {
                    waiters.append(waiter)
                }
                admitWaiters()
            }
        } onCancel: {
            Task { [weak self] in await self?.drop(id, with: CancellationError()) }
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

    /// Take a waiter out of the queue (cancelled, or out of patience). A
    /// waiter already admitted is gone from the queue and keeps its hold.
    private func drop(_ id: Int, with error: Error) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: i)
        waiter.continuation.resume(throwing: error)
        // It may have been the exclusive head holding back shared requests.
        admitWaiters()
    }

    private func canAdmit(exclusive: Bool) -> Bool {
        exclusive ? !exclusiveHeld && sharedHolders == 0 : !exclusiveHeld
    }

    private func admit(exclusive: Bool) {
        if exclusive { exclusiveHeld = true } else { sharedHolders += 1 }
    }

    /// FIFO: admit from the head while the head fits, so an exclusive
    /// waiter holds back every shared request queued behind it. The one
    /// exception is an interactive shared request: it never waits for a
    /// queued exclusive one, only for LiteRT actually running.
    private func admitWaiters() {
        while let head = waiters.first, canAdmit(exclusive: head.exclusive) {
            waiters.removeFirst()
            admit(exclusive: head.exclusive)
            head.continuation.resume(returning: generation)
        }
        guard !exclusiveHeld else { return }
        var i = 0
        while i < waiters.count {
            let w = waiters[i]
            if w.interactive, !w.exclusive {
                waiters.remove(at: i)
                admit(exclusive: false)
                w.continuation.resume(returning: generation)
            } else {
                i += 1
            }
        }
    }
}
