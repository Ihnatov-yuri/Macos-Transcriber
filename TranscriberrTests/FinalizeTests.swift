import XCTest
@testable import Transcriberr

/// Tests over the EXTRACTED finalize sequence — the most-fixed logic in the
/// app, now pinned end-to-end: echo scrub → boundary trim → identity →
/// cap-fold → renumber → filler removal → coalesce → names.
@MainActor
final class FinalizeTests: XCTestCase {
    var savedGap: Double = 0
    override func setUp() {
        savedGap = UserDefaults.standard.double(forKey: "ui.turnCoalesceGapSeconds")
        UserDefaults.standard.set(30.0, forKey: "ui.turnCoalesceGapSeconds")
    }
    override func tearDown() {
        UserDefaults.standard.set(savedGap, forKey: "ui.turnCoalesceGapSeconds")
    }

    private func makeRunner() -> TranscriptionRunner {
        TranscriptionRunner(
            factory: BackendFactory(gemma: GemmaSettingsStore(), prompts: PromptStore(),
                                    apiKeys: APIKeyStore()),
            prompts: PromptStore(),
            diarization: DiarizationRunner())
    }

    private func seg(_ a: Double, _ b: Double, _ t: String,
                     _ key: String?, name: String? = nil) -> RawSegment {
        RawSegment(startSeconds: a, endSeconds: b, text: t, speakerKey: key, speakerName: name)
    }

    /// The kitchen-sink meeting: crawl + echo + two phantom clusters + an
    /// unlabeled segment + filler + a greeting. One call, every rule.
    func testFullMeetingFinalizeScenario() {
        let input = [
            seg(0, 6, "We can talk now or would you prefer to schedule?", "SPEAKER_85"),
            seg(6, 12, "schedule. Hello Jenny, no worries at all.", "ME", name: "Yuri"),
            seg(12, 18, "I saw your resume and the migration project details yesterday evening.", "SPEAKER_85"),
            seg(18, 24, "Great. I saw your resume and the migration project details yesterday evening. Let me add some context about the budget.", "ME", name: "Yuri"),
            seg(24, 26, "Sure.", "SPEAKER_42"),
            seg(26, 28, "That works for me as well.", nil),
            seg(28, 29, "Mm-hmm.", "SPEAKER_85"),
        ]
        let out = makeRunner().finalizeSegments(
            input, diarize: true, splitTracks: true, expectedSpeakers: 2,
            diarSegments: [], myName: "Yuri")

        let keys = Set(out.compactMap { $0.speakerKey })
        XCTAssertEqual(keys, ["ME", "SPEAKER_01"], "cap-fold + renumber must yield exactly you + one other")

        let meText = out.filter { $0.speakerKey == "ME" }.map(\.text).joined(separator: " ")
        XCTAssertFalse(meText.hasPrefix("schedule"), "boundary crawl must be trimmed")
        XCTAssertTrue(meText.contains("Hello Jenny"))
        XCTAssertFalse(meText.contains("resume"), "echoed sentence must be scrubbed from ME")
        XCTAssertTrue(meText.contains("budget"), "user's own words must survive the scrub")

        XCTAssertFalse(out.contains { $0.text.contains("Mm-hmm") }, "pure filler segment dropped")
        let jenny = out.first { $0.speakerKey == "SPEAKER_01" }
        XCTAssertEqual(jenny?.speakerName, "Jenny", "addressee rule names the other speaker")
    }

    func testFoldedClusterSelfIntroNamesTheSurvivor() {
        let input = [
            seg(0, 20, "Long explanation about the roadmap and the deliverables for this quarter.", "SPEAKER_07"),
            seg(20, 22, "By the way my name is Matthew.", "SPEAKER_03"),
            seg(22, 30, "And there is more detail on the second milestone to cover.", "SPEAKER_07"),
        ]
        let out = makeRunner().finalizeSegments(
            input, diarize: true, splitTracks: true, expectedSpeakers: 2,
            diarSegments: [], myName: nil)
        let keys = Set(out.compactMap { $0.speakerKey })
        XCTAssertEqual(keys, ["SPEAKER_01"], "small cluster folds into dominant, renumbered")
        XCTAssertTrue(out.contains { $0.speakerName == "Matthew" },
                      "self-intro inside the folded cluster names the survivor")
    }

    func testNonMeetingNonDiarizedPassesThrough() {
        let input = [seg(0, 5, "Plain recording text here.", nil)]
        let out = makeRunner().finalizeSegments(
            input, diarize: false, splitTracks: false, expectedSpeakers: 0,
            diarSegments: [], myName: "Yuri")
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[0].speakerKey, "plain recordings must be untouched")
    }

    func testDiarFillAssignsFromRegions() {
        let input = [seg(0, 5, "Some spoken words here.", nil)]
        let regions = [DiarizationRunner.SpeakerSegment(startSeconds: 0, endSeconds: 5, speakerId: "SPEAKER_00")]
        let out = makeRunner().finalizeSegments(
            input, diarize: true, splitTracks: false, expectedSpeakers: 0,
            diarSegments: regions, myName: nil)
        XCTAssertEqual(out.first?.speakerKey, "SPEAKER_01", "filled from region, then renumbered")
    }

    // MARK: - Capture gate math

    func testGateClosesOnFarSideOnly() {
        var g: Float = 1
        for _ in 0..<40 { g = MeetingRecorder.gateStep(micRMS: 0.001, tapRMS: 0.2, currentGain: g) }
        XCTAssertLessThan(g, 0.01, "mic must be fully gated while only the far side plays")
    }

    func testGateOpensInstantlyOnAbsoluteSpeech() {
        var g: Float = 0
        g = MeetingRecorder.gateStep(micRMS: 0.05, tapRMS: 0.3, currentGain: g)
        g = MeetingRecorder.gateStep(micRMS: 0.05, tapRMS: 0.3, currentGain: g)
        XCTAssertGreaterThan(g, 0.8, "clear speech opens the gate even against a loud far side")
    }

    func testGateStaysOpenInSilence() {
        let g = MeetingRecorder.gateStep(micRMS: 0.0005, tapRMS: 0.0005, currentGain: 1)
        XCTAssertEqual(g, 1.0, accuracy: 0.001)
    }

    // MARK: - Mic / tap disambiguation

    func testTapChannelCountNeverMatchesTheMic() {
        XCTAssertEqual(MeetingRecorder.tapChannelCount(forMicStreams: [1]), 2, "mono mic → stereo tap")
        XCTAssertEqual(MeetingRecorder.tapChannelCount(forMicStreams: [2]), 1, "stereo mic → mono tap")
        XCTAssertEqual(MeetingRecorder.tapChannelCount(forMicStreams: [9]), 2, "9-channel wide-range mic → stereo tap")
        XCTAssertEqual(MeetingRecorder.tapChannelCount(forMicStreams: []), 2, "unknown mic → default stereo")
        XCTAssertEqual(MeetingRecorder.tapChannelCount(forMicStreams: [1, 2]), 2, "both counts in use → default, position decides")
    }

    func testTapBufferIndexFollowsChannelCountNotPosition() {
        XCTAssertEqual(MeetingRecorder.tapBufferIndex(channelCounts: [1, 2], tapChannels: 2), 1)
        XCTAssertEqual(MeetingRecorder.tapBufferIndex(channelCounts: [2, 1], tapChannels: 2), 0, "tap first must not be mistaken for the mic")
        XCTAssertEqual(MeetingRecorder.tapBufferIndex(channelCounts: [2, 1], tapChannels: 1), 1, "stereo mic + mono tap")
        XCTAssertEqual(MeetingRecorder.tapBufferIndex(channelCounts: [1, 2, 1], tapChannels: 2), 1, "two mic streams around the tap")
        XCTAssertNil(MeetingRecorder.tapBufferIndex(channelCounts: [2, 2], tapChannels: 2), "stereo mic + stereo tap is ambiguous")
        XCTAssertNil(MeetingRecorder.tapBufferIndex(channelCounts: [1, 2, 2], tapChannels: 2), "mono+stereo mic + stereo tap is ambiguous")
    }
}

extension FinalizeTests {
    func testFuzzyHeadCrawlTrimmed() {
        let out = TranscriptionRunner.trimBoundaryEcho(
            from: "scheduled. No, that's fine with me.",
            afterTailOf: "Or would you prefer to schedule?")
        XCTAssertEqual(out, "No, that's fine with me.", "ASR-degraded echo must match fuzzily")
    }

    func testTailCrawlTrimmed() {
        let out = TranscriptionRunner.trimBoundaryEchoTail(
            from: "It needs complex API troubleshooting.",
            beforeHeadOf: "Troubleshooting. And ultimately, given the nature of it.")
        XCTAssertEqual(out, "It needs complex API", "far side's first word leaking into ME tail must trim")
    }

    func testTailTrimProtectsShortWords() {
        let out = TranscriptionRunner.trimBoundaryEchoTail(
            from: "I think that is true.",
            beforeHeadOf: "True. But consider the cost.")
        XCTAssertEqual(out, "I think that is true.", "4-letter words never trim alone")
    }

    // MARK: - Scrap clusters and GUEST (2026-10-16)

    private func region(_ a: Double, _ b: Double, _ k: String) -> DiarizationRunner.SpeakerSegment {
        DiarizationRunner.SpeakerSegment(startSeconds: a, endSeconds: b, speakerId: k)
    }

    func testScrapClustersFoldIntoTheirNeighbours() {
        // Two real voices and a 4 s scrap next to B.
        var real: [DiarizationRunner.SpeakerSegment] = []
        for i in 0..<20 {
            let t = Double(i) * 10
            real.append(region(t, t + 8, i % 2 == 0 ? "A" : "B"))
        }
        let folded = DiarizationRunner.foldScraps(real + [region(205, 209, "C")])
        let ids: [String] = folded.map { $0.speakerId }
        XCTAssertEqual(Set(ids), ["A", "B"])
        XCTAssertEqual(folded.last?.speakerId, "B", "the scrap goes to the nearest real region")
        // A quiet but real voice (here 24 s over several regions) stays.
        let quiet = real + [region(300, 306, "D"), region(320, 326, "D"), region(340, 352, "D")]
        let quietIds: [String] = DiarizationRunner.foldScraps(quiet).map { $0.speakerId }
        XCTAssertEqual(Set(quietIds), ["A", "B", "D"])
        // One voice only: nothing to fold into.
        let one: [String] = DiarizationRunner.foldScraps([region(0, 3, "A")]).map { $0.speakerId }
        XCTAssertEqual(one, ["A"])
    }

    func testCallAudioOutsideTheRegionsGetsTheNearestVoiceNotGuest() {
        let diar = [region(0, 10, "S1"), region(20, 30, "S2"), region(100, 110, "S1")]
        let input = [
            RawSegment(startSeconds: 2, endSeconds: 8, text: "We start with the budget"),
            RawSegment(startSeconds: 21, endSeconds: 29, text: "Sounds good to me"),
            // In a gap, 1 s after S2: S2's.
            RawSegment(startSeconds: 31, endSeconds: 33, text: "and the timeline too"),
            // In silence, far from any speech: noise, dropped.
            RawSegment(startSeconds: 60, endSeconds: 61, text: "100%"),
            // Far, but a real sentence: kept, nearest voice.
            RawSegment(startSeconds: 70, endSeconds: 75, text: "Can everyone hear me now please"),
        ]
        let out = makeRunner().finalizeSegments(input, diarize: true, splitTracks: true, expectedSpeakers: 0,
                                                diarSegments: diar, myName: "Yuri")
        XCTAssertFalse(out.contains { $0.speakerKey == "GUEST" }, "\(out.map { ($0.speakerKey, $0.text) })")
        XCTAssertFalse(out.contains { $0.text.contains("100%") })
        XCTAssertTrue(out.contains { $0.text.contains("timeline") })
        XCTAssertTrue(out.contains { $0.text.contains("hear me") })
        XCTAssertEqual(Set(out.compactMap(\.speakerKey)).count, 2)
    }

    // MARK: - Short replies far from the regions (2026-10-18)

    /// The diarizer drops speech under a second, so a quick reply between
    /// two stretches of the user talking is far from every region. With
    /// sound under it, it stays; over silence, or with no letter in it (a
    /// backchannel Parakeet wrote as "100%"), it goes.
    func testFarShortReplyStaysWhenTheCallTrackHasSound() {
        let diar = [region(0, 12, "S1"), region(60, 80, "S1")]
        let input = [
            RawSegment(startSeconds: 2, endSeconds: 10, text: "Shall we start with the budget"),
            RawSegment(startSeconds: 30.2, endSeconds: 31.0, text: "Yes, definitely."),
            RawSegment(startSeconds: 40.0, endSeconds: 40.6, text: "100%"),
            RawSegment(startSeconds: 50.0, endSeconds: 50.5, text: "Thanks."),
            RawSegment(startSeconds: 62, endSeconds: 70, text: "Then the timeline"),
        ]
        let sound = [2.0...10.0, 30.3...30.9, 40.1...40.5, 62.0...70.0]
        let out = makeRunner().finalizeSegments(input, diarize: true, splitTracks: true, expectedSpeakers: 0,
                                                diarSegments: diar, myName: "Yuri", sysSound: sound)
        let texts = out.map(\.text).joined(separator: " | ")
        XCTAssertTrue(texts.contains("definitely"), texts)
        XCTAssertFalse(texts.contains("100%"), texts)
        XCTAssertFalse(texts.contains("Thanks"), texts)
        let s1 = out.first { $0.text.contains("budget") }?.speakerKey
        XCTAssertNotNil(s1)
        XCTAssertEqual(out.first { $0.text.contains("definitely") }?.speakerKey, s1, "the nearest voice")
        // A dump from before the sound timeline replays on distance alone.
        let old = makeRunner().finalizeSegments(input, diarize: true, splitTracks: true, expectedSpeakers: 0,
                                                diarSegments: diar, myName: "Yuri")
        XCTAssertFalse(old.map(\.text).joined().contains("definitely"))
    }

    func testSoundRangesSeeShortWordsButNotClicksOrSilence() {
        let rate = 16_000
        var x = [Float](repeating: 0, count: rate * 10)
        func tone(_ a: Double, _ b: Double) {
            for i in Int(a * Double(rate))..<Int(b * Double(rate)) { x[i] = 0.2 * sin(Float(i) * 0.3) }
        }
        tone(2.0, 2.3)      // a short word
        tone(5.0, 5.04)     // a click
        tone(7.0, 7.3); tone(7.4, 7.6)   // two syllables, one word
        let r = VoiceActivity.soundRanges(x)
        XCTAssertEqual(r.count, 2, "\(r)")
        XCTAssertEqual(r[0].lowerBound, 2.0, accuracy: 0.03)
        XCTAssertEqual(r[0].upperBound, 2.3, accuracy: 0.03)
        XCTAssertEqual(r[1].lowerBound, 7.0, accuracy: 0.03)
        XCTAssertEqual(r[1].upperBound, 7.6, accuracy: 0.03)
        XCTAssertEqual(VoiceActivity.soundRanges([Float](repeating: 0, count: rate * 3)), [])
    }

    // MARK: - Scrap folding and the voice print (2026-10-18)

    /// One track, voice print enrolled. P talks 400 s, the user U asks one
    /// question (7 s), X is a 4 s scrap right after U.
    private var talkWithOneQuestion: [DiarizationRunner.SpeakerSegment] {
        (0..<40).map { region(Double($0) * 12, Double($0) * 12 + 10, "P") }
            + [region(500, 503.5, "U"), region(520, 523.5, "U"), region(524, 528, "X")]
    }

    func testScrapFoldNeverFoldsTheUserAway() {
        let scores: [String: Float] = ["P": 0.12, "U": 0.62]
        let folded = DiarizationRunner.foldScraps(talkWithOneQuestion, scores: scores)
        XCTAssertEqual(Set(folded.map(\.speakerId)), ["P", "U"])
        XCTAssertEqual(folded.last?.speakerId, "P", "another voice's scrap is not given to the user")
        XCTAssertEqual(DiarizationRunner.userCluster(folded, scores: scores), "U")
        // Without a print, the user's 7 s is a scrap like any other.
        XCTAssertEqual(Set(DiarizationRunner.foldScraps(talkWithOneQuestion).map(\.speakerId)), ["P"])
    }

    func testScrapThatSoundsLikeTheUserJoinsTheUser() {
        // X scores like the user too: U and X are one voice split in two,
        // which spoils ClusterVoice's margin; the user is still found.
        let scores: [String: Float] = ["P": 0.12, "U": 0.62, "X": 0.55]
        XCTAssertNil(ClusterVoice.user(in: scores))
        XCTAssertEqual(DiarizationRunner.userCluster(talkWithOneQuestion, scores: scores), "U")
        let folded = DiarizationRunner.foldScraps(talkWithOneQuestion, scores: scores)
        XCTAssertEqual(folded.last?.speakerId, "U")
        XCTAssertEqual(DiarizationRunner.userCluster(folded, scores: scores), "U")
        // A big user cluster with a high-scoring scrap of the same voice.
        let big = talkWithOneQuestion.map { $0.speakerId == "U" ? region($0.startSeconds, $0.startSeconds + 40, "U") : $0 }
        XCTAssertEqual(DiarizationRunner.userCluster(big, scores: scores), "U")
    }

    func testOneTrackFinalizeNamesTheUserWhoSaidOneThing() {
        let diar = talkWithOneQuestion
        let input = diar.map { RawSegment(startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                                          text: $0.speakerId == "U" ? "Could you say more about pricing" : "and so the plan is simple") }
        let out = makeRunner().finalizeSegments(input, diarize: true, splitTracks: false, expectedSpeakers: 0,
                                                diarSegments: diar, myName: "Yuri",
                                                clusterVoice: ["P": 0.12, "U": 0.62])
        XCTAssertTrue(out.contains { $0.speakerKey == "ME" && $0.text.contains("pricing") },
                      "\(out.map { ($0.speakerKey, $0.text) })")
        XCTAssertFalse(out.contains { $0.speakerKey == "ME" && $0.text.contains("plan") })
    }
}
