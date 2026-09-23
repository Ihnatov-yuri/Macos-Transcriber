import XCTest
@testable import Transcriberr

/// Second wave: speaker-identity logic and canceller robustness.
final class PipelineLogicTests: XCTestCase {

    // MARK: - Name inference

    private func seg(_ t: String, key: String, s: Double = 0) -> RawSegment {
        RawSegment(startSeconds: s, endSeconds: s + 5, text: t, speakerKey: key, speakerName: nil)
    }

    func testSelfIntroductionEnglish() {
        let names = DiarizationRunner().inferSpeakerNames([
            seg("Hi everyone, my name is Matthew and I run recruiting.", key: "SPEAKER_01"),
        ])
        XCTAssertEqual(names["SPEAKER_01"], "Matthew")
    }

    func testSelfIntroductionUkrainian() {
        let names = DiarizationRunner().inferSpeakerNames([
            seg("Добрий день, мене звати Олена, я з команди безпеки.", key: "SPEAKER_01"),
        ])
        XCTAssertEqual(names["SPEAKER_01"], "Олена")
    }

    func testStoplistBlocksNonNames() {
        let names = DiarizationRunner().inferSpeakerNames([
            seg("I'm Sorry about the delay, I'm Really busy.", key: "SPEAKER_01"),
        ])
        XCTAssertNil(names["SPEAKER_01"])
    }

    func testAddresseeRuleNamesTheOtherSpeaker() {
        let names = DiarizationRunner().inferSpeakerNames([
            seg("Hello Jenny, thanks for waiting.", key: "ME", s: 0),
            seg("No problem at all.", key: "SPEAKER_01", s: 6),
        ])
        XCTAssertEqual(names["SPEAKER_01"], "Jenny")
        XCTAssertNil(names["ME"])
    }

    func testAddresseeRuleSilentWithThreeSpeakers() {
        let names = DiarizationRunner().inferSpeakerNames([
            seg("Hello Jenny, welcome.", key: "ME", s: 0),
            seg("Thanks.", key: "SPEAKER_01", s: 6),
            seg("Morning.", key: "SPEAKER_02", s: 12),
        ])
        XCTAssertNil(names["SPEAKER_01"])   // ambiguous addressee → no guess
        XCTAssertNil(names["SPEAKER_02"])
    }

    // MARK: - Speaker assignment by overlap

    func testAssignSpeakersPicksLargestOverlap() {
        let diar = [
            DiarizationRunner.SpeakerSegment(startSeconds: 0, endSeconds: 4, speakerId: "SPEAKER_00"),
            DiarizationRunner.SpeakerSegment(startSeconds: 4, endSeconds: 10, speakerId: "SPEAKER_01"),
        ]
        let out = DiarizationRunner().assignSpeakers(
            segments: [RawSegment(startSeconds: 3, endSeconds: 9, text: "x", speakerKey: nil, speakerName: nil)],
            diarization: diar)
        XCTAssertEqual(out[0].speakerKey, "SPEAKER_01")   // 5s overlap beats 1s
    }

    // MARK: - Destutter edges

    func testDestutterKeepsNumbers() {
        XCTAssertEqual(TextDestutter.collapseLine("The budget is 400 400 thousand."),
                       "The budget is 400 thousand.")
        XCTAssertEqual(TextDestutter.collapseLine("Prices rose 50 60 percent."),
                       "Prices rose 50 60 percent.")   // different numbers untouched
    }

    func testDestutterMultilinePreservesSpeakerLines() {
        let input = "Yuri: so so so we agree.\nLana: yes yes we do."
        XCTAssertEqual(TextDestutter.collapse(input), "Yuri: so we agree.\nLana: yes yes we do.")
        // ("yes" is a legit double — deliberate emphasis survives)
    }

    // MARK: - Echo canceller robustness

    func testEchoCancellerHandlesLargeDelay() {
        let sr = 16_000
        var rng: UInt64 = 7
        func rand() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: rng >> 12) % 1000) / 1000.0 * 0.3
        }
        let n = sr * 10
        var sys = [Float](repeating: 0, count: n)
        var mic = [Float](repeating: 0, count: n)
        var sm: Float = 0
        for i in 0..<n { sm = 0.7 * sm + 0.3 * rand(); sys[i] = sm }
        let d = 2400   // 150 ms
        for i in 0..<(n - d) { mic[i + d] = 0.35 * sys[i] }
        let cleaned = EchoCanceller.cancel(mic: mic, ref: sys)
        let before = mic.reduce(0.0) { $0 + Double($1 * $1) }
        let after = cleaned.reduce(0.0) { $0 + Double($1 * $1) }
        XCTAssertLessThan(after, before * 0.25, "pure echo at 150 ms should lose ≥6 dB")
    }

    /// No chunk — recap included — may exceed the 28 s the LiteRT backend
    /// keeps; the old fixed grid produced up to 33 s and lost the tail.
    func testChunksNeverExceedEngineLimit() {
        let decoder = AudioDecoder()
        // Silences placed to pull one boundary early and the next one late.
        let silences = [26.0, 57.9, 80.5, 113.9].map {
            AudioDecoder.Silence(startSeconds: $0 - 0.2, endSeconds: $0 + 0.2)
        }
        let duration = 200.0
        let cuts = decoder.computeCutPoints(silences: silences, durationSeconds: duration)
        let samples = [Float](repeating: 0, count: Int(duration * AudioDecoder.sampleRate))
        let chunks = decoder.slice(samples: samples, cuts: cuts)
        XCTAssertFalse(chunks.isEmpty)
        for c in chunks {
            XCTAssertLessThanOrEqual(Double(c.samples.count) / AudioDecoder.sampleRate,
                                     AudioDecoder.chunkSeconds + 0.001)
        }
        XCTAssertEqual(chunks.last?.endSeconds ?? 0, duration, accuracy: 0.001)
        XCTAssertEqual(cuts, cuts.sorted())
    }
}

/// The cross-engine gate: Whisper/Parakeet share it, LiteRT holds it alone.
final class InferenceGateTests: XCTestCase {

    private final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        func add(_ e: String) { lock.lock(); events.append(e); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
    }

    private func settle() async throws { try await Task.sleep(nanoseconds: 50_000_000) }

    func testPassThroughWithoutLiteRT() async {
        let gate = InferenceGate()
        let stamp = await gate.acquire(exclusive: true)
        XCTAssertEqual(stamp, -1)
    }

    func testSharedHoldersRunTogetherAndExclusiveRunsAlone() async throws {
        let gate = InferenceGate()
        await gate.setLitertActive(true)
        let s1 = await gate.acquire(), s2 = await gate.acquire()
        XCTAssertGreaterThanOrEqual(s1, 0)
        XCTAssertGreaterThanOrEqual(s2, 0)

        let order = Order()
        let exclusive = Task { let s = await gate.acquire(exclusive: true); order.add("X"); return s }
        try await settle()
        // A shared request behind a waiting exclusive one must not jump it.
        let late = Task { let s = await gate.acquire(); order.add("S"); return s }
        try await settle()
        XCTAssertEqual(order.all, [])

        await gate.release(s1)
        try await settle()
        XCTAssertEqual(order.all, [], "exclusive waits for the last shared holder")
        await gate.release(s2)
        let xs = await exclusive.value
        try await settle()
        XCTAssertEqual(order.all, ["X"], "shared waits while LiteRT holds the gate")
        await gate.release(xs, exclusive: true)
        _ = await late.value
        XCTAssertEqual(order.all, ["X", "S"])
    }

    func testResetEvictsZombieAndIgnoresItsLateRelease() async throws {
        let gate = InferenceGate()
        await gate.setLitertActive(true)
        let zombie = await gate.acquire(exclusive: true)
        let w1 = Task { await gate.acquire() }, w2 = Task { await gate.acquire() }
        try await settle()
        await gate.reset()
        let a = await w1.value, b = await w2.value
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, zombie)

        let order = Order()
        let next = Task { _ = await gate.acquire(exclusive: true); order.add("X") }
        try await settle()
        await gate.release(zombie, exclusive: true)   // stale stamp: no effect
        await gate.release(a)
        try await settle()
        XCTAssertEqual(order.all, [], "one shared holder is still running")
        await gate.release(b)
        await next.value
        XCTAssertEqual(order.all, ["X"])
    }

    func testSilentChunkDetection() {
        XCTAssertTrue(EnsembleBackend.isSilent([Float](repeating: 0, count: 16_000 * 26)))
        // The quietest real chunk measured peaked at 0.020 RMS.
        var quiet = [Float](repeating: 0, count: 16_000 * 26)
        for i in 0..<16_000 { quiet[160_000 + i] = 0.02 * sinf(Float(i) * 0.3) * 1.414 }
        XCTAssertFalse(EnsembleBackend.isSilent(quiet))
    }
}
