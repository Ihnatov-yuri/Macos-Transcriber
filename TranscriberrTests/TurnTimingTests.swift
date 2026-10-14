import XCTest
@testable import Transcriberr

/// Turn timing: chunk-span segments of a split-track meeting become word-span
/// pieces cut at pauses and far-side voice changes.
final class TurnTimingTests: XCTestCase {
    /// Words spoken one after another from `start`, `step` seconds apart.
    private func line(_ text: String, from start: Double, step: Double = 0.4) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { i, w in
            TimedWord(word: ScoredWord(surface: String(w), norm: TurnTiming.norm(w), confidence: 1),
                      start: start + Double(i) * step, end: start + Double(i) * step + step * 0.8)
        }
    }

    private func seg(_ a: Double, _ b: Double, _ t: String, _ key: String?) -> RawSegment {
        RawSegment(startSeconds: a, endSeconds: b, text: t, speakerKey: key)
    }

    /// The 2026-10-14 interview: a question split by the answer's chunk.
    func testReplyLandsBetweenQuestionAndFollowUp() {
        let far = line("you are based where", from: 1) + line("okay how far is it from Amsterdam", from: 9)
        let mic = line("I work from home in Haarlem", from: 4)
        let out = TurnTiming.retime(
            [seg(0, 26, "You are based where? Okay, how far is it from Amsterdam?", "GUEST"),
             seg(0, 26, "I work from home in Haarlem.", "ME")],
            timelines: [0: far, 1: mic], diarization: [])
        XCTAssertEqual(out.map(\.speakerKey), ["GUEST", "ME", "GUEST"])
        XCTAssertEqual(out[0].text, "You are based where?")
        XCTAssertEqual(out[1].text, "I work from home in Haarlem.")
        XCTAssertTrue(out[2].text.hasPrefix("Okay,"))
        XCTAssertEqual(out[1].startSeconds, 4, accuracy: 0.01, "piece starts at its first word, not the chunk")
    }

    /// Two voices inside one far-side chunk are two turns.
    func testFarSideChunkSplitsWhereTheVoiceChanges() {
        let far = line("thanks and JC do you want to introduce yourself", from: 0)
            + line("hi everyone looking forward to the meeting", from: 4.2)
        let diar = [
            DiarizationRunner.SpeakerSegment(startSeconds: 0, endSeconds: 4.0, speakerId: "SPEAKER_01"),
            DiarizationRunner.SpeakerSegment(startSeconds: 4.0, endSeconds: 8, speakerId: "SPEAKER_04"),
        ]
        let out = TurnTiming.retime(
            [seg(0, 26, "Thanks. And JC, do you want to introduce yourself? Hi everyone, looking forward to the meeting.", nil)],
            timelines: [0: far, 1: []], diarization: diar)
        XCTAssertEqual(out.map(\.speakerKey), ["SPEAKER_01", "SPEAKER_04"])
        XCTAssertTrue(out[1].text.hasPrefix("Hi everyone"))
    }

    /// One stray word clustered to another voice is jitter, not a turn.
    func testSingleWordOfAnotherVoiceStaysInTheTurn() {
        let far = line("we deliver this across the region together", from: 0)
        let diar = [
            DiarizationRunner.SpeakerSegment(startSeconds: 0, endSeconds: 1.1, speakerId: "A"),
            DiarizationRunner.SpeakerSegment(startSeconds: 1.1, endSeconds: 1.5, speakerId: "B"),
            DiarizationRunner.SpeakerSegment(startSeconds: 1.5, endSeconds: 5, speakerId: "A"),
        ]
        let out = TurnTiming.retime([seg(0, 26, "We deliver this across the region together.", nil)],
                                    timelines: [0: far, 1: []], diarization: diar)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].speakerKey, "A")
    }

    /// Whisper's "So. So. So. So." over echo residue goes; a word the mic's
    /// own reading supports stays.
    func testUnanchoredLoopOnTheMicIsDropped() {
        let mic = line("and then the demo", from: 2)
        let out = TurnTiming.retime([seg(0, 26, "And then So. So. So. So. So. the demo.", "ME")],
                                    timelines: [0: line("unrelated words", from: 20), 1: mic], diarization: [])
        XCTAssertEqual(out.map(\.text).joined(separator: " "), "And then the demo.")
    }

    func testAnchoredRepeatsSurvive() {
        let mic = line("no no no that is wrong", from: 2)
        let out = TurnTiming.retime([seg(0, 26, "No, no, no, that is wrong.", "ME")],
                                    timelines: [0: line("x", from: 20), 1: mic], diarization: [])
        XCTAssertEqual(out.map(\.text).joined(separator: " "), "No, no, no, that is wrong.")
    }

    /// The far side heard again on the mic, at the same time, goes; the
    /// user's own words in the same line stay.
    func testEchoedRunOnTheMicIsDropped() {
        let far = line("we enable business to really operate", from: 10)
        let mic = line("have seventeen", from: 5) + line("we enable business to really operate", from: 10.03)
        let out = TurnTiming.retime(
            [seg(0, 26, "We enable business to really operate.", "GUEST"),
             seg(0, 26, "Have seventeen. We enable business to really operate.", "ME")],
            timelines: [0: far, 1: mic], diarization: [])
        let me = out.filter { $0.speakerKey == "ME" }.map(\.text).joined(separator: " ")
        XCTAssertEqual(me, "Have seventeen.")
    }

    func testWithoutTimelinesNothingChanges() {
        let input = [seg(0, 26, "Hello there.", "ME"), seg(0, 26, "Hi.", "GUEST")]
        let out = TurnTiming.retime(input, timelines: [:], diarization: [])
        XCTAssertEqual(out.map(\.text), input.map(\.text))
        XCTAssertEqual(out.map(\.startSeconds), [0, 0])
    }

    /// A segment none of whose words the track's reading has keeps its span.
    func testUnalignedSegmentIsKeptAsIs() {
        let out = TurnTiming.retime([seg(30, 56, "Completely different words.", "GUEST")],
                                    timelines: [0: line("nothing alike here", from: 31), 1: []], diarization: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].startSeconds, 30)
        XCTAssertEqual(out[0].endSeconds, 56)
    }

    func testNearSpellingsAlign() {
        XCTAssertTrue(TurnTiming.similar("organise", "organize"))
        XCTAssertTrue(TurnTiming.similar("fouad", "fuad"))
        XCTAssertFalse(TurnTiming.similar("the", "she"), "short words must match exactly")
    }

    /// Finalize uses the timelines: pieces interleave, then same-speaker
    /// neighbours coalesce into turns.
    @MainActor
    func testFinalizeInterleavesTurns() {
        UserDefaults.standard.set(30.0, forKey: "ui.turnCoalesceGapSeconds")
        let runner = TranscriptionRunner(
            factory: BackendFactory(gemma: GemmaSettingsStore(), prompts: PromptStore(), apiKeys: APIKeyStore()),
            prompts: PromptStore(), diarization: DiarizationRunner())
        let far = line("so tell me about your background please", from: 1) + line("and why travel", from: 14)
        let mic = line("I studied engineering and built products", from: 6)
        let out = runner.finalizeSegments(
            [seg(0, 26, "So tell me about your background, please. And why travel?", nil),
             seg(0, 26, "I studied engineering and built products.", "ME")],
            diarize: true, splitTracks: true, expectedSpeakers: 2,
            diarSegments: [DiarizationRunner.SpeakerSegment(startSeconds: 0, endSeconds: 26, speakerId: "SPEAKER_07")],
            myName: nil, timelines: [0: far, 1: mic])
        XCTAssertEqual(out.map(\.speakerKey), ["SPEAKER_01", "ME", "SPEAKER_01"])
        XCTAssertEqual(out.last?.text, "And why travel?")
    }
}
