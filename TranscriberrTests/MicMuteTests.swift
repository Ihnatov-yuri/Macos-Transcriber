import XCTest
@testable import Transcriberr

final class MicMuteTests: XCTestCase {
    func testLabelsSayTheState() {
        XCTAssertEqual(MeetingMuteMonitor.parseLabel("Unmute mic (⇧⌘M)"), true)
        XCTAssertEqual(MeetingMuteMonitor.parseLabel("Unmute"), true)
        XCTAssertEqual(MeetingMuteMonitor.parseLabel("Mute microphone"), false)
        XCTAssertEqual(MeetingMuteMonitor.parseLabel("Mute audio"), false)
        XCTAssertEqual(MeetingMuteMonitor.parseLabel("Unmute audio"), true)
    }

    func testOtherPeoplesMuteButtonsAreNotOurs() {
        XCTAssertNil(MeetingMuteMonitor.parseLabel("Mute all"))
        XCTAssertNil(MeetingMuteMonitor.parseLabel("Mute Anna Smith"))
        XCTAssertNil(MeetingMuteMonitor.parseLabel("Unmute participants"))
        XCTAssertNil(MeetingMuteMonitor.parseLabel("Microphone settings"))
    }

    func testGoogleMeetSaysItTheOtherWayRound() {
        XCTAssertEqual(MeetingMuteMonitor.parseLabel("Turn on microphone (⌘ + D)"), true)
        XCTAssertEqual(MeetingMuteMonitor.parseLabel("Turn off microphone (⌘ + D)"), false)
        XCTAssertEqual(MeetingMuteMonitor.parseLabel("Turn off microphone"), false)
        XCTAssertNil(MeetingMuteMonitor.parseLabel("Turn off microphone for everyone"))
        XCTAssertNil(MeetingMuteMonitor.parseLabel("Turn on camera (⌘ + E)"))
    }

    func testABrowserVideoPlayerIsNotTheMicrophone() {
        XCTAssertNil(MeetingMuteMonitor.parseLabel("Unmute (m)", meetOnly: true))
        XCTAssertNil(MeetingMuteMonitor.parseLabel("Mute", meetOnly: true))
        XCTAssertEqual(MeetingMuteMonitor.parseLabel("Turn on microphone (⌘ + D)", meetOnly: true), true)
        XCTAssertEqual(MeetingMuteMonitor.parseLabel("Turn off microphone", meetOnly: true), false)
    }

    func testTheSwitchOverrulesTheMeetingApp() {
        XCTAssertFalse(MicSwitch.auto.leavesOut(appMuted: false))
        XCTAssertTrue(MicSwitch.auto.leavesOut(appMuted: true))
        XCTAssertFalse(MicSwitch.on.leavesOut(appMuted: true))
        XCTAssertTrue(MicSwitch.off.leavesOut(appMuted: false))
    }

    func testTheSwitchSaysWhatHappensToTheMic() {
        XCTAssertNil(MicSwitch.auto.status(mutedIn: nil))
        XCTAssertNil(MicSwitch.on.status(mutedIn: nil))
        XCTAssertEqual(MicSwitch.auto.status(mutedIn: "Teams"), "Muted in Teams · mic left out")
        XCTAssertEqual(MicSwitch.on.status(mutedIn: "Teams"), "Muted in Teams · mic kept")
        XCTAssertEqual(MicSwitch.off.status(mutedIn: nil), "Mic left out")
        XCTAssertEqual(MicSwitch.off.status(mutedIn: "Zoom"), "Mic left out")
    }

    @MainActor
    func testTheRecorderKeepsTheSwitch() {
        let recorder = MeetingRecorder()
        XCTAssertEqual(recorder.micSwitch, .auto)
        recorder.setMicSwitch(.off)
        XCTAssertEqual(recorder.micSwitch, .off)
    }

    func testAMissAlwaysLeavesALine() {
        let silent = MeetingMuteMonitor.missLine(app: "Teams", windows: 2, searched: 2, elements: 6001,
                                                 seconds: 2.04, stopped: "out of time", near: [])
        XCTAssertEqual(silent, "Teams: no mute control; 2 of 2 windows, 6001 elements in 2.0 s (out of time); no button mentions mic or mute")
        let worded = MeetingMuteMonitor.missLine(app: "Teams", windows: 1, searched: 1, elements: 40,
                                                 seconds: 0.1, stopped: "whole tree read", near: ["Mic options"])
        XCTAssertTrue(worded.hasSuffix("nearest labels: Mic options"))
    }

    func testTheNextScanStartsAtAnotherWindow() {
        XCTAssertEqual(MeetingMuteMonitor.rotated([1, 2, 3], by: 1), [2, 3, 1])
        XCTAssertEqual(MeetingMuteMonitor.rotated([1, 2, 3], by: 3), [1, 2, 3])
        XCTAssertEqual(MeetingMuteMonitor.rotated([Int](), by: 2), [])
    }

    func testAScanCutShortStartsAtTheWindowItDidNotFinish() {
        // Chat list first, call window cut off: the call window goes first
        // next time, with the whole time to itself.
        XCTAssertEqual(MeetingMuteMonitor.nextStart(previous: 0, stoppedAt: 1, count: 2), 1)
        XCTAssertEqual(MeetingMuteMonitor.nextStart(previous: 1, stoppedAt: 2, count: 3), 0)
        // The first window used all the time: the next one gets a turn.
        XCTAssertEqual(MeetingMuteMonitor.nextStart(previous: 0, stoppedAt: 0, count: 2), 1)
        XCTAssertEqual(MeetingMuteMonitor.nextStart(previous: 0, stoppedAt: 0, count: 1), 0)
    }

    func testABrowserWithNoMeetWindowIsNotAMiss() {
        XCTAssertFalse(MeetingMuteMonitor.isMiss(browser: true, searched: 0))
        XCTAssertTrue(MeetingMuteMonitor.isMiss(browser: true, searched: 1))
        XCTAssertTrue(MeetingMuteMonitor.isMiss(browser: false, searched: 0))
    }

    func testNothingIsKeptFromAMicOffStretch() throws {
        // Muted in the app 0-20 s and by the switch 30-50 s, ten seconds
        // of the user's voice in each: only the first comes back.
        let log = MicMuteLog(mode: .follow, muted: [[0, 20], [30, 50]], off: [[30, 50]])
        let kept = MicMute.keptRanges(muted: MicMute.span(log, duration: 60), voice: [5...15, 35...45], sound: [])
        XCTAssertEqual(kept, [5...15, 35...45])
        XCTAssertEqual(MicMute.keptOutsideOff(kept, log: log), [5...15])
        // A mode chosen after the meeting overrules the switch.
        var mine = log; mine.mode = .myVoice
        XCTAssertEqual(MicMute.keptOutsideOff(kept, log: mine), kept)
        // The stretches survive the file, a join and a cut; older logs have none.
        let back = try JSONDecoder().decode(MicMuteLog.self, from: JSONEncoder().encode(log))
        XCTAssertEqual(back.off, [[30, 50]])
        XCTAssertNil(try JSONDecoder().decode(MicMuteLog.self, from: Data(#"{"mode":"follow","muted":[[0,5]]}"#.utf8)).off)
        XCTAssertEqual(MicMute.merged(log, log, offset: 100)?.off, [[30, 50], [130, 150]])
        let halves = MicMute.split(log, at: 40)
        XCTAssertEqual(halves.first.off, [[30, 40]])
        XCTAssertEqual(halves.second.off, [[0, 10]])
    }

    func testOnlyAWholeWordMatchesTheWindow() {
        XCTAssertTrue(MeetingMuteMonitor.windowMatches("Meet - abc-defg-hij - Google Chrome", wanted: "Meet"))
        XCTAssertTrue(MeetingMuteMonitor.windowMatches("Google Meet", wanted: "Meet"))
        XCTAssertFalse(MeetingMuteMonitor.windowMatches("Meeting notes - Google Docs", wanted: "Meet"))
    }

    func testAMicChangeKeepsTheEngineThatMadeTheTranscript() {
        XCTAssertEqual(DetailModel.engineForRerun(transcribedWith: "ensemble", panel: .parakeet), .ensemble)
        XCTAssertEqual(DetailModel.engineForRerun(transcribedWith: "parakeet-v3", panel: .ensemble), .parakeet)
        // Never transcribed, or by the retired Gemma audio engine: the panel decides.
        XCTAssertEqual(DetailModel.engineForRerun(transcribedWith: nil, panel: .whisper), .whisper)
        XCTAssertEqual(DetailModel.engineForRerun(transcribedWith: "gemma4-litert", panel: .parakeet), .parakeet)
    }

    func testRoomVoicesAndShortAsidesAreLeftOut() {
        // No voice at all, then a 1 s aside mid-mute.
        XCTAssertEqual(MicMute.keptRanges(muted: [10...60], voice: [], sound: [10...60]), [])
        XCTAssertEqual(MicMute.keptRanges(muted: [10...60], voice: [30...31], sound: [10...60]), [])
    }

    func testSustainedSpeechIsBackFilledToItsStart() {
        XCTAssertEqual(MicMute.keptRanges(muted: [10...60], voice: [30...36], sound: [29.4...37]), [29.4...36])
    }

    func testOnsetReachIsCappedInANoisyRoom() {
        // The room never goes quiet: "sound" must not drag the start back.
        XCTAssertEqual(MicMute.keptRanges(muted: [10...60], voice: [30...36], sound: [10...60]), [29...36])
    }

    func testBackFillStaysInsideTheMute() {
        XCTAssertEqual(MicMute.keptRanges(muted: [30...60], voice: [30...36], sound: [10...40]), [30...36])
    }

    func testSpeechJustBeforeUnmuteIsKeptAtAnyLength() {
        XCTAssertEqual(MicMute.keptRanges(muted: [10...60], voice: [59...60], sound: [58.8...60]), [58.8...60])
    }

    func testOnlyMyVoiceKeepsShortReplies() {
        XCTAssertEqual(MicMute.keptRanges(muted: [0...60], voice: [30...30.5], sound: [30...31], minSustained: 0), [30...30.5])
    }

    func testHolesAreTheSpanMinusWhatIsKept() {
        XCTAssertEqual(MicMute.holes(span: [10...20], kept: [12...14, 16...18]), [10...12, 14...16, 18...20])
        XCTAssertEqual(MicMute.holes(span: [10...20], kept: [5...25]), [])
        XCTAssertEqual(MicMute.holes(span: [10...20], kept: []), [10...20])
    }

    func testSilenceOnlyTouchesTheHoles() {
        var x = [Float](repeating: 1, count: 16_000 * 3)
        MicMute.silence(&x, holes: [1...2])
        XCTAssertEqual(x[15_999], 1)
        XCTAssertEqual(x[16_000], 0)
        XCTAssertEqual(x[31_999], 0)
        XCTAssertEqual(x[32_001], 1)
    }

    func testSpanFollowsTheMode() {
        var log = MicMuteLog(mode: .follow, muted: [[5, 9]])
        XCTAssertEqual(MicMute.span(log, duration: 100), [5...9])
        log.mode = .everything
        XCTAssertEqual(MicMute.span(log, duration: 100), [])
        log.mode = .nothing
        XCTAssertEqual(MicMute.span(log, duration: 100), [0...100])
        log.mode = .myVoice
        XCTAssertEqual(MicMute.span(log, duration: 100), [0...100])
    }

    func testAMeetingWithNoLogShowsAsEverything() {
        XCTAssertEqual(MicMuteLog().effectiveMode, .everything)
        XCTAssertEqual(MicMuteLog(mode: .follow, muted: [[1, 2]]).effectiveMode, .follow)
    }

    func testAnUnknownModeReadsAsFollow() throws {
        let log = try JSONDecoder().decode(MicMuteLog.self, from: Data(#"{"mode":"later","muted":[[1,2]]}"#.utf8))
        XCTAssertEqual(log.mode, .follow)
        XCTAssertEqual(log.muted, [[1, 2]])
    }

    func testMergeShiftsAndSplitCuts() {
        let merged = MicMute.merged(MicMuteLog(muted: [[1, 2]]), MicMuteLog(muted: [[3, 4]]), offset: 10)
        XCTAssertEqual(merged?.muted, [[1, 2], [13, 14]])
        XCTAssertNil(MicMute.merged(nil, MicMuteLog(), offset: 10))
        let parts = MicMute.split(MicMuteLog(mode: .myVoice, muted: [[1, 2], [4, 8], [9, 10]]), at: 6)
        XCTAssertEqual(parts.first.muted, [[1, 2], [4, 6]])
        XCTAssertEqual(parts.second.muted, [[0, 2], [3, 4]])
        XCTAssertEqual(parts.second.mode, .myVoice)
    }

    func testNothingModeAppliesAndEverythingLeavesTheTrack() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let main = dir.appendingPathComponent("m.wav")

        var mic = [Float](repeating: 0.5, count: 16_000)
        MicMute.save(MicMuteLog(mode: .everything, muted: [[0, 1]]), forMain: main)
        var suffix = try await MicMute.apply(to: &mic, main: main, print: nil)
        XCTAssertNil(suffix)
        XCTAssertEqual(mic[100], 0.5)

        MicMute.setMode(.nothing, forMain: main)
        suffix = try await MicMute.apply(to: &mic, main: main, print: nil)
        XCTAssertEqual(suffix, "#mic-nothing")
        XCTAssertEqual(mic[100], 0)
    }

    func testOnlyMyVoiceWithoutAPrintKeepsTheMic() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let main = dir.appendingPathComponent("m.wav")
        var mic = [Float](repeating: 0.5, count: 16_000)
        MicMute.setMode(.myVoice, forMain: main)
        let suffix = try await MicMute.apply(to: &mic, main: main, print: nil)
        XCTAssertNil(suffix)
        XCTAssertEqual(mic[100], 0.5)
    }
}
