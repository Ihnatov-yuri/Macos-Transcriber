import SwiftData
import SwiftUI
import XCTest
@testable import Transcriberr

/// The split sheet's picture of a cut before it is made: where the pauses
/// are, and which line each recording ends and begins with.
final class SplitPlanTests: XCTestCase {
    private func line(_ start: Double, _ end: Double, _ text: String = "words") -> SplitPlan.Line {
        SplitPlan.Line(start: start, end: end, text: text)
    }

    func testLongestPausesAreSuggestedInOrderAndShortOnesAreNot() {
        let lines = [line(2, 40), line(42, 120), line(200, 260), line(500, 560), line(575, 590)]
        let pauses = SplitPlan.pauses(in: lines, total: 600)
        // 120→200 (80 s) and 260→500 (240 s); 40→42 and 560→575 are breaths.
        XCTAssertEqual(pauses.map(\.at), [199.5, 499.5])
        XCTAssertEqual(pauses.map(\.length), [80, 240])
    }

    func testOnlyTheThreeLongestPausesAreKept() {
        let lines = [line(0, 10), line(50, 60), line(160, 170), line(300, 310), line(500, 510)]
        let pauses = SplitPlan.pauses(in: lines, total: 600)
        XCTAssertEqual(pauses.count, 3)
        XCTAssertEqual(pauses.map(\.length), [100, 130, 190])   // the 40 s one is dropped, order is by time
    }

    func testAPauseStartsWhereTheLastOverlappingSpeakerStopped() {
        // The second speaker is still talking at 100 when the first has long stopped.
        let lines = [line(0, 20), line(10, 100), line(140, 150)]
        XCTAssertEqual(SplitPlan.pauses(in: lines, total: 300), [SplitPlan.Pause(at: 139.5, length: 40)])
    }

    func testSidesFollowTheRepositorysMidpointRule() {
        let lines = [line(0, 10, "first meeting ends here"), line(20, 40, "a line the cut runs through"),
                     line(50, 60, "second meeting starts here")]
        let between = SplitPlan.sides(of: lines, cut: 45)
        XCTAssertEqual(between.before?.text, "a line the cut runs through")
        XCTAssertEqual(between.after?.text, "second meeting starts here")
        XCTAssertNil(between.through)

        // Midpoint of 20…40 is 30: a cut at 35 leaves the line in the first
        // recording, a cut at 25 sends it to the second.
        let late = SplitPlan.sides(of: lines, cut: 35)
        XCTAssertEqual(late.through?.text, "a line the cut runs through")
        XCTAssertTrue(late.throughStaysInFirst)
        XCTAssertEqual(late.after?.text, "second meeting starts here")
        let early = SplitPlan.sides(of: lines, cut: 25)
        XCTAssertFalse(early.throughStaysInFirst)
        XCTAssertEqual(early.before?.text, "first meeting ends here")
        XCTAssertEqual(early.after?.text, "a line the cut runs through")
    }

    func testNothingOnOneSide() {
        let lines = [line(30, 40, "only line")]
        XCTAssertNil(SplitPlan.sides(of: lines, cut: 10).before)
        XCTAssertNil(SplitPlan.sides(of: lines, cut: 50).after)
    }

    func testCutStaysInsideWhatTheSplitItselfAccepts() {
        XCTAssertEqual(SplitPlan.clamp(-3, total: 600), 0.25)
        XCTAssertEqual(SplitPlan.clamp(9_999, total: 600), 599.75)
        XCTAssertEqual(SplitPlan.clamp(123.4, total: 600), 123.4)
        XCTAssertNil(SplitPlan.range(total: 0.4))          // too short to cut at all
        XCTAssertNil(SplitPlan.range(total: .nan))
        XCTAssertEqual(SplitPlan.clamp(.nan, total: 600), 0)
        XCTAssertEqual(SplitPlan.pauses(in: [line(0, 1), line(40, 41)], total: 0), [])
    }

    func testATypedTimeMovesTheCutUnlessItIsOnlyTheCutAsDisplayed() {
        // The picture put the cut at 419.6; the field shows 7:00.
        XCTAssertNil(SplitPlan.typed(420, replacing: 419.6, total: 600))          // untouched field: keep the exact place
        XCTAssertEqual(SplitPlan.typed(720, replacing: 419.6, total: 900), 720)   // a different time wins
        XCTAssertEqual(SplitPlan.typed(420.4, replacing: 419.6, total: 600), 420.4) // a typed fraction is meant
        XCTAssertEqual(SplitPlan.typed(3, replacing: 300, total: 600), 3)         // near the start is allowed, as for the split
        XCTAssertNil(SplitPlan.typed(5_000, replacing: 300, total: 600))          // outside: not a place on the picture
        XCTAssertNil(SplitPlan.typed(0, replacing: 300, total: 600))
    }

    func testAPressOnAMarkMeansThatPause() {
        let pauses = [SplitPlan.Pause(at: 400, length: 100), SplitPlan.Pause(at: 1500, length: 500)]
        // An hour drawn 580 points wide: the marks are at 64.4 and 241.7.
        XCTAssertEqual(SplitPlan.pause(under: 70, width: 580, total: 3600, in: pauses)?.at, 400)
        XCTAssertEqual(SplitPlan.pause(under: 236, width: 580, total: 3600, in: pauses)?.at, 1500)
        XCTAssertNil(SplitPlan.pause(under: 150, width: 580, total: 3600, in: pauses))
        XCTAssertNil(SplitPlan.pause(under: 70, width: 0, total: 3600, in: pauses))
    }

    func testSidesDoNotDependOnTheOrderOfTheLinesAndACutOnAMidpointGoesToTheSecond() {
        let lines = [line(50, 60, "c"), line(0, 10, "a"), line(20, 40, "b")]
        let sides = SplitPlan.sides(of: lines, cut: 30)   // exactly the midpoint of "b"
        XCTAssertEqual(sides.before?.text, "a")
        XCTAssertEqual(sides.after?.text, "b")
        XCTAssertFalse(sides.throughStaysInFirst)
    }

    func testHeadAndTailQuoteAFewWords() {
        let text = "one two three four five six seven eight nine ten eleven twelve"
        XCTAssertEqual(SplitPlan.head(text, words: 3), "one two three")
        XCTAssertEqual(SplitPlan.tail(text, words: 3), "ten eleven twelve")
        XCTAssertEqual(SplitPlan.tail("short", words: 3), "short")
    }

    func testClock() {
        XCTAssertEqual(SplitPlan.clock(419.5), "7:00")
        XCTAssertEqual(SplitPlan.clock(3725), "1:02:05")
        XCTAssertEqual(SplitPlan.clock(-4), "0:00")
    }

    /// The picture itself: drawn off screen so a change to it can be looked
    /// at without opening a recording. The file lands in the temporary folder.
    @MainActor
    func testTimelineDraws() throws {
        // Two meetings with four minutes of nothing between them.
        func track(_ spans: [(Int, Int)]) -> [Float] {
            (0 ..< 900).map { i in
                let second = i * 600 / 900
                guard spans.contains(where: { second >= $0.0 && second < $0.1 }) else { return 0 }
                return 0.35 + 0.6 * Float((i * 37) % 11) / 11
            }
        }
        let view = SplitTimeline(
            upper: track([(2, 40), (123, 180), (472, 590)]), lower: track([(42, 120), (420, 470)]),
            total: 600, pauses: [SplitPlan.Pause(at: 419.5, length: 240)], cut: .constant(419.5))
            .frame(width: 580)
            .padding(12)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 2_000)
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("transcriberr-split-timeline.png"))
    }

    /// The whole sheet, laid out off screen at its smallest size with three
    /// suggested pauses and long lines: nothing may be cut off or overlap.
    @MainActor
    func testSheetLaysOut() throws {
        let app = try XCTUnwrap(AppContainer.shared, "the test host has an app container")
        let store = try ModelContainer(for: Schema(TranscriberrSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let repo = RecordingRepository(context: store.mainContext)
        let rec = Recording(title: "Monday", audioPath: "/nonexistent/monday.wav", durationSeconds: 3600)
        try repo.save(rec)
        try repo.appendSegments([
            Segment(startSeconds: 2, endSeconds: 300, text: "Добрий день, почнемо з бюджету на наступний квартал і подивимось на цифри разом, бо часу сьогодні небагато."),
            Segment(startSeconds: 400, endSeconds: 900, text: "Так, давайте. Я підготувала цифри по трьох напрямках і хочу пройтись по кожному окремо."),
            Segment(startSeconds: 1500, endSeconds: 2000, text: "Привіт, це вже друга зустріч, щодо найму нових людей у команду на перший квартал."),
            Segment(startSeconds: 2400, endSeconds: 3500, text: "І останнє на сьогодні: план відпусток."),
        ], to: rec)
        let sheet = SplitRecordingSheet(recording: rec, container: app, initialSeconds: 0) { _ in }
            .frame(width: 640, height: 610)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5_000)
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("transcriberr-split-sheet.png"))
    }

    // Review findings for 5.10.1.

    /// Dragged to either end the field reads a time just outside the
    /// recording; Split then refused the cut its own preview had shown.
    func testACutAtEitherEndSplitsWhereThePreviewShowed() {
        XCTAssertEqual(SplitPlan.secondsToSplit(typed: 600, cut: 599.75, total: 600), 599.75)
        XCTAssertEqual(SplitPlan.secondsToSplit(typed: 0, cut: 0.25, total: 600), 0.25)
        // A time really typed outside the recording is passed on, for the repository to refuse.
        XCTAssertEqual(SplitPlan.secondsToSplit(typed: 700, cut: 300, total: 600), 700)
        XCTAssertEqual(SplitPlan.secondsToSplit(typed: 0, cut: 300, total: 600), 0)
        // Untouched field, typed time inside: as before.
        XCTAssertEqual(SplitPlan.secondsToSplit(typed: 420, cut: 419.6, total: 600), 419.6)
        XCTAssertEqual(SplitPlan.secondsToSplit(typed: 200, cut: 419.6, total: 600), 200)
        // Length unknown (the file's duration could not be read): the typed time goes through.
        XCTAssertEqual(SplitPlan.secondsToSplit(typed: 95, cut: 0, total: 0), 95)
    }
}
