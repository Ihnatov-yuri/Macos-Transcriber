import XCTest
@testable import Transcriberr

/// AudioPostProcessTracker semantics: the transcription job waits for
/// "busy" only, merge/split wait for "pending" as well, and a cancelled
/// waiter leaves promptly without leaking or double-resuming.
final class PipelineRaceTests: XCTestCase {
    private actor Flag {
        private(set) var isSet = false
        func set() { isSet = true }
    }

    /// Spins until `id` has `count` suspended waiters (or fails after ~2 s).
    private func waitForWaiters(_ tracker: AudioPostProcessTracker, _ id: UUID, count: Int,
                                file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 {
            if await tracker.waiterCount(id) == count { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("expected \(count) waiter(s)", file: file, line: line)
    }

    func testJobWaitIgnoresPending() async {
        let tracker = AudioPostProcessTracker()
        let id = UUID()
        await tracker.markPending(id)
        // Would deadlock the auto-transcribe path if it waited on pending.
        await tracker.waitUntilIdle(id)
        let waiters = await tracker.waiterCount(id)
        XCTAssertEqual(waiters, 0)
    }

    func testSettledWaitsThroughPendingAndBusy() async {
        let tracker = AudioPostProcessTracker()
        let id = UUID()
        let done = Flag()
        await tracker.markPending(id)
        let waiter = Task {
            await tracker.waitUntilSettled(id)
            await done.set()
        }
        await waitForWaiters(tracker, id, count: 1)
        await tracker.markBusy(id)
        var isDone = await done.isSet
        XCTAssertFalse(isDone)
        await tracker.markIdle(id)
        await waiter.value
        isDone = await done.isSet
        XCTAssertTrue(isDone)
        let waiters = await tracker.waiterCount(id)
        XCTAssertEqual(waiters, 0)
    }

    func testIdleWaiterResumesWhileSettledWaiterStillWaits() async {
        let tracker = AudioPostProcessTracker()
        let id = UUID()
        let settled = Flag()
        await tracker.markPending(id)
        await tracker.markBusy(id)
        let jobWait = Task { await tracker.waitUntilIdle(id) }
        let mergeWait = Task {
            await tracker.waitUntilSettled(id)
            await settled.set()
        }
        await waitForWaiters(tracker, id, count: 2)
        // Clearing pending alone: busy still holds both.
        await tracker.clearPending(id)
        let stillTwo = await tracker.waiterCount(id)
        XCTAssertEqual(stillTwo, 2)
        await tracker.markIdle(id)
        await jobWait.value
        await mergeWait.value
        let isSettled = await settled.isSet
        XCTAssertTrue(isSettled)
    }

    func testClearPendingReleasesSettledWaiter() async {
        let tracker = AudioPostProcessTracker()
        let id = UUID()
        await tracker.markPending(id)
        let waiter = Task { await tracker.waitUntilSettled(id) }
        await waitForWaiters(tracker, id, count: 1)
        await tracker.clearPending(id)
        await waiter.value
        let waiters = await tracker.waiterCount(id)
        XCTAssertEqual(waiters, 0)
    }

    func testCancelledWaiterLeavesAndIsNotResumedTwice() async {
        let tracker = AudioPostProcessTracker()
        let id = UUID()
        await tracker.markBusy(id)
        let waiter = Task { await tracker.waitUntilIdle(id) }
        await waitForWaiters(tracker, id, count: 1)
        waiter.cancel()
        await waiter.value
        await waitForWaiters(tracker, id, count: 0)
        // Still busy: the cancel must not have cleared anything else, and a
        // later markIdle finds no stale continuation to resume again.
        await tracker.markIdle(id)
        let waiters = await tracker.waiterCount(id)
        XCTAssertEqual(waiters, 0)
    }

    func testAlreadyCancelledTaskDoesNotSuspend() async {
        let tracker = AudioPostProcessTracker()
        let id = UUID()
        await tracker.markBusy(id)
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await tracker.waitUntilSettled(id)
        }
        await waiter.value
        let waiters = await tracker.waiterCount(id)
        XCTAssertEqual(waiters, 0)
    }
}
