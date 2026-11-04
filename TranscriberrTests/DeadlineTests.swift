import XCTest
@testable import Transcriberr

/// `Deadline.run` — the one first-wins race behind the chunk timeout, the
/// post-processing timeout and the live-caption read deadline.
@MainActor
final class DeadlineTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
    }

    func testResultBeforeTheDeadline() async throws {
        let v = try await Deadline.run(seconds: 30, timeoutError: DeadlineTimedOut()) { 42 }
        XCTAssertEqual(v, 42)
    }

    func testTimeoutThrowsTheGivenErrorWithoutWaitingForTheWork() async throws {
        let started = Date()
        do {
            _ = try await Deadline.run(seconds: 0.1, timeoutError: DeadlineTimedOut()) { () async throws -> Int in
                try? await Task.sleep(nanoseconds: 30_000_000_000)   // ignores cancellation
                return 1
            }
            XCTFail("the deadline must win")
        } catch is DeadlineTimedOut {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testTimeoutCancelsTheWork() async throws {
        let counter = DeadlineCounter()
        do {
            _ = try await Deadline.run(seconds: 0.05, timeoutError: DeadlineTimedOut()) { () async throws -> Int in
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    counter.bump()   // cancelled by the deadline
                    throw error
                }
                return 1
            }
            XCTFail("the deadline must win")
        } catch is DeadlineTimedOut {}
        try await waitUntil { counter.value == 1 }
        XCTAssertEqual(counter.value, 1, "the abandoned work was cancelled")
    }

    func testWorkErrorPassesThrough() async throws {
        do {
            _ = try await Deadline.run(seconds: 30, timeoutError: DeadlineTimedOut()) { () async throws -> Int in
                throw DeadlineBoom()
            }
            XCTFail("expected the work's error")
        } catch is DeadlineBoom {
        } catch {
            XCTFail("expected DeadlineBoom, got \(error)")
        }
    }

    func testOuterCancellationEndsTheWaitAndCancelsTheWork() async throws {
        let counter = DeadlineCounter()
        let started = Date()
        let task = Task { () async throws -> Int in
            try await Deadline.run(seconds: 30, timeoutError: DeadlineTimedOut()) { () async throws -> Int in
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    counter.bump()
                    throw error
                }
                return 1
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled caller must not get a result")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "did not sit out the deadline")
        try await waitUntil { counter.value == 1 }
        XCTAssertEqual(counter.value, 1, "the detached work was cancelled too")
    }

    /// Cancelled before the race starts: the cancellation handler settles
    /// before the continuation is attached — the parked result must still
    /// reach the caller.
    func testAlreadyCancelledCallerGetsCancellationError() async throws {
        let task = Task { () async throws -> Int in
            try await Deadline.run(seconds: 30, timeoutError: DeadlineTimedOut()) { () async throws -> Int in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return 1
            }
        }
        task.cancel()   // before it ever runs (this test holds the main actor)
        do {
            _ = try await task.value
            XCTFail("a cancelled caller must not get a result")
        } catch is CancellationError {}
    }

    func testDeadlineDoesNotFireAfterSuccess() async throws {
        let counter = DeadlineCounter()
        let v = try await Deadline.run(seconds: 0.1, timeoutError: counter.timedOut()) { 7 }
        XCTAssertEqual(v, 7)
        // Well past the deadline: a deadline that was not cancelled would
        // build its error now.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(counter.value, 0, "the deadline was cancelled when the work finished")
    }

    func testSleepLengthIsClamped() {
        XCTAssertEqual(Deadline.nanoseconds(-1), 0)
        XCTAssertEqual(Deadline.nanoseconds(.nan), 0)
        XCTAssertEqual(Deadline.nanoseconds(1.5), 1_500_000_000)
        XCTAssertEqual(Deadline.nanoseconds(.infinity), 1_000_000_000_000_000_000)
        XCTAssertEqual(Deadline.nanoseconds(1e300), 1_000_000_000_000_000_000)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

nonisolated private struct DeadlineTimedOut: Error {}
nonisolated private struct DeadlineBoom: Error {}

nonisolated private final class DeadlineCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    /// The timeout error, counted: built only when a deadline fires.
    func timedOut() -> Error {
        bump()
        return DeadlineTimedOut()
    }
}
