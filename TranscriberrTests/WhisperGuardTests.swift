import XCTest
import os
@testable import Transcriberr

/// The guards around Whisper's native calls (v3.15.9): a slow decode must not
/// look like a hang, and the GPU placement stays opt-in after the freeze of
/// 2026-10-01.
final class WhisperGuardTests: XCTestCase {

    func testLimiterAdmitsWaitersInOrder() async throws {
        let limiter = WhisperCallLimiter(width: 1)
        try await limiter.acquire()
        let order = OrderLog()
        let first = Task { try await limiter.acquire(); await order.add(1); await limiter.release() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = Task { try await limiter.acquire(); await order.add(2); await limiter.release() }
        try await Task.sleep(nanoseconds: 50_000_000)
        await limiter.release()
        try await first.value
        try await second.value
        let seen = await order.items
        XCTAssertEqual(seen, [1, 2])
    }

    func testCancelledWaiterLeavesTheQueueWithoutTakingAPermit() async throws {
        let limiter = WhisperCallLimiter(width: 1)
        try await limiter.acquire()
        let waiter = Task { try await limiter.acquire() }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        do { try await waiter.value; XCTFail("a cancelled waiter must throw") } catch is CancellationError {}
        await limiter.release()
        // The permit is free again: this must not block.
        try await limiter.acquire()
        await limiter.release()
    }

    func testProgressClockRestartsOnEveryToken() async throws {
        let p = WhisperCallProgress()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertGreaterThan(p.sinceLastToken, 0.1)
        p.touch()
        XCTAssertLessThan(p.sinceLastToken, 0.1)
        XCTAssertGreaterThan(p.elapsed, 0.1, "elapsed counts from the start, not from the last token")
    }

    /// 2026-11-11: a Super run the Mac slept through lost 44% of its words.
    /// The budget and the stuck-call age read `Date()`, which counts sleep;
    /// they now read a clock that stands still while the Mac sleeps.
    func testProgressFollowsTheAwakeClockNotTheWallClock() {
        let now = OSAllocatedUnfairLock(initialState: 1_000.0)
        let p = WhisperCallProgress(clock: { now.withLock { $0 } })
        now.withLock { $0 += 5 }
        XCTAssertEqual(p.elapsed, 5, accuracy: 0.001)
        XCTAssertEqual(p.sinceLastToken, 5, accuracy: 0.001)
        // The Mac sleeps for eight hours here: the awake clock does not move.
        XCTAssertLessThan(p.elapsed, WhisperBackend.decodeBudget, "a call the Mac slept through is inside its budget")
        XCTAssertLessThan(p.sinceLastToken, ParakeetBackend.stuckCallAge, "and is not stuck")
        p.touch()
        now.withLock { $0 += 2 }
        XCTAssertEqual(p.sinceLastToken, 2, accuracy: 0.001)
        XCTAssertEqual(p.elapsed, 7, accuracy: 0.001)
    }

    func testAwakeClockIsTheSystemUptimeWhichStopsDuringSleep() {
        XCTAssertEqual(AwakeClock.now, ProcessInfo.processInfo.systemUptime, accuracy: 0.5)
        var watch = AwakeClock.Stopwatch(clock: { 42 })
        XCTAssertEqual(watch.elapsed, 0)
        watch.restart()
        XCTAssertEqual(watch.elapsed, 0)
    }

    func testAwakeSleepWaitsAndHonoursCancellation() async throws {
        let watch = AwakeClock.Stopwatch()
        try await AwakeClock.sleep(seconds: 0.15)
        XCTAssertGreaterThan(watch.elapsed, 0.1)
        try await AwakeClock.sleep(seconds: -1)   // clamped to zero, returns at once
        let waiter = Task { try await AwakeClock.sleep(seconds: 60) }
        waiter.cancel()
        do { try await waiter.value; XCTFail("a cancelled wait must throw") } catch is CancellationError {}
    }

    /// The timers that give up on work wait on the awake clock. A plain
    /// `Task.sleep(nanoseconds:)` here brings back the words lost after sleep.
    func testWorkBudgetsWaitOnTheAwakeClock() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Transcriberr/Utility/Deadline.swift", "Transcriberr/ASR/PersonBrief.swift",
                     "Transcriberr/ASR/Backends/LocalTextBackend.swift", "Transcriberr/ASR/BackendFactory.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains("AwakeClock.sleep(seconds:"), file)
            XCTAssertFalse(source.contains("Task.sleep(nanoseconds:"), "\(file) times work on a clock that counts sleep")
        }
    }

    func testTheCommandLineToolLogsApartFromTheApp() {
        XCTAssertEqual(AppLog.logFileName(isTestHost: false, processName: "Transcriberr"), "transcriberr.log")
        XCTAssertEqual(AppLog.logFileName(isTestHost: false, processName: "transcriberrcli"), "transcriberr-cli.log")
        XCTAssertEqual(AppLog.logFileName(isTestHost: true, processName: "Transcriberr"), "transcriberr-tests.log")
    }

    func testDefaultsAreTheTestedConfiguration() throws {
        let env = ProcessInfo.processInfo.environment
        let d = UserDefaults.standard
        if env["TRANSCRIBERR_WHISPER_COMPUTE"] == nil, d.object(forKey: "whisper.compute") == nil {
            XCTAssertEqual(WhisperBackend.Placement.configured, .ane, "GPU placement is opt-in")
        }
        if env["TRANSCRIBERR_WHISPER_BUDGET"] == nil, d.object(forKey: "whisper.decodeBudget") == nil {
            XCTAssertEqual(WhisperBackend.decodeBudget, 100)
            XCTAssertLessThan(WhisperBackend.decodeBudget, 120, "must give up before the runner's own deadline")
        }
        if env["TRANSCRIBERR_WHISPER_FALLBACKS"] == nil, d.object(forKey: "whisper.fallbacks") == nil {
            XCTAssertEqual(WhisperBackend.fallbackCount, 2)
        }
        if env["TRANSCRIBERR_WHISPER_WIDTH"] == nil, d.object(forKey: "whisper.width") == nil {
            XCTAssertEqual(WhisperBackend.callWidth, 0)
        }
    }
}

private actor OrderLog {
    private(set) var items: [Int] = []
    func add(_ n: Int) { items.append(n) }
}
