import XCTest
@testable import Transcriberr

/// The one-time reset of a saved meeting echo filter (5.1.4).
final class EchoFilterResetTests: XCTestCase {
    private let filter = "recorder.meetingEchoFilter"
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "EchoFilterResetTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testASavedOnIsTurnedOff() {
        defaults.set(true, forKey: filter)
        RecorderSettings.resetEchoFilterOnce(defaults)
        XCTAssertEqual(defaults.object(forKey: filter) as? Bool, false)
    }

    func testTurningItBackOnSticks() {
        defaults.set(true, forKey: filter)
        RecorderSettings.resetEchoFilterOnce(defaults)
        defaults.set(true, forKey: filter)   // the user's own choice afterwards
        RecorderSettings.resetEchoFilterOnce(defaults)
        XCTAssertEqual(defaults.object(forKey: filter) as? Bool, true)
    }

    func testNothingSavedStaysTheDefault() {
        RecorderSettings.resetEchoFilterOnce(defaults)
        XCTAssertNil(defaults.object(forKey: filter), "the default (off) applies")
    }

    func testASavedOffStaysOff() {
        defaults.set(false, forKey: filter)
        RecorderSettings.resetEchoFilterOnce(defaults)
        XCTAssertEqual(defaults.object(forKey: filter) as? Bool, false)
    }
}
