import XCTest
@testable import Transcriberr

/// Target-speaker voice activity: similarity scores → the user's timeline,
/// and how finalize uses it on the mic and in the call audio. No model, no
/// audio: the scores are crafted at the levels measured on real meetings
/// (user 0.49-0.70, other voices at most 0.32, echo residue about 0).
final class VoiceprintTests: XCTestCase {
    private func seg(_ a: Double, _ b: Double, _ t: String, _ key: String?) -> RawSegment {
        RawSegment(startSeconds: a, endSeconds: b, text: t, speakerKey: key)
    }

    private func line(_ text: String, from start: Double, step: Double = 0.4, confidence: Float = 1) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { i, w in
            TimedWord(word: ScoredWord(surface: String(w), norm: TurnTiming.norm(w), confidence: confidence),
                      start: start + Double(i) * step, end: start + Double(i) * step + step * 0.8)
        }
    }

    // MARK: - Timeline

    func testHysteresisKeepsADipInsideATurn() {
        // 0.5 s cells: user, a dip to 0.33 (a word over the far side), user, silence, other voice.
        let scores: [Float?] = [0.6, 0.55, 0.33, 0.6, 0.5, nil, nil, nil, 0.3, 0.32]
        XCTAssertEqual(VoiceActivity.intervals(scores), [0...2.5])
    }

    func testOtherVoicesNeverOpenTheTimeline() {
        let scores: [Float?] = [0.1, 0.32, 0.28, nil, 0.05, 0.31]
        XCTAssertTrue(VoiceActivity.intervals(scores).isEmpty)
    }

    func testShortGapsMerge() {
        // Two stretches 0.5 s apart are one; 1.5 s apart stay two.
        let scores: [Float?] = [0.6, 0.6, nil, 0.6, nil, nil, nil, 0.6]
        XCTAssertEqual(VoiceActivity.intervals(scores), [0...2, 3.5...4])
    }

    func testOpenStretchClosesAtTheEnd() {
        XCTAssertEqual(VoiceActivity.intervals([nil, 0.5, 0.5]), [0.5...1.5])
    }

    func testCoverage() {
        XCTAssertEqual(VoiceActivity.coverage(0, 10, in: [2...4, 8...12]), 0.4, accuracy: 1e-9)
        XCTAssertEqual(VoiceActivity.coverage(3, 3, in: [2...4]), 1)
    }

    func testCosineAndCentroid() {
        XCTAssertEqual(VoiceActivity.cosine([1, 0], [1, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(VoiceActivity.cosine([1, 0], [0, 1]), 0, accuracy: 1e-6)
        let c = VoiceActivity.normalizedMean([[1, 0], [0, 1]])
        XCTAssertEqual(c[0], c[1], accuracy: 1e-6)
        XCTAssertEqual(c[0] * c[0] + c[1] * c[1], 1, accuracy: 1e-5)
        let p = Voiceprint(seconds: 30, embeddings: [[1, 0], [1, 0.1]])
        XCTAssertGreaterThan(p.selfSimilarity, 0.99)
        let decoded = try? JSONDecoder().decode(Voiceprint.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded, p)
    }

    func testSpeechFloorIgnoresSilence() {
        var x = [Float](repeating: 0.0005, count: 16_000 * 4)
        for i in 16_000..<32_000 { x[i] = i % 2 == 0 ? 0.2 : -0.2 }
        let floor = VoiceActivity.speechFloor(x)
        XCTAssertLessThan(floor, 0.2)
        XCTAssertGreaterThanOrEqual(floor, 0.003)
        XCTAssertLessThan(VoiceActivity.rms(x[0..<16_000]), floor)
    }

    // MARK: - The mic gate

    /// The coaching-call bug, at its root: the far side bleeding into the mic
    /// reads confidently, so the loudness timeline's confidence escape kept
    /// it as the user. The voice timeline drops it however confident.
    func testConfidentBleedOfAnotherVoiceIsDropped() {
        let mic = line("я нарешті теж собі повернула батареї", from: 30, confidence: 0.92)
            + line("насправді я сьогодні якраз думав про це", from: 60, confidence: 0.91)
        let out = TurnTiming.retime(
            [seg(26, 52, "Я нарешті теж собі повернула батареї.", "ME"),
             seg(52, 78, "Насправді я сьогодні якраз думав про це.", "ME")],
            timelines: [0: line("x", from: 500), 1: mic], diarization: [],
            micVoice: [59.5...64])
        XCTAssertEqual(out.map(\.text), ["Насправді я сьогодні якраз думав про це."])
    }

    /// Headphones: no echo, so the voice gate alone decides, and a line only
    /// Whisper heard is not dropped for being unanchored.
    func testHeadphoneLineInYourVoiceIsKept() {
        let mic = line("we can ship it on Monday", from: 10, confidence: 0.6)
        let out = TurnTiming.retime(
            [seg(8, 30, "We can ship it on Monday, I think.", "ME")],
            timelines: [0: line("x", from: 500), 1: mic], diarization: [],
            micVoice: [9.5...13], micEcho: false)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].text.hasPrefix("We can ship it on Monday"))
    }

    /// A short reply just after your stretch survives the timeline's
    /// half-second resolution (the same 1 s slack as the speech timeline).
    func testShortReplyNearYourVoiceIsKept() {
        let out = TurnTiming.retime(
            [seg(0, 26, "Bye.", "ME")],
            timelines: [0: line("x", from: 500), 1: line("bye", from: 20)], diarization: [],
            micVoice: [18...19.5])
        XCTAssertEqual(out.map(\.text), ["Bye."])
    }

    /// A mic chunk with no timing at all (Super without max quality) still
    /// goes when none of it is your voice.
    @MainActor
    func testUntimedMicChunkWithoutYourVoiceIsDropped() {
        let runner = TranscriptionRunner(
            factory: BackendFactory(gemma: GemmaSettingsStore(), prompts: PromptStore(), apiKeys: APIKeyStore()),
            prompts: PromptStore(), diarization: DiarizationRunner())
        let out = runner.finalizeSegments(
            [seg(0, 26, "Hello, I'm Joe. Hello, I'm Joe.", "ME"),
             seg(26, 52, "Right, let me share my screen.", "ME"),
             seg(0, 26, "Hello everyone, I'm Joe.", nil)],
            diarize: false, splitTracks: true, expectedSpeakers: 2, diarSegments: [], myName: nil,
            voice: VoiceTimeline(mic: [30...40], sys: []))
        XCTAssertEqual(out.filter { $0.speakerKey == "ME" }.map(\.text), ["Right, let me share my screen."])
    }

    // MARK: - Your voice in the call audio

    func testYourVoiceInTheCallAudioIsACopyOrYours() {
        let segments = [
            seg(10, 14, "I think we should start with the bank.", "ME"),
            // The call sent the same words back: a copy.
            seg(10.4, 14.3, "I think we should start with the bank.", "SPEAKER_01"),
            // The mic missed this one; the call audio has it in your voice.
            seg(30, 33, "And the kiosk can wait a week.", "SPEAKER_01"),
            // Someone else entirely.
            seg(40, 45, "Sounds good to me.", "SPEAKER_01"),
        ]
        let out = TranscriptionRunner.reclaimLeakedVoice(segments, sysVoice: [10...14.5, 29.8...33.2])
        XCTAssertEqual(out.map(\.text), ["I think we should start with the bank.", "And the kiosk can wait a week.", "Sounds good to me."])
        XCTAssertEqual(out.map(\.speakerKey), ["ME", "ME", "SPEAKER_01"])
        XCTAssertEqual(out[1].speakerName, "Me", "a line given back carries the user's name, as mic lines do")
        XCTAssertEqual(TranscriptionRunner.reclaimLeakedVoice(segments, sysVoice: [29.8...33.2], myName: "Yuri")
            .first { $0.text.hasPrefix("And the kiosk") }?.speakerName, "Yuri")
    }

    // MARK: - One track: which cluster is you

    @MainActor
    private func singleTrack(_ clusterVoice: [String: Float]?, myName: String? = "Yuri") -> [RawSegment] {
        let runner = TranscriptionRunner(
            factory: BackendFactory(gemma: GemmaSettingsStore(), prompts: PromptStore(), apiKeys: APIKeyStore()),
            prompts: PromptStore(), diarization: DiarizationRunner())
        return runner.finalizeSegments(
            [seg(0, 5, "So what did the bank say?", "S1"),
             seg(5, 10, "They want the papers by Friday.", "S2"),
             seg(10, 15, "Then we send them on Thursday.", "S1"),
             seg(15, 20, "Fine by me.", "S3")],
            diarize: true, splitTracks: false, expectedSpeakers: 0, diarSegments: [], myName: myName,
            clusterVoice: clusterVoice)
    }

    @MainActor
    func testTheClusterInYourVoiceIsYou() {
        let out = singleTrack(["S1": 0.58, "S2": 0.21, "S3": 0.30])
        XCTAssertEqual(out.map(\.speakerKey), ["ME", "SPEAKER_01", "ME", "SPEAKER_02"])
        XCTAssertEqual(out.filter { $0.speakerKey == "ME" }.map(\.speakerName), ["Yuri", "Yuri"])
    }

    @MainActor
    func testNoClusterClearOfTheThresholdRenamesNothing() {
        let out = singleTrack(["S1": 0.36, "S2": 0.21, "S3": 0.30])
        XCTAssertFalse(out.contains { $0.speakerKey == "ME" })
        XCTAssertEqual(out.map(\.speakerKey), ["SPEAKER_01", "SPEAKER_02", "SPEAKER_01", "SPEAKER_03"])
        XCTAssertEqual(singleTrack(nil).map(\.speakerKey), out.map(\.speakerKey))
    }

    @MainActor
    func testWithoutYourNameYouAreStillMe() {
        let out = singleTrack(["S2": 0.62], myName: nil)
        XCTAssertEqual(out.map(\.speakerKey), ["SPEAKER_01", "ME", "SPEAKER_01", "SPEAKER_02"])
        XCTAssertEqual(out[1].speakerName, "Me", "named as mic lines are when no name is set")
    }

    func testTwoClustersInYourVoiceNameNeither() {
        // One voice split in two, or two alike: neither is named.
        XCTAssertNil(ClusterVoice.user(in: ["S1": 0.55, "S2": 0.49, "S3": 0.1]))
        XCTAssertEqual(ClusterVoice.user(in: ["S1": 0.55, "S2": 0.32]), "S1")
        XCTAssertEqual(ClusterVoice.user(in: ["S1": 0.40]), "S1")
        XCTAssertNil(ClusterVoice.user(in: [:]))
    }

    func testClipsStayInsideTheirOwnClusterSpeech() {
        typealias R = DiarizationRunner.SpeakerSegment
        let regions = [R(startSeconds: 0, endSeconds: 10, speakerId: "S1"),
                       R(startSeconds: 4, endSeconds: 6, speakerId: "S2"),     // overlaps S1
                       R(startSeconds: 20, endSeconds: 21, speakerId: "S2")]   // too short once inset
        let clips = ClusterVoice.clipRanges(regions, sampleCount: 16_000 * 30)
        let s1 = clips["S1"]!.map { (Double($0.lowerBound) / 16_000, Double($0.upperBound) / 16_000) }
        XCTAssertFalse(s1.isEmpty)
        for (a, b) in s1 {
            XCTAssertGreaterThanOrEqual(a, 0.25)
            XCTAssertLessThanOrEqual(b, 9.75)
            XCTAssertTrue(b <= 4 || a >= 6, "clip \(a)-\(b) overlaps S2")
        }
        XCTAssertEqual(clips["S2"], [])
        // A long cluster is sampled, not embedded whole.
        let long = ClusterVoice.clipRanges([R(startSeconds: 0, endSeconds: 3600, speakerId: "S1")], sampleCount: 16_000 * 3600)
        XCTAssertEqual(long["S1"]!.count, ClusterVoice.maxClips)
        XCTAssertGreaterThan(long["S1"]!.last!.lowerBound, 16_000 * 3000)
    }
}
