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
        // The English singulars ("1 minute") come from the catalog's plural
        // variants, so check the structure: the count and the unit.
        func check(_ seconds: Double, _ parts: [String], not absent: [String] = []) {
            let text = RecordingResume.lengthText(seconds)
            for p in parts { XCTAssertTrue(text.contains(p), "\(text) lacks \(p)") }
            for p in absent { XCTAssertFalse(text.contains(p), "\(text) has \(p)") }
        }
        check(40, ["40", "second"], not: ["minute"])
        check(61, ["1", "minute"], not: ["second", "hour"])
        check(23 * 60 + 10, ["23", "minute"], not: ["second", "hour"])
        check(3600, ["1", "hour"], not: ["minute"])
        check(3900, ["1", "hour", "5", "minute"])
        // In English the singulars must come out right (review of 5.8.0:
        // one string with two counts said "1 hours 5 minutes").
        if Bundle.main.preferredLocalizations.first == "en" {
            XCTAssertEqual(RecordingResume.lengthText(61), "1 minute")
            XCTAssertEqual(RecordingResume.lengthText(3900), "1 hour 5 minutes")
            XCTAssertEqual(RecordingResume.lengthText(2 * 3600 + 60), "2 hours 1 minute")
        }
    }

    func testJoinedTitleNamesTheKind() {
        XCTAssertTrue(RecordingResume.joinedTitle(cut(minutesAgo: 10, seconds: 60)).hasPrefix("Meeting "))
        XCTAssertTrue(RecordingResume.joinedTitle(cut(minutesAgo: 10, seconds: 60, meeting: false)).hasPrefix("Recording "))
    }
}
