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

    /// A mic chunk the mic's own reading has nothing for: its loops go even
    /// though there is nothing to time it by (2026-10-14: "Silence. Silence.
    /// Silence. Silence?" over speaker echo, 26 s each).
    func testUnalignedMicLoopIsDropped() {
        let out = TurnTiming.retime(
            [seg(860, 886, "Silence. Silence. Silence. Silence?", "ME"),
             seg(890, 916, "Hello. Hello. Hello. Hello.", "ME")],
            timelines: [0: line("x", from: 0), 1: line("unrelated words", from: 100)], diarization: [])
        XCTAssertTrue(out.isEmpty, "got \(out.map(\.text))")
    }

    /// A stray "Silence." between real words goes when the mic did not hear it.
    func testStraySilenceWordIsDropped() {
        let mic = line("yeah right", from: 650)
        let out = TurnTiming.retime([seg(640, 666, "yeah. Right. Silence.", "ME")],
                                    timelines: [0: line("x", from: 0), 1: mic], diarization: [])
        XCTAssertEqual(out.map(\.text), ["yeah. Right."])
    }

    /// The far side keeps an unaligned chunk exactly as it was.
    func testFarSideUnalignedLoopIsLeftAlone() {
        let out = TurnTiming.retime([seg(0, 26, "Go go go go!", "GUEST")],
                                    timelines: [0: line("x", from: 100), 1: []], diarization: [])
        XCTAssertEqual(out.map(\.text), ["Go go go go!"])
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

    /// "We are" between pauses on the mic, timed on the far side's "we're"
    /// (Landal interview, 86.6 s): echo, though the words differ.
    func testShortEchoPieceWithContractionIsDropped() {
        let far = line("landau we're looking for", from: 85.4)
        let mic = line("a blessing", from: 77) + line("we are", from: 86.0)
        let out = TurnTiming.retime([seg(75, 103, "A blessing. We are", "ME")],
                                    timelines: [0: far, 1: mic], diarization: [])
        XCTAssertEqual(out.map(\.text), ["A blessing."])
    }

    /// One word the far side says in the same second is not echo on its own.
    func testSingleSharedEdgeWordStays() {
        let far = line("it's easy to commute", from: 76.5)
        let mic = line("it's a blessing and a curse", from: 76.6)
        let out = TurnTiming.retime([seg(75, 103, "It's a blessing and a curse.", "ME")],
                                    timelines: [0: far, 1: mic], diarization: [])
        XCTAssertEqual(out.map(\.text), ["It's a blessing and a curse."])
    }

    /// The far side's last words before the reply come off the reply.
    func testEchoedLeadInIsTrimmed() {
        let far = line("what is your experience there", from: 320)
        let mic = line("your experience there", from: 320.9) + line("well I have a degree", from: 322.3)
        let out = TurnTiming.retime([seg(310, 336, "Your experience there? Well, I have a degree.", "ME")],
                                    timelines: [0: far, 1: mic], diarization: [])
        XCTAssertEqual(out.map(\.text), ["Well, I have a degree."])
    }

    /// Parakeet writes "have17"; the merged text has "have 17".
    func testGluedNumberAligns() {
        let mic = line("I have17 years", from: 115)
        let out = TurnTiming.retime([seg(102, 128, "I have 17 years.", "ME")],
                                    timelines: [0: line("x", from: 0), 1: mic], diarization: [])
        XCTAssertEqual(out.first?.startSeconds ?? 0, 115, accuracy: 0.01)
    }

    /// An unaligned mic line that is the far side's words is dropped.
    func testUnalignedMicEchoIsDropped() {
        let far = line("so tell me about your background", from: 104)
        let out = TurnTiming.retime([seg(102, 128, "tell me about your background", "ME")],
                                    timelines: [0: far, 1: line("nothing alike", from: 110)], diarization: [])
        XCTAssertTrue(out.isEmpty)
    }

    /// On speakers, the recorder's mic-dominance timeline decides: a long
    /// mic piece covered only by a 0.3 s blip is invented, a covered one is
    /// the user, and a short reply near an interval survives.
    func testMicSpeechTimelineFiltersUnspokenPieces() {
        let micSpeech: [ClosedRange<Double>] = [300.8...302.9, 304.3...311.5, 1144.8...1145.1, 1500.2...1500.5]
        XCTAssertTrue(TurnTiming.isSpoken(300.6, 314.1, micSpeech: micSpeech))
        XCTAssertFalse(TurnTiming.isSpoken(1140.4, 1164.6, micSpeech: micSpeech))
        XCTAssertTrue(TurnTiming.isSpoken(1500.9, 1501.3, micSpeech: micSpeech), "short reply just after an interval")
        XCTAssertFalse(TurnTiming.isSpoken(1700, 1701, micSpeech: micSpeech))

        let mic = line("sure I'm Yuri technical project manager", from: 301)
        let out = TurnTiming.retime(
            [seg(296, 322, "Sure, I'm Yuri, technical project manager.", "ME"),
             seg(2390, 2417, "Hello, I'm Joe. Hello, I'm Joe.", "ME")],
            // As on the real call, the mic's own reading has none of the
            // invented line, so it keeps its 27 s chunk span.
            timelines: [0: line("x", from: 0),
                        1: mic + line("mm", from: 2391).map { var w = $0; w.word.confidence = 0.4; return w }],
            diarization: [],
            micSpeech: micSpeech + [2391.2...2391.6])
        XCTAssertEqual(out.map(\.text), ["Sure, I'm Yuri, technical project manager."])
    }

    /// A line the speech timeline misses but the mic's own reading heard
    /// confidently is the user (coaching call, 0.91 median confidence).
    func testConfidentMicSpeechSurvivesTheTimeline() {
        func confident(_ text: String, from start: Double, _ c: Float) -> [TimedWord] {
            line(text, from: start).map { var w = $0; w.word.confidence = c; return w }
        }
        let micSpeech: [ClosedRange<Double>] = [100...100.3]
        let real = TurnTiming.retime([seg(0, 26, "Привет, как твои вікна?", "ME")],
                                     timelines: [0: line("x", from: 200), 1: confident("привет как твои вікна", from: 9, 0.9)],
                                     diarization: [], micSpeech: micSpeech)
        XCTAssertEqual(real.map(\.text), ["Привет, как твои вікна?"])
        let residue = TurnTiming.retime([seg(0, 26, "Semi tummy kidney choke chain.", "ME")],
                                        timelines: [0: line("x", from: 200), 1: confident("semi tummy kidney choke chain", from: 9, 0.45)],
                                        diarization: [], micSpeech: micSpeech)
        XCTAssertTrue(residue.isEmpty)
    }

    /// Without a timeline (headphones: no echo found) nothing is filtered.
    func testNoMicSpeechTimelineKeepsEverything() {
        let mic = line("one two three four five six", from: 10, step: 1)
        let out = TurnTiming.retime([seg(0, 26, "One two three four five six.", "ME")],
                                    timelines: [0: line("x", from: 100), 1: mic], diarization: [], micSpeech: nil)
        XCTAssertEqual(out.count, 1)
    }

    /// Words only Whisper wrote must not bridge the pause where the other
    /// side asked something (Landal, 0:49 on the 3.17.1 re-run).
    func testUnanchoredWordsDoNotBridgeAPause() {
        let far = line("how far is it from Amsterdam", from: 53.6)
        let mic = line("I work from home in Marsen", from: 49.4, step: 0.6) + line("it's about twenty minutes", from: 57.5)
        let out = TurnTiming.retime(
            [seg(49, 75, "I work from home in Marsen. Okay. Nice place. It's about twenty minutes.", "ME"),
             seg(49, 75, "How far is it from Amsterdam?", "GUEST")],
            timelines: [0: far, 1: mic], diarization: [])
        XCTAssertEqual(out.map(\.speakerKey), ["ME", "GUEST", "ME"])
        XCTAssertEqual(out.last?.text, "It's about twenty minutes.")
    }

    /// One long echoed word alone between pauses goes ("architecture,"
    /// repeated under the interviewer's question); a short one stays.
    func testLoneLongEchoWordIsDropped() {
        let far = line("coding and architecture", from: 321) + line("it's easy", from: 330)
        let mic = line("architecture", from: 322.3) + line("it's", from: 330.1) + line("well I have a degree", from: 335)
        let out = TurnTiming.retime(
            [seg(310, 336, "architecture, it's Well, I have a degree.", "ME")],
            timelines: [0: far, 1: mic], diarization: [])
        XCTAssertEqual(out.map(\.text), ["it's", "Well, I have a degree."])
    }

    /// Repeating the other person's word a beat later is speech, not echo
    /// (uk-b reference slice: "логику" then "логіку" 0.7 s later).
    func testRepeatedWordABeatLaterStays() {
        let far = line("шукает логику", from: 259.2, step: 0.8)
        let mic = line("шукають", from: 259.5) + line("логіку", from: 260.72)
        let out = TurnTiming.retime([seg(252, 276, "шукають логіку", "ME")],
                                    timelines: [0: far, 1: mic], diarization: [])
        XCTAssertEqual(out.map(\.text).joined(separator: " "), "шукають логіку")
    }

    /// On a speaker call, a mic line mostly missing from the mic's own
    /// reading is dropped even inside a speech interval.
    func testMostlyUnheardMicPieceIsDroppedUnderEcho() {
        // Echo residue: the mic's reading is unsure of it.
        let mic = line("it's a", from: 1388.6).map { var w = $0; w.word.confidence = 0.5; return w }
        let out = TurnTiming.retime([seg(1386, 1412, "I to it's a. of mirrors", "ME")],
                                    timelines: [0: line("x", from: 0), 1: mic], diarization: [],
                                    micSpeech: [1388.6...1389.0])
        XCTAssertTrue(out.isEmpty, "got \(out.map(\.text))")
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
