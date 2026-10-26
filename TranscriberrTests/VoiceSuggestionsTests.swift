import XCTest
@testable import Transcriberr

/// "People you meet often" (5.0.0): which unnamed voices and typed names
/// are suggested, and which never are.
final class VoiceSuggestionsTests: XCTestCase {
    private func unit(_ v: [Float]) -> [Float] {
        let n = sqrt(v.map { $0 * $0 }.reduce(0, +)); return v.map { $0 / n }
    }
    private let now = Date(timeIntervalSince1970: 200 * 86_400)
    private func entry(_ v: [Float], day: Double, withMe: Bool = true, rec: UUID = UUID(), key: String = "S1") -> UnknownVoiceStore.Entry {
        .init(recordingId: rec, speaker: key, centroid: unit(v), seconds: 120,
              date: Date(timeIntervalSince1970: day * 86_400), withMe: withMe)
    }

    func testARecurringVoiceInMyMeetingsIsSuggested() {
        let kate: [Float] = [1, 0.1, 0, 0]
        var f = UnknownVoiceStore.File()
        f.entries = (0..<4).map { entry(kate, day: 190 - Double($0)) }
            + [entry([0, 1, 0, 0], day: 195), entry([0, 1, 0, 0], day: 194)]          // only twice
            + (0..<3).map { entry([0, 0, 1, 0], day: 190 - Double($0), withMe: false) } // not my meetings
            + (0..<3).map { entry([0, 0, 0, 1], day: 10 + Double($0)) }                // long ago
        let g = VoiceSuggestions.groups(f, people: [], me: nil, now: now)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g.first?.members.count, 4)
    }

    func testOneRecordingCountsOnceAndDismissedOrKnownVoicesAreNot() {
        let v: [Float] = [1, 0, 0, 0]
        let rec = UUID()
        var f = UnknownVoiceStore.File()
        f.entries = [entry(v, day: 190, rec: rec, key: "S1"), entry(v, day: 190, rec: rec, key: "S2"),
                     entry(v, day: 189)]
        XCTAssertTrue(VoiceSuggestions.groups(f, people: [], me: nil, now: now).isEmpty,
                      "two speakers of one recording are not two meetings")
        f.entries += [entry(v, day: 188), entry(v, day: 187)]
        XCTAssertEqual(VoiceSuggestions.groups(f, people: [], me: nil, now: now).first?.members.count, 4)
        XCTAssertTrue(VoiceSuggestions.groups(f, people: [("Kate", unit(v))], me: nil, now: now).isEmpty,
                      "sounds like someone saved: their page asks, not this list")
        XCTAssertTrue(VoiceSuggestions.groups(f, people: [], me: unit(v), now: now).isEmpty, "the user's own voice")
        f.dismissed = f.entries.map(\.key)
        XCTAssertTrue(VoiceSuggestions.groups(f, people: [], me: nil, now: now).isEmpty)
    }

    func testTypedNamesWithoutAVoice() {
        let a = UUID(), b = UUID()
        let lines: [(name: String, recording: UUID, seconds: Double)] = [
            ("Sarah", a, 40), ("sarah", b, 30), ("Kate", a, 50), ("Kate", b, 50),
            ("Speaker 2", a, 90), ("Speaker 2", b, 90), ("SPEAKER_01", a, 90), ("SPEAKER_01", b, 90),
            ("Yuri", a, 90), ("Yuri", b, 90), ("Once", a, 300),
        ]
        let n = VoiceSuggestions.named(lines, saved: ["kate"], me: "Yuri")
        XCTAssertEqual(n.map(\.name), ["Sarah"])
        XCTAssertEqual(n.first?.recordings, 2)
    }

    func testStoreReplacesPerRecordingAndDeletes() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unknown-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = UnknownVoiceStore(url: url)
        let rec = UUID()
        store.record([entry([1, 0], day: 1, rec: rec), entry([0, 1], day: 1, rec: rec, key: "S2")], for: rec)
        store.record([entry([1, 0], day: 1, rec: rec)], for: rec)
        XCTAssertEqual(store.load().entries.count, 1)
        store.remove(keys: [Person.Hearing.key(rec, "S1")])
        XCTAssertTrue(store.load().entries.isEmpty)
    }
}
