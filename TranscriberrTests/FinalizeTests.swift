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
}
