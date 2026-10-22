import XCTest
@testable import Transcriberr

/// The meeting echo filter's FIFO between Apple's voice-processing engine
/// and the meeting aggregate, and the headphone check that decides whether
/// it runs at all. No audio unit is created here (`start` is never called).
final class VoiceProcessedMicTests: XCTestCase {

    private func filled(_ n: Int, _ v: Float) -> [Float] { [Float](repeating: v, count: n) }

    func testNothingBeforeTheRateIsKnown() {
        let mic = VoiceProcessedMic()
        mic.push(filled(4800, 0.1), sourceRate: 48_000)
        XCTAssertNil(mic.pull(480), "samples arriving before setTargetRate are dropped")
    }

    func testWaitsForItsCushionThenDeliversInOrder() {
        let mic = VoiceProcessedMic()
        mic.setTargetRate(48_000)
        mic.push(filled(1000, 0.1), sourceRate: 48_000)
        XCTAssertNil(mic.pull(480), "30 ms cushion + one cycle not there yet — raw mic for this cycle")
        mic.push(filled(1000, 0.2), sourceRate: 48_000)
        let first = mic.pull(480)
        XCTAssertEqual(first?.count, 480)
        XCTAssertEqual(first?.first, 0.1, "oldest samples come out first")
    }

    func testShortCyclePadsInsteadOfFallingBack() {
        let mic = VoiceProcessedMic()
        mic.setTargetRate(48_000)
        for _ in 0..<3 { mic.push(filled(800, 0.3), sourceRate: 48_000) }   // 2400, cushion 1440
        XCTAssertEqual(mic.pull(480)?.count, 480)
        XCTAssertEqual(mic.pull(1800)?.count, 1800)
        // 120 left, 480 asked, the unit delivered just now: pad, keep the timeline.
        let out = mic.pull(480)
        XCTAssertEqual(out?.count, 480)
        XCTAssertEqual(out?[119], 0.3)
        XCTAssertEqual(out?[120], 0)
    }

    /// The tap hands over ~100 ms at a time however small a buffer is asked
    /// for, while the aggregate pulls 10 ms per cycle. Simulated in step:
    /// the cushion must grow to one delivery, so no cycle is ever padded
    /// with silence and nothing is dropped.
    func testLargeTapDeliveriesNeverLeaveHoles() {
        let mic = VoiceProcessedMic()
        mic.setTargetRate(48_000)
        var pulled = 0, padded = 0, fallback = 0
        for cycle in 0..<2_000 {                       // 20 s of 480-sample cycles
            if cycle % 10 == 0 { mic.push(filled(4800, 0.5), sourceRate: 48_000) }
            guard let out = mic.pull(480) else { fallback += 1; continue }
            pulled += 1
            if out.contains(0) { padded += 1 }
        }
        XCTAssertEqual(padded, 0, "a cycle was padded with silence — a hole in the user's voice")
        XCTAssertLessThan(fallback, 20, "only the priming cycles may fall back to the raw mic")
        XCTAssertGreaterThan(pulled, 1_980)
    }

    func testDriftIsTrimmedButNeverBelowTheCushion() {
        let mic = VoiceProcessedMic()
        mic.setTargetRate(48_000)
        // One burst far above the ceiling: the oldest audio goes, so the
        // filtered mic never lags the call audio by more than that.
        mic.push(filled(10_000, 0.1), sourceRate: 48_000)
        mic.push(filled(10_000, 0.5), sourceRate: 48_000)
        var delivered = 0
        while let chunk = mic.pull(480), !chunk.contains(0) { delivered += chunk.count }
        XCTAssertGreaterThanOrEqual(delivered, 10_000 - 480, "at least one delivery is kept")
        XCTAssertLessThan(delivered, 20_000, "the backlog was trimmed")
    }

    func testResamplesWhenTheUnitRunsAtAnotherRate() {
        let mic = VoiceProcessedMic()
        mic.setTargetRate(48_000)
        for _ in 0..<10 { mic.push(filled(441, 0.25), sourceRate: 44_100) }
        let out = mic.pull(480)
        XCTAssertEqual(out?.count, 480)
    }

    func testHeadphoneNames() {
        XCTAssertTrue(VoiceProcessedMic.isHeadphoneName("Yuri’s AirPods Pro"))
        XCTAssertTrue(VoiceProcessedMic.isHeadphoneName("External Headphones"))
        XCTAssertTrue(VoiceProcessedMic.isHeadphoneName("Galaxy Buds2"))
        XCTAssertTrue(VoiceProcessedMic.isHeadphoneName("WH-1000XM5"))
        XCTAssertFalse(VoiceProcessedMic.isHeadphoneName("MacBook Pro Speakers"))
        XCTAssertFalse(VoiceProcessedMic.isHeadphoneName("Soundcore Motion+"))
        XCTAssertFalse(VoiceProcessedMic.isHeadphoneName("Multi-Output Device"))
    }
}

private extension VoiceProcessedMic {
    func push(_ samples: [Float], sourceRate: Double) {
        samples.withUnsafeBufferPointer { push($0, sourceRate: sourceRate) }
    }
}
