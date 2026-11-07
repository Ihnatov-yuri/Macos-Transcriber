import Foundation

/// Holds background Super runs while a recording is in progress.
///
/// Why: Super's Whisper decoder lands on the CPU (CoreML runs it through
/// BNNS even with the "ane" placement): measured at ~3.4 cores for the
/// whole pass, 26 s chunks taking 31-35 s. Meetings are back to back, so
/// the previous meeting's Super pass (20+ minutes) would run through the
/// next meeting: the fans, the call app and live captions would all pay for it.
/// Super is a background quality pass; nothing is lost by running it after
/// the recording ends.
///
/// Super checks in between chunks and between stages. A native call already
/// running finishes; nothing new starts until the recording stops.
@MainActor
final class RecordingActivity {
    static let shared = RecordingActivity()

    private(set) var isRecording = false
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var nextWaiter = 0

    func begin() {
        guard !isRecording else { return }
        isRecording = true
        AppLog.info("recorder", "recording started — background Super runs hold until it ends")
    }

    func end() {
        guard isRecording else { return }
        isRecording = false
        let resumed = waiters
        waiters.removeAll()
        if !resumed.isEmpty {
            AppLog.info("recorder", "recording ended — \(resumed.count) held Super run(s) carry on")
        }
        for c in resumed.values { c.resume() }
    }

    /// Returns at once when nothing is recording. Throws `CancellationError`
    /// when the waiting task is cancelled (Cancel on a held job).
    func waitUntilIdle() async throws {
        guard isRecording else { return }
        let id = nextWaiter
        nextWaiter += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled || !isRecording {
                    Task.isCancelled ? c.resume(throwing: CancellationError()) : c.resume()
                    return
                }
                waiters[id] = c
            }
        } onCancel: {
            Task { @MainActor [self] in
                waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }
}
