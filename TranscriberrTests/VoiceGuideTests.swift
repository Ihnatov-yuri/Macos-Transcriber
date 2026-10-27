import XCTest
@testable import Transcriberr

/// The voice-print rules over the residual echo suppressor (`VoiceGuide`),
/// and the split canceller staying what it was without a guide.
final class VoiceGuideTests: XCTestCase {
    private let sr = 16_000

    // One score per 0.5 s cell. A frame at t reads the cells from 2 hops
    // before t (a 1.5 s window reaching into it) to t + lead.
    private let e: Float = 1e-2          // loud predicted echo, frame power

    func testMaxScoreReadsTheCellsAroundAFrame() {
        let g = VoiceGuide(scores: [0.1, nil, 0.5, 0.2, 0.0, 0.0, 0.0])
        // t = 1.2 s: cells 0 (from -0.3 s) to 2.
        XCTAssertEqual(g.maxScore(from: 1.2, to: 1.2), 0.5)
        // t = 2.6 s: cells 3 to 5.
        XCTAssertEqual(g.maxScore(from: 2.6, to: 2.6), 0.2)
        // Past the end, or nothing but silent cells: no evidence at all.
        XCTAssertNil(g.maxScore(from: 9, to: 9))
        XCTAssertNil(VoiceGuide(scores: [nil, nil, nil]).maxScore(from: 0.5, to: 0.5))
    }

    func testTheUserIsNeverMuted() {
        let g = VoiceGuide(scores: [0.55, 0.55, 0.55])
        XCTAssertEqual(g.target(base: 0, at: 0.4, echoPower: e), 1, "the print vouches for the user")
    }

    func testTheLeadInKeepsTheFirstSyllable() {
        // Only cell 3 (1.5-2.0 s) matches; a frame at 1.3 s is 0.2 s before it.
        let g = VoiceGuide(scores: [0, 0, 0, 0.6, 0.6])
        XCTAssertEqual(g.target(base: 0, at: 1.3, echoPower: e), 1)
        // Further ahead than the lead-in: the residual test decides.
        XCTAssertEqual(g.target(base: 0, at: 1.0, echoPower: e), 0)
    }

    func testAnEchoBurstStaysMuted() {
        let g = VoiceGuide(scores: [0.03, 0.01, 0.04, 0.02])
        XCTAssertEqual(g.target(base: 1, at: 1.0, echoPower: e), EchoCanceller.nlpFloor,
                       "the residual test opened, but every cell says clearly not the user")
        XCTAssertEqual(g.target(base: 1, at: 1.0, echoPower: 0), 1,
                       "no echo predicted: nothing to call a burst")
    }

    func testSilentCellsAroundEchoStayMuted() {
        // Nothing that sounds like the user, only echo the filter missed:
        // muted. Letting it through cost the user's first words downstream.
        let silent = VoiceGuide(scores: [nil, nil, nil, nil])
        XCTAssertEqual(silent.target(base: 1, at: 1.0, echoPower: e), EchoCanceller.nlpFloor)
    }

    func testAnUnsureScoreLeavesTheResidualTestInCharge() {
        // Between "clearly not you" and "you": the user under loud echo
        // often scores here, so neither rule may act.
        let g = VoiceGuide(scores: [0.2, 0.25, 0.3, 0.2])
        XCTAssertEqual(g.target(base: 1, at: 1.0, echoPower: e), 1)
        XCTAssertEqual(g.target(base: 0, at: 1.0, echoPower: e), 0)
    }

    func testTheScoreCacheDropsItsOldestEntry() {
        let keys = (0...VoiceScoreCache.capacity).map { "cache-test-\($0)-\(UUID())" }
        for k in keys { VoiceScoreCache.put(k, sampleCount: 1, scores: [0.5]) }
        XCTAssertNil(VoiceScoreCache.take(keys[0], sampleCount: 1), "the oldest made room")
        XCTAssertEqual(VoiceScoreCache.take(keys.last!, sampleCount: 1)?.first ?? nil, 0.5, "the newest is kept")
        for k in keys { _ = VoiceScoreCache.take(k, sampleCount: 1) }
    }

    // MARK: - Through the canceller

    private var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
    private func rand() -> Float {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: rng >> 12) % 1000) / 1000.0 * 0.3 - 0.15
    }

    /// 20 s of far-side noise, its echo on the mic, and from 12 s to 13 s a
    /// stretch the reference cannot explain (what the speakers' own
    /// processing does to a phrase start).
    private func echoWithBurst() -> (mic: [Float], sys: [Float], burst: Range<Int>) {
        let n = sr * 20
        var sys = [Float](repeating: 0, count: n)
        var s: Float = 0
        for i in 0..<n { s = 0.7 * s + 0.3 * rand(); sys[i] = s }
        var mic = [Float](repeating: 0, count: n)
        for i in 0..<(n - 400) { mic[i + 400] = 0.35 * sys[i] }
        let burst = (sr * 12)..<(sr * 13)
        var u: Float = 0
        for i in burst { u = 0.7 * u + 0.3 * rand(); mic[i] += 0.5 * u }
        return (mic, sys, burst)
    }

    private func energy(_ x: [Float], _ r: Range<Int>) -> Float {
        r.reduce(0) { $0 + x[$1] * x[$1] }
    }

    func testWithoutAGuideTheSplitCancellerIsUnchanged() {
        let (mic, sys, _) = echoWithBurst()
        guard case .linear(let l) = EchoCanceller.linearStage(mic: mic, ref: sys) else {
            return XCTFail("synthetic echo has a linear path")
        }
        let split = EchoCanceller.suppress(l, mic: mic)
        let whole = EchoCanceller.cancelDetailed(mic: mic, ref: sys)
        XCTAssertEqual(split.samples, whole.samples)
        XCTAssertEqual(split.outcome, whole.outcome)
    }

    func testTheGuideMutesABurstTheResidualTestLetsThrough() {
        let (mic, sys, burst) = echoWithBurst()
        guard case .linear(let l) = EchoCanceller.linearStage(mic: mic, ref: sys) else {
            return XCTFail("synthetic echo has a linear path")
        }
        let windows = Int(Double(mic.count) / Double(sr) / VoiceActivity.hop)
        let unguided = EchoCanceller.suppress(l, mic: mic)
        let notYou = EchoCanceller.suppress(l, mic: mic, guide: VoiceGuide(scores: Array(repeating: 0.02, count: windows)))
        let you = EchoCanceller.suppress(l, mic: mic, guide: VoiceGuide(scores: Array(repeating: 0.6, count: windows)))
        let raw = energy(mic, burst)
        XCTAssertGreaterThan(energy(unguided.samples, burst), raw * 0.1, "the residual test takes the burst for the user")
        XCTAssertLessThan(energy(notYou.samples, burst), raw * 0.001, "clearly not the user: muted")
        XCTAssertGreaterThan(energy(you.samples, burst), raw * 0.1, "the user: kept")
        // Away from the burst, echo stays muted either way.
        let calm = (sr * 15)..<(sr * 19)
        XCTAssertLessThan(energy(notYou.samples, calm), energy(mic, calm) * 0.01)
    }

    func testACancelledRunStopsInsteadOfFallingBack() async {
        let (mic, sys, _) = echoWithBurst()
        let print = Voiceprint(seconds: 30, embeddings: [[1, 0, 0, 0]])
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await EchoCanceller.cancelGuided(mic: mic, ref: sys, print: print)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        let stopped = await task.value
        XCTAssertTrue(stopped, "cancellation is passed on, not treated as a scoring failure")
    }
}
