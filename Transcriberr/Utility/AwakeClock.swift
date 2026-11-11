import Foundation

/// Seconds the Mac has been awake since boot. It stands still while the Mac
/// sleeps, which is what a budget for work needs: a decode that was paused by
/// a closed lid has not been "running" for the hours the lid was closed.
///
/// `Date()` kept counting through sleep. Measured on 2026-11-11: a Super run
/// that slept through the night came back with 44% of its words missing,
/// because on wake every Whisper call was past its decode budget and every
/// native call looked stuck for an hour.
nonisolated enum AwakeClock {
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Wait for `seconds` of awake time; throws when the task is cancelled.
    /// Every budget, patience and idle timer waits here. `Task.sleep(nanoseconds:)`
    /// counts the time the Mac slept (measured: a 120 s chunk timeout fired
    /// after 1 s awake and 994 s asleep), so it must not time work.
    static func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .nanoseconds(Int64(Deadline.nanoseconds(seconds))), clock: .suspending)
    }

    /// A stopwatch on the awake clock. `clock` is replaceable so tests can
    /// move time by hand.
    struct Stopwatch: Sendable {
        private let clock: @Sendable () -> TimeInterval
        private var start: TimeInterval

        init(clock: @escaping @Sendable () -> TimeInterval = { AwakeClock.now }) {
            self.clock = clock
            self.start = clock()
        }

        var elapsed: TimeInterval { clock() - start }
        mutating func restart() { start = clock() }
    }
}
