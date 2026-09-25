import XCTest
@testable import Transcriberr

/// The `.json` sidecar has to stay the document Android's
/// `TranscriptExporter.toJson` writes, or files stop round-tripping.
@MainActor
final class TranscriptExporterTests: XCTestCase {
    func testJsonMatchesAndroidSchema() throws {
        let rec = Recording(title: "Standup", audioPath: "/tmp/a/standup.wav", durationSeconds: 12.5,
                            sourceLanguage: "en", transcribedWithBackend: "parakeet")
        let segs = [
            Segment(startSeconds: 0, endSeconds: 2, text: "Hello", speaker: "SPEAKER_00", speakerName: "Yuri"),
            Segment(startSeconds: 2, endSeconds: 4, text: "Hi"),
        ]
        let data = try TranscriptExporter.jsonData(recording: rec, segments: segs)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["audioPath", "title", "language", "translated",
                                       "durationSeconds", "backend", "model", "segments"])
        XCTAssertTrue(obj["model"] is NSNull, "absent values are explicit nulls, as kotlinx writes them")
        XCTAssertEqual(obj["audioPath"] as? String, "/tmp/a/standup.wav")

        let second = try XCTUnwrap((obj["segments"] as? [[String: Any]])?.last)
        XCTAssertEqual(Set(second.keys), ["start", "end", "speaker", "speakerName", "language", "text"])
        XCTAssertTrue(second["speaker"] is NSNull)

        let back = try JSONDecoder().decode(TranscriptExporter.TranscriptJson.self, from: data)
        XCTAssertEqual(back.segments.first?.speakerName, "Yuri")
        XCTAssertEqual(back.durationSeconds, 12.5)
    }

    func testSrtTimeRoundsInsteadOfTruncating() {
        XCTAssertEqual(TranscriptExporter.srtTime(2.3), "00:00:02,300")
        XCTAssertEqual(TranscriptExporter.srtTime(59.9996), "00:01:00,000")
        XCTAssertEqual(TranscriptExporter.srtTime(3_661.5), "01:01:01,500")
        XCTAssertEqual(TranscriptExporter.srtTime(.nan), "00:00:00,000")
    }

    func testSrtSkipsEmptySegmentsAndKeepsNumberingSequential() {
        let segs = [
            Segment(startSeconds: 0, endSeconds: 1, text: "One"),
            Segment(startSeconds: 1, endSeconds: 2, text: "  \n "),
            Segment(startSeconds: 2, endSeconds: 3, text: ""),
            Segment(startSeconds: 3, endSeconds: 4, text: "Two"),
        ]
        XCTAssertEqual(TranscriptExporter.srtText(segments: segs),
                       "1\n00:00:00,000 --> 00:00:01,000\nOne\n\n"
                       + "2\n00:00:03,000 --> 00:00:04,000\nTwo\n\n")
    }
}
