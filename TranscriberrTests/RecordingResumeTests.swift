import XCTest
@testable import Transcriberr

final class RecordingResumeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func cut(minutesAgo: Double, seconds: Double, meeting: Bool = true) -> InterruptedRecording {
        InterruptedRecording(id: UUID(), isMeeting: meeting,
                             startedAt: now.addingTimeInterval(-minutesAgo * 60), seconds: seconds)
    }

    func testOffersTheOneThatStoppedLast() {
        let early = cut(minutesAgo: 120, seconds: 600)    // stopped 110 min ago
        let late = cut(minutesAgo: 30, seconds: 1200)     // stopped 10 min ago
        XCTAssertEqual(RecordingResume.offer(from: [early, late], now: now), late)
    }

    func testNothingOfferedOutsideTheWindow() {
        let old = cut(minutesAgo: 60 * 8, seconds: 600)   // stopped 7 h 50 min ago
        XCTAssertNil(RecordingResume.offer(from: [old], now: now))
        XCTAssertNil(RecordingResume.offer(from: [], now: now))
    }

    func testTheLengthDatesTheStop() {
        // Started 7 hours ago but ran 2 hours: it stopped 5 hours ago.
        let long = cut(minutesAgo: 420, seconds: 7200)
        XCTAssertEqual(RecordingResume.offer(from: [long], now: now), long)
    }

    func testLengthText() {
        XCTAssertEqual(RecordingResume.lengthText(40), "40 seconds")
        XCTAssertEqual(RecordingResume.lengthText(61), "1 minute")
        XCTAssertEqual(RecordingResume.lengthText(23 * 60 + 10), "23 minutes")
        XCTAssertEqual(RecordingResume.lengthText(3600), "1 hour")
        XCTAssertEqual(RecordingResume.lengthText(3900), "1 hour 5 minutes")
    }

    func testJoinedTitleNamesTheKind() {
        XCTAssertTrue(RecordingResume.joinedTitle(cut(minutesAgo: 10, seconds: 60)).hasPrefix("Meeting "))
        XCTAssertTrue(RecordingResume.joinedTitle(cut(minutesAgo: 10, seconds: 60, meeting: false)).hasPrefix("Recording "))
    }
}
