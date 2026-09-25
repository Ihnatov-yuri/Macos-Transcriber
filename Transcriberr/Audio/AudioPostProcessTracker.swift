import Foundation

/// Tracks which recordings currently have background audio post-processing
/// (echo-cancel mix rebuild, AAC compression) in flight, so a reader that
/// needs a recording's files to be stable — namely `RecordingRepository.merge`
/// — can wait for that work to quiesce instead of racing it. Deferring
/// post-processing off `RecordModel.endRecording`'s critical path (so Stop
/// doesn't block on it) reopened a window that used to be closed by
/// compression always finishing before a recording was even saved/visible;
/// this closes it back up without reintroducing the block.
///
/// Two states per recording:
/// - **pending**: post-processing is owed but hasn't started — set from Stop
///   until it finishes. With auto-transcribe on, the rebuild/compression only
///   starts once the transcription job has decoded the source, so the job
///   itself must NOT wait on this state (it would wait on itself).
/// - **busy**: the files are being rewritten or deleted right now.
///
/// The transcription job waits with `waitUntilIdle` (busy only); merge/split,
/// which read the files and must not see them vanish afterwards, wait with
/// `waitUntilSettled` (pending and busy). Both waits return early if the
/// waiting task is cancelled — the caller must check for that.
actor AudioPostProcessTracker {
    private struct Waiter {
        let token: UInt64
        let includePending: Bool
        let cont: CheckedContinuation<Void, Never>
    }

    private var busy: Set<UUID> = []
    private var pending: Set<UUID> = []
    private var waiters: [UUID: [Waiter]] = [:]
    private var nextToken: UInt64 = 0

    /// Post-processing is owed for `id` but not running yet. Cleared by
    /// `markIdle` (or `clearPending` if it will never run).
    func markPending(_ id: UUID) {
        pending.insert(id)
    }

    func clearPending(_ id: UUID) {
        pending.remove(id)
        resumeSatisfied(id)
    }

    func markBusy(_ id: UUID) {
        busy.insert(id)
    }

    /// Post-processing for `id` is over: clears busy AND pending.
    func markIdle(_ id: UUID) {
        busy.remove(id)
        pending.remove(id)
        resumeSatisfied(id)
    }

    /// Suspends while `id`'s files are being rewritten (busy). Does not wait
    /// for pending work — see the type's doc comment.
    func waitUntilIdle(_ id: UUID) async {
        await wait(id, includePending: false)
    }

    /// Suspends until no post-processing is owed or running for `id`.
    func waitUntilSettled(_ id: UUID) async {
        await wait(id, includePending: true)
    }

    private func isClear(_ id: UUID, includePending: Bool) -> Bool {
        !busy.contains(id) && !(includePending && pending.contains(id))
    }

    private func wait(_ id: UUID, includePending: Bool) async {
        guard !isClear(id, includePending: includePending) else { return }
        nextToken += 1
        let token = nextToken
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                // Runs synchronously on the actor: a cancel that landed
                // before this point is seen here; one after it finds the
                // waiter registered via `cancelWaiter`.
                if Task.isCancelled {
                    cont.resume()
                } else {
                    waiters[id, default: []].append(
                        Waiter(token: token, includePending: includePending, cont: cont))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, token: token) }
        }
    }

    /// Every resume goes through removal from `waiters` on the actor, so a
    /// continuation is resumed exactly once whichever path gets there first.
    private func cancelWaiter(_ id: UUID, token: UInt64) {
        guard var list = waiters[id], let idx = list.firstIndex(where: { $0.token == token }) else { return }
        let waiter = list.remove(at: idx)
        waiters[id] = list.isEmpty ? nil : list
        waiter.cont.resume()
    }

    private func resumeSatisfied(_ id: UUID) {
        guard let list = waiters[id] else { return }
        let (ready, still) = (list.filter { isClear(id, includePending: $0.includePending) },
                              list.filter { !isClear(id, includePending: $0.includePending) })
        waiters[id] = still.isEmpty ? nil : still
        for waiter in ready { waiter.cont.resume() }
    }

    /// Number of suspended waiters for `id` (tests only).
    func waiterCount(_ id: UUID) -> Int {
        waiters[id]?.count ?? 0
    }
}
