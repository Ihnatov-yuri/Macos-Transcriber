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

    /// No chunk — recap included — may exceed 28 s (the engines' limit when
    /// it was set); the old fixed grid produced up to 33 s and lost the tail.
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

/// The text model's queue: one generation at a time, dictation first, and a
/// bounded, cancellable wait.
final class GenerationQueueTests: XCTestCase {

    private final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        func add(_ e: String) { lock.lock(); events.append(e); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 50_000_000) }

    func testOneAtATimeInArrivalOrder() async throws {
        let q = GenerationQueue()
        let order = Order()
        try await q.enter()
        let a = Task { try await q.enter(); order.add("a"); await q.leave() }
        await settle()
        let b = Task { try await q.enter(); order.add("b"); await q.leave() }
        await settle()
        XCTAssertEqual(order.all, [], "nothing runs while the model is held")
        await q.leave()
        try await a.value; try await b.value
        XCTAssertEqual(order.all, ["a", "b"])
        let busy = await q.isBusy
        XCTAssertFalse(busy)
    }

    func testInteractiveGoesAheadOfBackground() async throws {
        let q = GenerationQueue()
        let order = Order()
        try await q.enter()
        let background = Task { try await q.enter(); order.add("background"); await q.leave() }
        await settle()
        let dictation = Task {
            try await GenerationQueue.$interactive.withValue(true) { try await q.enter() }
            order.add("dictation"); await q.leave()
        }
        await settle()
        await q.leave()
        try await background.value; try await dictation.value
        XCTAssertEqual(order.all, ["dictation", "background"])
    }

    func testPatienceRunsOutWithBusy() async throws {
        let q = GenerationQueue()
        try await q.enter()
        do {
            try await GenerationQueue.$patience.withValue(0.1) { try await q.enter() }
            XCTFail("should have given up")
        } catch is GenerationQueue.Busy {}
        await q.leave()
        let busy = await q.isBusy
        XCTAssertFalse(busy, "the request that gave up left the queue")
    }

    func testCancelledWaiterLeavesTheQueue() async throws {
        let q = GenerationQueue()
        try await q.enter()
        let waiter = Task { try await q.enter() }
        await settle()
        waiter.cancel()
        do { try await waiter.value; XCTFail("should have been cancelled") } catch is CancellationError {}
        await q.leave()
        let busy = await q.isBusy
        XCTAssertFalse(busy)
    }
}

/// Live captions: phrase ends, paragraphs, and Super held during a recording.
final class LiveCaptionTests: XCTestCase {
    private let sr = LiveTranscriber.sampleRate

    /// `speech` seconds of a 200 Hz tone at -14 dB, then `pause` seconds of
    /// -60 dB room tone, repeated.
    private func audio(_ parts: [(speech: Double, pause: Double)]) -> [Float] {
        var out: [Float] = []
        for p in parts {
            for i in 0..<Int(p.speech * Double(sr)) {
                out.append(0.2 * sin(2 * .pi * 200 * Float(i) / Float(sr)))
            }
            for i in 0..<Int(p.pause * Double(sr)) {
                out.append(0.001 * (i % 2 == 0 ? 1 : -1))
            }
        }
        return out
    }

    private func end(_ samples: [Float]) -> Int? {
        LiveTranscriber.phraseEnd(frames: LiveTranscriber.frameRMS(samples), sampleCount: samples.count)
    }

    func testPauseAfterAPhraseClosesIt() throws {
        let cut = try XCTUnwrap(end(audio([(2.0, 0.6), (1.0, 0)])))
        let seconds = Double(cut) / Double(sr)
        // Inside the pause, not in either stretch of speech.
        XCTAssertGreaterThan(seconds, 2.0)
        XCTAssertLessThan(seconds, 2.6)
    }

    func testShortPauseKeepsThePhraseOpen() {
        XCTAssertNil(end(audio([(2.0, 0.2), (2.0, 0)])))
    }

    func testPauseBeforeMinimumPhraseDoesNotClose() {
        XCTAssertNil(end(audio([(0.8, 0.6), (0.5, 0)])))
    }

    func testTrailingPauseClosesThePhrase() {
        XCTAssertNotNil(end(audio([(3.0, 0.5)])))
    }

    func testUnbrokenSpeechClosesAtTheLimit() throws {
        XCTAssertNil(end(audio([(14.0, 0)])))
        let cut = try XCTUnwrap(end(audio([(16.0, 0)])))
        XCTAssertGreaterThanOrEqual(Double(cut) / Double(sr), 10)
        XCTAssertLessThanOrEqual(cut, 16 * sr)
    }

    /// The values measured on the recording that showed a ghost "Yeah."
    func testVoicedSeparatesAClickFromSpeech() {
        XCTAssertFalse(LiveTranscriber.voiced([0.1, 0.76, 0.2]))
        XCTAssertFalse(LiveTranscriber.voiced([0.24]))
        XCTAssertFalse(LiveTranscriber.voiced([]))
        XCTAssertTrue(LiveTranscriber.voiced([0.1, 1.0]))
    }

    func testSpeechCheckIsOnUnlessTurnedOff() {
        let name = "LiveSpeechCheck.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        XCTAssertTrue(LiveTranscriber.speechCheckOn(d))
        d.set(false, forKey: LiveTranscriber.speechCheckKey)
        XCTAssertFalse(LiveTranscriber.speechCheckOn(d))
    }

    /// Measured: at -20 dB the normal floor left 43 of 5,629 words.
    func testQuietFloorLetsQuietSpeechThrough() {
        var speech = [Float](repeating: 0, count: 200)
        for i in 50..<150 { speech[i] = 0.006 }     // about -44 dB
        XCTAssertFalse(LiveTranscriber.hasSpeech(speech))
        XCTAssertTrue(LiveTranscriber.hasSpeech(speech, quiet: true))
        XCTAssertFalse(LiveTranscriber.hasSpeech([Float](repeating: 0.0005, count: 200), quiet: true))
    }

    func testQuietPausesAreFoundBelowTheFixedFloor() {
        var frames = [Float](repeating: 0.0001, count: 100)
        for i in 0..<60 { frames[i] = 0.006 }
        XCTAssertEqual(LiveTranscriber.pauseThreshold(frames), 0.003)
        XCTAssertEqual(LiveTranscriber.pauseThreshold(frames, quiet: true), 0.0003, accuracy: 0.00001)
    }

    func testQuietFloorChangesNothingForNormalSpeech() {
        let frames = [Float](repeating: 0.001, count: 50) + [Float](repeating: 0.2, count: 50)
        XCTAssertEqual(LiveTranscriber.pauseThreshold(frames, quiet: true), LiveTranscriber.pauseThreshold(frames))
    }

    func testRoomToneIsNotSpeech() {
        XCTAssertFalse(LiveTranscriber.hasSpeech(LiveTranscriber.frameRMS(audio([(0, 3)]))))
        XCTAssertTrue(LiveTranscriber.hasSpeech(LiveTranscriber.frameRMS(audio([(1, 2)]))))
    }

    func testParagraphsJoinCloseLinesOnly() {
        typealias L = LiveTranscriber.LiveLine
        let lines = [
            L(startSeconds: 0, endSeconds: 3, text: "Hello"),
            L(startSeconds: 3.5, endSeconds: 6, text: "there."),
            L(startSeconds: 12, endSeconds: 14, text: "Next topic."),
        ]
        let p = LivePanel.paragraphs(lines)
        XCTAssertEqual(p.map(\.text), ["Hello there.", "Next topic."])
        XCTAssertEqual(p.first?.endSeconds, 6)
    }

    func testParagraphsStopGrowingAtTheLimit() {
        typealias L = LiveTranscriber.LiveLine
        let lines = (0..<20).map { L(startSeconds: Double($0) * 4, endSeconds: Double($0) * 4 + 3.5, text: "w\($0)") }
        let p = LivePanel.paragraphs(lines)
        XCTAssertGreaterThan(p.count, 1)
        XCTAssertTrue(p.allSatisfy { $0.endSeconds - $0.startSeconds < LivePanel.maxParagraphSeconds })
    }

    @MainActor
    func testSuperWaitsForTheRecordingToEnd() async throws {
        let activity = RecordingActivity.shared
        activity.begin()
        defer { activity.end() }
        var released = false
        let waiter = Task { @MainActor in
            try await activity.waitUntilIdle()
            released = true
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(released)
        activity.end()
        try await waiter.value
        XCTAssertTrue(released)
    }

    @MainActor
    func testCancelledWaiterLeavesTheHold() async throws {
        let activity = RecordingActivity.shared
        activity.begin()
        defer { activity.end() }
        let waiter = Task { @MainActor in try await activity.waitUntilIdle() }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("a cancelled wait must throw")
        } catch is CancellationError {}
        XCTAssertTrue(activity.isRecording)
    }

    func testNotRecordingDoesNotWait() async throws {
        try await RecordingActivity.shared.waitUntilIdle()
    }

    // MARK: - Live feed

    private func chunk(_ t: Double) -> WavRecorder.Chunk {
        WavRecorder.Chunk(samples: [Float](repeating: 0, count: 16), startTimeSeconds: t)
    }

    /// v3.16.0: Live off and on again within one recording showed nothing
    /// more. Cancelling the consumer of the recorder's single stream had
    /// terminated it for the rest of the recording.
    func testLiveFeedSurvivesAConsumerBeingCancelled() async throws {
        let feed = LiveChunkFeed(backlog: 8)
        let first = Task { () -> Int in
            var n = 0
            for await _ in feed.subscribe() { n += 1 }
            return n
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        feed.yield(chunk(0))
        try await Task.sleep(nanoseconds: 20_000_000)
        first.cancel()                       // Live switched off
        _ = await first.value
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(feed.subscriberCount, 0, "a cancelled consumer must leave the feed")

        let stream = feed.subscribe()        // Live switched back on
        feed.yield(chunk(1))
        feed.yield(chunk(2))
        feed.finishAll()                     // recording stopped
        var seen: [Double] = []
        for await c in stream { seen.append(c.startTimeSeconds) }
        XCTAssertEqual(seen, [1, 2])
    }

    func testLiveFeedReachesEverySubscriber() async {
        let feed = LiveChunkFeed(backlog: 8)
        let a = feed.subscribe(), b = feed.subscribe()
        feed.yield(chunk(5))
        feed.finishAll()
        var na = 0, nb = 0
        for await _ in a { na += 1 }
        for await _ in b { nb += 1 }
        XCTAssertEqual([na, nb], [1, 1])
        XCTAssertEqual(feed.subscriberCount, 0)
    }

    func testDeadlineGivesUpOnACallThatNeverReturns() async throws {
        let started = Date()
        do {
            _ = try await LiveTranscriber.withDeadline(0.1) { () -> Int in
                try? await Task.sleep(nanoseconds: 60_000_000_000)   // ignores cancellation
                return 1
            }
            XCTFail("the deadline must win")
        } catch is LiveTranscriber.ReadTimeout {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let v = try await LiveTranscriber.withDeadline(5) { 42 }
        XCTAssertEqual(v, 42)
    }
}
