import Foundation

/// The on-device text engines (MLX Gemma, uzu Qwen). BackendFactory drops
/// an idle one after a quiet spell; `isBusy` keeps it from doing so under a
/// running or queued generation.
protocol LocalTextBackend: ASRBackend {
    var isBusy: Bool { get async }
    var lastStats: LocalTextStats? { get async }
}

/// What the last generation cost, for the CLI's timing report.
nonisolated struct LocalTextStats: Sendable {
    var promptTokens: Int
    var generatedTokens: Int
    var prefillTokensPerSecond: Double
    var decodeTokensPerSecond: Double
    var seconds: Double
}

/// One generation at a time per text model. Two decodes side by side on one
/// model only split the GPU, and each holds its own KV cache: a brief, a
/// preset and Super's arbiter arriving together would triple the
/// memory for no gain in total time.
///
/// Dictation must not wait behind them:
/// Super's arbiter reading a whole meeting holds the model for minutes.
///   - `interactive` requests go ahead of background ones;
///   - `patience` bounds the wait: past it the request throws `Busy`, and
///     dictation keeps its clean text instead of waiting for the polish;
///   - a request whose task is cancelled while queued (a timeout giving up)
///     leaves the queue, so it never runs for nobody.
actor GenerationQueue {
    /// Foreground work (dictation polish): served ahead of background waiters.
    @TaskLocal static var interactive = false
    /// How long a request may wait before giving up with `Busy`; nil waits.
    @TaskLocal static var patience: TimeInterval? = nil

    /// The model stayed busy for longer than the caller's `patience`.
    struct Busy: Error, LocalizedError {
        var errorDescription: String? { "the text model is busy with another job" }
    }

    private struct Waiter {
        let id: Int
        let interactive: Bool
        let continuation: CheckedContinuation<Void, Error>
    }

    private var running = false
    private var waiters: [Waiter] = []
    private var nextId = 0

    var isBusy: Bool { running || !waiters.isEmpty }

    /// Returns once the caller holds the model; pair with `leave()`.
    /// Throws `CancellationError` or `Busy` without holding it.
    func enter() async throws {
        guard running else { running = true; return }
        let interactive = Self.interactive
        let id = nextId
        nextId += 1
        if let patience = Self.patience {
            Task { [weak self] in
                try? await AwakeClock.sleep(seconds: patience)
                await self?.drop(id, with: Busy())
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                // Runs on this actor, so a cancellation after this check is
                // handled by `drop`, which can only run once queued.
                if Task.isCancelled { c.resume(throwing: CancellationError()); return }
                let waiter = Waiter(id: id, interactive: interactive, continuation: c)
                if interactive {
                    // Behind earlier interactive requests, ahead of the rest.
                    waiters.insert(waiter, at: waiters.firstIndex { !$0.interactive } ?? waiters.endIndex)
                } else {
                    waiters.append(waiter)
                }
            }
        } onCancel: {
            Task { await self.drop(id, with: CancellationError()) }
        }
    }

    func leave() {
        if waiters.isEmpty { running = false } else { waiters.removeFirst().continuation.resume() }
    }

    private func drop(_ id: Int, with error: Error) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume(throwing: error)
    }
}
