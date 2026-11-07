import Foundation
import Synchronization

/// Wall-clock deadline for work that may never return — native
/// inference blocks its thread and ignores Swift cancellation. Shared by the
/// chunk loop (`TranscriptionRunner`), post-processing (`PostProcessor`) and
/// live captions (`LiveTranscriber`).
///
/// Three ways the call can end; the first one wins and every later one is
/// dropped (exactly one resume):
///  - the work returns or throws → that result, and the deadline is cancelled
///    (a 0.3 s chunk must not leave a task asleep for two minutes);
///  - the deadline passes → `timeoutError` (evaluated only then — never
///    for a deadline the work beat), and the work is cancelled
///    (best effort: a native call already running may ignore it, but nothing
///    waits on it any more);
///  - the calling task is cancelled → `CancellationError`, and the work is
///    cancelled. Both sides are DETACHED tasks, which inherit nothing —
///    cancellation included — so without this the caller would sit out the
///    whole deadline after Cancel.
///
/// NOT a task group: a group awaits every child before it returns, which
/// would pin each call to the full deadline even when the work finished at once.
///
/// Named `Deadline.run` rather than a free `withDeadline` so it is never
/// shadowed by (or shadows) a type's own `withDeadline` member.
nonisolated enum Deadline {

    static func run<T: Sendable>(
        seconds: TimeInterval,
        timeoutError: @autoclosure @escaping @Sendable () -> any Error,
        priority: TaskPriority = .userInitiated,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = DeadlineRace<T>()
        let nanos = nanoseconds(seconds)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                race.attach(cont)
                // The deadline goes first so the work can cancel it.
                let deadline = Task.detached(priority: priority) {
                    try? await Task.sleep(nanoseconds: nanos)
                    guard !Task.isCancelled else { return }
                    race.settle(.failure(timeoutError()))
                }
                let work = Task.detached(priority: priority) {
                    do {
                        race.settle(.success(try await op()))
                    } catch {
                        race.settle(.failure(error))
                    }
                }
                race.register(work: work, deadline: deadline)
            }
        } onCancel: {
            race.settle(.failure(CancellationError()))
        }
    }

    /// `seconds` as a sleep length: negative (or NaN) is zero, absurdly
    /// large or infinite is capped (the `UInt64` conversion would trap past
    /// ~584 years).
    static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard !seconds.isNaN, seconds > 0 else { return 0 }
        return UInt64(min(seconds, 1e9) * 1_000_000_000)
    }
}

/// The one-shot state behind `Deadline.run` (file scope: Swift forbids type
/// declarations inside generic functions). It holds the continuation itself
/// rather than a bare first-wins flag, so the cancellation handler — which
/// never sees the continuation — can still unblock the caller, and it keeps
/// a result that arrives before the continuation is attached (the handler
/// runs at once when the caller is already cancelled).
nonisolated private final class DeadlineRace<T: Sendable>: Sendable {
    nonisolated private struct State {
        var cont: CheckedContinuation<T, Error>?
        var pending: Result<T, Error>?
        var settled = false
        var work: Task<Void, Never>?
        var deadline: Task<Void, Never>?
    }

    private let state = Mutex(State())

    func attach(_ cont: CheckedContinuation<T, Error>) {
        let early: Result<T, Error>? = state.withLock { s in
            if let p = s.pending {
                s.pending = nil
                return p
            }
            s.cont = cont
            return nil
        }
        if let early { cont.resume(with: early) }
    }

    /// The two tasks, once created. When the race is already over (the
    /// caller was cancelled before they started, or the deadline was zero),
    /// both are cancelled at once.
    func register(work: Task<Void, Never>, deadline: Task<Void, Never>) {
        let over: Bool = state.withLock { s in
            s.work = work
            s.deadline = deadline
            return s.settled
        }
        if over {
            work.cancel()
            deadline.cancel()
        }
    }

    /// First call wins: resumes the caller (or parks the result until the
    /// continuation is attached) and cancels both tasks — the deadline is
    /// no longer needed, and the work is no longer awaited. Later calls are
    /// dropped.
    func settle(_ result: Result<T, Error>) {
        let won: (won: Bool, cont: CheckedContinuation<T, Error>?,
                  work: Task<Void, Never>?, deadline: Task<Void, Never>?) = state.withLock { s in
            guard !s.settled else { return (false, nil, nil, nil) }
            s.settled = true
            let c = s.cont
            s.cont = nil
            if c == nil { s.pending = result }
            return (true, c, s.work, s.deadline)
        }
        guard won.won else { return }
        won.deadline?.cancel()
        won.work?.cancel()
        won.cont?.resume(with: result)
    }
}
