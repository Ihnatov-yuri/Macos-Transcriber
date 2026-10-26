import XCTest
@testable import Transcriberr

/// Nemotron 3 post-processing and the rules that send a recording to the
/// offline diarizer instead (2026-10-25).
final class DiarizationEngineTests: XCTestCase {
    private func region(_ a: Double, _ b: Double, _ k: String) -> DiarizationRunner.SpeakerSegment {
        DiarizationRunner.SpeakerSegment(startSeconds: a, endSeconds: b, speakerId: k)
    }

    /// `n` voices that each speak 40 s, in 10 s turns.
    private func voices(_ n: Int) -> [DiarizationRunner.SpeakerSegment] {
        (0..<(n * 4)).map { i in
            let t = Double(i) * 10
            return region(t, t + 9, String(format: "SPEAKER_%02d", i % n + 1))
        }
    }

    func testBridgeGapsJoinsOneSpeakersPausesOnly() {
        let words = [region(0, 0.4, "A"), region(0.9, 1.5, "A"), region(1.6, 2.0, "B"), region(3.5, 4.0, "A")]
        let out = DiarizationRunner.bridgeGaps(words, maxGap: 1.0)
        let a = out.filter { $0.speakerId == "A" }.map { [$0.startSeconds, $0.endSeconds] }
        XCTAssertEqual(a, [[0, 1.5], [3.5, 4.0]], "a 0.5 s pause joins, a 2 s pause does not")
        XCTAssertEqual(out.filter { $0.speakerId == "B" }.count, 1, "another speaker between is no reason to split or join")
        XCTAssertEqual(out.map(\.startSeconds), out.map(\.startSeconds).sorted())
    }

    func testNemotronStandsWithinItsLimits() {
        XCTAssertNil(DiarizationRunner.nemotronFallback(voices(3), numClusters: 0, exact: false))
        XCTAssertNil(DiarizationRunner.nemotronFallback(voices(3), numClusters: 5, exact: false))
        XCTAssertNil(DiarizationRunner.nemotronFallback(voices(3), numClusters: 3, exact: true))
        XCTAssertNil(DiarizationRunner.nemotronFallback(voices(7), numClusters: 0, exact: false))
        // A scrap in a spare slot is not a voice over the bound.
        XCTAssertNil(DiarizationRunner.nemotronFallback(voices(2) + [region(500, 501.5, "SPEAKER_03")],
                                                        numClusters: 2, exact: false))
    }

    func testFullHouseAndBrokenBoundsGoToTheOfflineDiarizer() {
        XCTAssertNotNil(DiarizationRunner.nemotronFallback(voices(8), numClusters: 0, exact: false),
                        "8 slots used: voices past the 8th were squeezed in")
        XCTAssertNotNil(DiarizationRunner.nemotronFallback(voices(7) + [region(900, 902, "SPEAKER_08")],
                                                           numClusters: 0, exact: false),
                        "a full house counts scraps too")
        XCTAssertNotNil(DiarizationRunner.nemotronFallback(voices(4), numClusters: 3, exact: false))
        XCTAssertNotNil(DiarizationRunner.nemotronFallback(voices(2), numClusters: 3, exact: true))
    }

    func testEngineDefaultsToNemotron() {
        let saved = UserDefaults.standard.string(forKey: DiarizationRunner.engineKey)
        defer { UserDefaults.standard.set(saved, forKey: DiarizationRunner.engineKey) }
        UserDefaults.standard.removeObject(forKey: DiarizationRunner.engineKey)
        XCTAssertEqual(DiarizationRunner.engine, .nemotron)
        UserDefaults.standard.set("fluid", forKey: DiarizationRunner.engineKey)
        XCTAssertEqual(DiarizationRunner.engine, .fluid)
    }

    func testSameVoiceUnderTwoLabelsBecomesOne() {
        let a: [Float] = [1, 0, 0], a2: [Float] = [0.95, 0.3, 0], b: [Float] = [0, 1, 0], c: [Float] = [0, 0, 1]
        let clips = ["S1": [a2, a2, a2], "S2": [a, a, a, a], "S3": [b, b, b], "S4": [c, c, c], "S5": []]
        let seconds = ["S1": 10.0, "S2": 250, "S3": 80, "S4": 60, "S5": 5]
        let into = DiarizationRunner.sameVoiceMerges(clips, seconds: seconds, threshold: 0.62).into
        XCTAssertEqual(into, ["S1": "S2"], "the short label folds into the long one; different voices and clipless ones stay")
        XCTAssertEqual(DiarizationRunner.sameVoiceMerges(["S3": [b], "S4": [c]], seconds: seconds, threshold: 0.62).into, [:])
    }
}
