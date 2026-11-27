import XCTest
@testable import Transcriberr

/// A headset that drops mid-meeting must not end the recording (v5.9.2:
/// until then it did, and the rest of a Teams call was never captured).
/// These pin where the recording moves to; `transcriberrcli meetingmove`
/// runs the real capture rebuild.
final class MeetingMicMoveTests: XCTestCase {

    func testAHeadsetThatDropsMovesTheRecordingToTheSystemDefault() {
        // AirPods gone; macOS already made the built-in mic the default.
        XCTAssertEqual(MeetingRecorder.pickMic(startedOn: "airpods", avoiding: ["airpods"], chosen: nil,
                                               systemDefault: "builtin", available: ["builtin"]),
                       "builtin")
    }

    func testTheMicPickedInSettingsComesBeforeTheDefault() {
        XCTAssertEqual(MeetingRecorder.pickMic(startedOn: "airpods", avoiding: ["airpods"], chosen: "usb",
                                               systemDefault: "builtin", available: ["builtin", "usb"]),
                       "usb")
    }

    func testTheLostMicIsNeverPickedEvenWhileTheDefaultStillNamesIt() {
        // Right after the removal the default can lag behind.
        XCTAssertNil(MeetingRecorder.pickMic(startedOn: "airpods", avoiding: ["airpods"], chosen: nil,
                                             systemDefault: "airpods", available: ["airpods"]))
        XCTAssertNil(MeetingRecorder.pickMic(startedOn: "airpods", avoiding: ["airpods"], chosen: "",
                                             systemDefault: nil, available: []),
                     "no microphone left: the call audio records alone")
    }

    func testTheMicTheMeetingStartedOnWinsOnceItIsBack() {
        XCTAssertEqual(MeetingRecorder.pickMic(startedOn: "airpods", avoiding: [], chosen: nil,
                                               systemDefault: "builtin", available: ["builtin", "airpods"]),
                       "airpods")
    }

    func testMovingBackOnlyForTheReturningMicOrWhenThereIsNone() {
        // On the fallback, the original headset returns: back to it.
        XCTAssertTrue(MeetingRecorder.shouldMoveBack(current: "builtin", pick: "airpods", startedOn: "airpods"))
        // Recording the call alone: any microphone is taken.
        XCTAssertTrue(MeetingRecorder.shouldMoveBack(current: nil, pick: "builtin", startedOn: "airpods"))
        // A mic plugged in mid-meeting does not take over a working one.
        XCTAssertFalse(MeetingRecorder.shouldMoveBack(current: "builtin", pick: "usb", startedOn: "airpods"))
        // Already there, or nothing to move to.
        XCTAssertFalse(MeetingRecorder.shouldMoveBack(current: "airpods", pick: "airpods", startedOn: "airpods"))
        XCTAssertFalse(MeetingRecorder.shouldMoveBack(current: nil, pick: nil, startedOn: "airpods"))
    }

    func testAMicCoolingDownIsSkippedLikeALostOne() {
        // AirPods listed again but not ready: left alone, the built-in stays.
        XCTAssertEqual(MeetingRecorder.pickMic(startedOn: "airpods", avoiding: ["airpods"], chosen: nil,
                                               systemDefault: "builtin", available: ["builtin", "airpods"]),
                       "builtin")
    }

    func testAMoveFallsBackToTheMicItWasOnBeforeTheCallAudioAlone() {
        // Moving back to returning AirPods that refuse: built-in again, then call only.
        XCTAssertEqual(MeetingRecorder.moveAttempts(target: "airpods", previous: "builtin", previousUsable: true),
                       ["airpods", "airpods", "builtin", nil])
        // The mic was lost: no going back to it.
        XCTAssertEqual(MeetingRecorder.moveAttempts(target: "builtin", previous: "airpods", previousUsable: false),
                       ["builtin", "builtin", nil])
        // Rebuilding on the same mic (a stall).
        XCTAssertEqual(MeetingRecorder.moveAttempts(target: "builtin", previous: "builtin", previousUsable: true),
                       ["builtin", "builtin", nil])
        XCTAssertEqual(MeetingRecorder.moveAttempts(target: nil, previous: "airpods", previousUsable: false), [nil, nil])
    }

    func testTheWatchdogArmsOnlyOnceAudioHasFlowed() {
        // Never any audio (no System Audio Recording permission): never rebuilt.
        var s = MeetingRecorder.StallState()
        var last: Int64 = -1
        for _ in 0..<10 {
            XCTAssertFalse(MeetingRecorder.stallStep(frames: 0, last: last, paused: false, state: &s))
            last = 0
        }
    }

    func testACaptureThatGoesSilentIsRebuiltAfterTwoSecondsAtMostThreeTimes() {
        var s = MeetingRecorder.StallState()
        XCTAssertFalse(MeetingRecorder.stallStep(frames: 4800, last: -1, paused: false, state: &s))
        XCTAssertTrue(s.armed)
        // Stuck: one second is not yet a stall, two is.
        XCTAssertFalse(MeetingRecorder.stallStep(frames: 4800, last: 4800, paused: false, state: &s))
        XCTAssertTrue(MeetingRecorder.stallStep(frames: 4800, last: 4800, paused: false, state: &s))
        XCTAssertFalse(s.armed, "waits for the rebuilt graph to deliver before judging it")
        XCTAssertFalse(MeetingRecorder.stallStep(frames: 4800, last: 4800, paused: false, state: &s))
        // Paused on purpose: frames stand still and nothing is wrong.
        var p = MeetingRecorder.StallState(armed: true, still: 0, rebuilds: 0)
        for _ in 0..<5 { XCTAssertFalse(MeetingRecorder.stallStep(frames: 9, last: 9, paused: true, state: &p)) }
        // A graph that keeps dying: three rebuilds, then it is left alone.
        var d = MeetingRecorder.StallState()
        var frames: Int64 = 0
        var rebuilds = 0
        for _ in 0..<10 {
            _ = MeetingRecorder.stallStep(frames: frames + 100, last: frames, paused: false, state: &d)
            frames += 100
            for _ in 0..<2 where MeetingRecorder.stallStep(frames: frames, last: frames, paused: false, state: &d) { rebuilds += 1 }
        }
        XCTAssertEqual(rebuilds, MeetingRecorder.maxStallRebuilds)
    }

    func testTheOutputClockFollowsTheDefaultOutputWithoutLooping() {
        // Headphones out: the tap follows the speakers, so must the clock.
        XCTAssertTrue(MeetingRecorder.outputMoved(clock: 105, now: 120))
        XCTAssertFalse(MeetingRecorder.outputMoved(clock: 105, now: 105))
        // No output at all: nothing to follow.
        XCTAssertFalse(MeetingRecorder.outputMoved(clock: 105, now: nil))
        // The clock could not start: rebuilding would fail again, forever.
        XCTAssertFalse(MeetingRecorder.outputMoved(clock: 0, now: 105))
    }
}
