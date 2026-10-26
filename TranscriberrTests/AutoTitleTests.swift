import XCTest
@testable import Transcriberr

final class AutoTitleTests: XCTestCase {

    func testShortTranscriptIsReadWhole() {
        let s = AutoTitle.sample([(5, "the kiosk rollout"), (0, "Hello everyone, today we look at"), (9, "for CBQ branches")])
        XCTAssertEqual(s, "Hello everyone, today we look at the kiosk rollout for CBQ branches")
    }

    func testTooLittleTextGivesNothing() {
        XCTAssertNil(AutoTitle.sample([(0, "Hi."), (2, "Hello?")]))
    }

    func testLongTranscriptIsSampledAcrossTheTimeline() {
        // An hour of lines: greetings at the start, the subject later on.
        var segs: [(start: Double, text: String)] = [(0, "Happy Friday everyone, how was the weekend?")]
        for i in 1..<600 {
            let topic = i < 300 ? "budget planning for the node migration" : "the Bank Audi demo deck review"
            segs.append((Double(i) * 6, "Line \(i) about \(topic) and what comes next."))
        }
        let s = AutoTitle.sample(segs)!
        XCTAssertLessThanOrEqual(MeetingBriefBuilder.estimatedTokens(s), AutoTitle.tokenBudget + 20)
        XCTAssertFalse(s.contains("Happy Friday"), "the opening small talk is skipped")
        XCTAssertTrue(s.contains("node migration"))
        XCTAssertTrue(s.contains("Bank Audi"), "the second half of the recording is read too")
        XCTAssertTrue(s.contains("Line 5"), "slices are consecutive lines")
    }

    func testCleanStripsModelNoise() {
        XCTAssertEqual(AutoTitle.clean("**Title:** \"Kiosk Rollout For CBQ.\"\n\nHope this helps"), "Kiosk Rollout For CBQ")
        XCTAssertEqual(AutoTitle.clean("  Node Migration Plan  "), "Node Migration Plan")
        XCTAssertNil(AutoTitle.clean("\n  \n"))
        XCTAssertNil(AutoTitle.clean("Ok"))
        XCTAssertNil(AutoTitle.clean(String(repeating: "Word ", count: 30)))
    }
}

final class AutoTitleDefaultTitleTests: XCTestCase {
    /// The launch catch-up and the end-of-run hook name the same titles.
    func testDefaultTitlesAreRenamedOthersKept() {
        XCTAssertTrue(TranscriptionJobManager.shouldAutoTitle("Meeting 26/10/2026, 13:08"))
        XCTAssertTrue(TranscriptionJobManager.shouldAutoTitle("Recording 2026-10-26 12:24"))
        XCTAssertFalse(TranscriptionJobManager.shouldAutoTitle("Node Migration And Bot Updates: follow-up"))
        XCTAssertFalse(TranscriptionJobManager.shouldAutoTitle("Call with Kees"))
    }
}
