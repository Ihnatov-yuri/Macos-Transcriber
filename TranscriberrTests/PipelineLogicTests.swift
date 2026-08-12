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
}
