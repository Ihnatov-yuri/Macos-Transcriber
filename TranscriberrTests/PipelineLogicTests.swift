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
            // Zero-mean: a 0.15 DC offset outweighed the noise ~17:1 in
            // power, and the filter cancelled a constant at ANY lag — the
            // test passed with the delay estimate forced wrong.
            return Float(Int64(bitPattern: rng >> 12) % 1000) / 1000.0 * 0.3 - 0.15
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

    func testPassThroughWithoutLiteRT() async throws {
        let gate = InferenceGate()
        let stamp = try await gate.acquire(exclusive: true)
        XCTAssertEqual(stamp, -1)
    }

    func testSharedHoldersRunTogetherAndExclusiveRunsAlone() async throws {
        let gate = InferenceGate()
        await gate.setLitertActive(true)
        let s1 = try await gate.acquire(), s2 = try await gate.acquire()
        XCTAssertGreaterThanOrEqual(s1, 0)
        XCTAssertGreaterThanOrEqual(s2, 0)

        let order = Order()
        let exclusive = Task { let s = try await gate.acquire(exclusive: true); order.add("X"); return s }
        try await settle()
        // A shared request behind a waiting exclusive one must not jump it.
        let late = Task { let s = try await gate.acquire(); order.add("S"); return s }
        try await settle()
        XCTAssertEqual(order.all, [])

        await gate.release(s1)
        try await settle()
        XCTAssertEqual(order.all, [], "exclusive waits for the last shared holder")
        await gate.release(s2)
        let xs = try await exclusive.value
        try await settle()
        XCTAssertEqual(order.all, ["X"], "shared waits while LiteRT holds the gate")
        await gate.release(xs, exclusive: true)
        _ = try await late.value
        XCTAssertEqual(order.all, ["X", "S"])
    }

    func testEvictExclusiveDropsZombieAndIgnoresItsLateRelease() async throws {
        let gate = InferenceGate()
        await gate.setLitertActive(true)
        let zombie = try await gate.acquire(exclusive: true)
        let w1 = Task { try await gate.acquire() }, w2 = Task { try await gate.acquire() }
        try await settle()
        await gate.evictExclusive()
        let a = try await w1.value, b = try await w2.value
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, zombie)

        let order = Order()
        let next = Task { _ = try await gate.acquire(exclusive: true); order.add("X") }
        try await settle()
        await gate.release(zombie, exclusive: true)   // evicted token: no effect
        await gate.release(a)
        try await settle()
        XCTAssertEqual(order.all, [], "one shared holder is still running")
        await gate.release(b)
        try await next.value
        XCTAssertEqual(order.all, ["X"])
    }

    /// Gemma recovery used to zero the shared count: the Whisper calls still
    /// running on other chunks lost their hold, and the next Gemma call ran
    /// next to them.
    func testEvictExclusiveKeepsLiveSharedHolders() async throws {
        let gate = InferenceGate()
        await gate.setLitertActive(true)
        let whisper = try await gate.acquire(owner: "whisper")
        let order = Order()
        let gemma = Task { let s = try await gate.acquire(exclusive: true); order.add("X"); return s }
        try await settle()
        await gate.evictExclusive()
        try await settle()
        XCTAssertEqual(order.all, [], "Gemma still waits for the running Whisper call")
        await gate.release(whisper)
        _ = try await gemma.value
        XCTAssertEqual(order.all, ["X"])
    }

    /// A Whisper chunk admitted before Gemma loaded is still running when
    /// it does; the first Gemma call must wait for it.
    func testSharedHoldTakenBeforeActivationIsCounted() async throws {
        let gate = InferenceGate()
        let early = try await gate.acquire(owner: "whisper")
        await gate.setLitertActive(true)
        let order = Order()
        let gemma = Task { let s = try await gate.acquire(exclusive: true); order.add("X"); return s }
        try await settle()
        XCTAssertEqual(order.all, [])
        await gate.release(early)
        _ = try await gemma.value
        XCTAssertEqual(order.all, ["X"])
    }

    func testEvictSharedDropsOnlyThatEnginesHolds() async throws {
        let gate = InferenceGate()
        await gate.setLitertActive(true)
        let hungWhisper = try await gate.acquire(owner: "whisper")
        let parakeet = try await gate.acquire(owner: "parakeet")
        let order = Order()
        let gemma = Task { let s = try await gate.acquire(exclusive: true); order.add("X"); return s }
        try await settle()
        await gate.evictShared(owner: "whisper", olderThan: 0)
        try await settle()
        XCTAssertEqual(order.all, [], "Parakeet's hold is not Whisper's to give up")
        await gate.release(parakeet)
        let x = try await gemma.value
        XCTAssertEqual(order.all, ["X"])
        await gate.release(hungWhisper)   // evicted token: no effect
        await gate.release(x, exclusive: true)
    }

    /// Dictation abandoning its own hung call evicts that hold, never a
    /// background hold of the same engine (Super's whole-track reading).
    func testInteractiveEvictionLeavesBackgroundHolds() async throws {
        let gate = InferenceGate()
        let background = try await gate.acquire(owner: "whisper")
        let dictation = try await InferenceGate.$interactive.withValue(true) {
            try await gate.acquire(owner: "whisper")
        }
        await gate.setLitertActive(true)
        let order = Order()
        let gemma = Task { let s = try await gate.acquire(exclusive: true); order.add("X"); return s }
        try await settle()
        await gate.evictShared(owner: "whisper", olderThan: 0, interactiveOnly: true)
        try await settle()
        XCTAssertEqual(order.all, [], "the background reading still holds the gate")
        await gate.release(background)
        _ = try await gemma.value
        XCTAssertEqual(order.all, ["X"])
        await gate.release(dictation)   // evicted token: no effect
    }

    /// The 2026-09-25 freeze: a timed-out dictation polish left its
    /// exclusive request queued behind Super's long Whisper hold, and every
    /// later shared request queued behind that. Cancelling must free the
    /// queue.
    func testCancelledExclusiveWaiterStopsBlockingSharedRequests() async throws {
        let gate = InferenceGate()
        await gate.setLitertActive(true)
        let longHold = try await gate.acquire()                 // Super's whole-track Whisper
        let polish = Task { try await gate.acquire(exclusive: true) }
        try await settle()
        let order = Order()
        let next = Task { let s = try await gate.acquire(); order.add("S"); return s }
        try await settle()
        XCTAssertEqual(order.all, [], "shared request queues behind the waiting exclusive one")
        polish.cancel()
        do { _ = try await polish.value; XCTFail("cancelled waiter must not get the gate") }
        catch is CancellationError {}
        let s = try await next.value
        XCTAssertEqual(order.all, ["S"])
        await gate.release(s)
        await gate.release(longHold)
        // The gate is whole again: an exclusive request gets straight in.
        let x = try await gate.acquire(exclusive: true)
        XCTAssertGreaterThanOrEqual(x, 0)
    }

    func testInteractiveSharedDoesNotWaitForQueuedExclusive() async throws {
        let gate = InferenceGate()
        await gate.setLitertActive(true)
        let longHold = try await gate.acquire()
        let background = Task { try await gate.acquire(exclusive: true) }
        try await settle()
        // Dictation's Parakeet call: runs next to Whisper at once.
        let s = try await InferenceGate.$interactive.withValue(true) { try await gate.acquire() }
        XCTAssertGreaterThanOrEqual(s, 0)
        await gate.release(s)
        await gate.release(longHold)
        let x = try await background.value
        await gate.release(x, exclusive: true)
    }

    func testInteractiveSharedStillWaitsWhileLiteRTRuns() async throws {
        let gate = InferenceGate()
        await gate.setLitertActive(true)
        let x = try await gate.acquire(exclusive: true)
        let order = Order()
        let dictation = Task {
            try await InferenceGate.$interactive.withValue(true) {
                let s = try await gate.acquire(); order.add("D"); return s
            }
        }
        try await settle()
        XCTAssertEqual(order.all, [], "never next to a running LiteRT call")
        await gate.release(x, exclusive: true)
        _ = try await dictation.value
        XCTAssertEqual(order.all, ["D"])
    }

    func testPatienceGivesUpWithBusyAndLeavesTheQueue() async throws {
        let gate = InferenceGate()
        await gate.setLitertActive(true)
        let longHold = try await gate.acquire()
        do {
            _ = try await InferenceGate.$patience.withValue(0.1) { try await gate.acquire(exclusive: true) }
            XCTFail("expected Busy")
        } catch is InferenceGate.Busy {}
        // Nothing left queued: a plain shared request is admitted at once.
        let s = try await gate.acquire()
        await gate.release(s)
        await gate.release(longHold)
    }

    func testInteractiveExclusiveGoesAheadOfBackgroundWaiters() async throws {
        let gate = InferenceGate()
        await gate.setLitertActive(true)
        let hold = try await gate.acquire()
        let order = Order()
        let background = Task { let s = try await gate.acquire(exclusive: true); order.add("B"); return s }
        try await settle()
        let polish = Task {
            try await InferenceGate.$interactive.withValue(true) {
                let s = try await gate.acquire(exclusive: true); order.add("P"); return s
            }
        }
        try await settle()
        await gate.release(hold)
        let p = try await polish.value
        try await settle()
        XCTAssertEqual(order.all, ["P"])
        await gate.release(p, exclusive: true)
        let b = try await background.value
        XCTAssertEqual(order.all, ["P", "B"])
        await gate.release(b, exclusive: true)
    }

    func testSilentChunkDetection() {
        XCTAssertTrue(EnsembleBackend.isSilent([Float](repeating: 0, count: 16_000 * 26)))
        // The quietest real chunk measured peaked at 0.020 RMS.
        var quiet = [Float](repeating: 0, count: 16_000 * 26)
        for i in 0..<16_000 { quiet[160_000 + i] = 0.02 * sinf(Float(i) * 0.3) * 1.414 }
        XCTAssertFalse(EnsembleBackend.isSilent(quiet))
    }
}
