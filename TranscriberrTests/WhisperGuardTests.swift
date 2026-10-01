import XCTest
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
