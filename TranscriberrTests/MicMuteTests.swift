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
