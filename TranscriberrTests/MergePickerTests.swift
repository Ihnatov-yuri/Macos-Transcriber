import XCTest
import SwiftUI
@testable import Transcriberr

/// The "Merge with…" picker: closest in time first, title search, and
/// labels that say how far apart the two recordings are.
final class MergePickerTests: XCTestCase {
    private let base: Int64 = 1_793_100_000_000

    /// `end` in minutes from `base`; `length` in minutes.
    private func c(_ title: String, end: Double, length: Double) -> MergeCandidate {
        MergeCandidate(id: UUID(), title: title, endMillis: base + Int64(end * 60_000), durationSeconds: length * 60)
    }

    func testClosestInTimeComesFirst() {
        let source = c("Standup part 1", end: 30, length: 30)          // 0:00-0:30
        let partTwo = c("Standup part 2", end: 45, length: 13)          // starts 2 min after
        let earlier = c("Morning dictation", end: -60, length: 1)       // ended 90 min before
        let lastWeek = c("Old interview", end: -7 * 24 * 60, length: 40)
        let order = MergePicker.ordered([lastWeek, earlier, partTwo, source], source: source, query: "")
        XCTAssertEqual(order.map(\.title), ["Standup part 2", "Morning dictation", "Old interview"],
                       "the source itself is left out")
    }

    func testSearchMatchesEveryWord() {
        let source = c("A", end: 0, length: 1)
        let list = [c("CBQ Team Meeting Kickoff", end: 10, length: 5),
                    c("Aligning On CBQ Team Call", end: 20, length: 5),
                    c("Kiosk Setup", end: 5, length: 5)]
        XCTAssertEqual(MergePicker.ordered(list, source: source, query: "cbq call").map(\.title),
                       ["Aligning On CBQ Team Call"])
        XCTAssertEqual(MergePicker.ordered(list, source: source, query: "  ").count, 3)
    }

    func testTheRelationSaysHowFarApart() {
        let source = c("Source", end: 30, length: 30)
        XCTAssertEqual(MergePicker.relation(c("x", end: 33, length: 1), to: source), "Starts 2 min after this one")
        XCTAssertEqual(MergePicker.relation(c("x", end: -60, length: 1), to: source), "Ended 1 h before this one")
        XCTAssertEqual(MergePicker.relation(c("x", end: 20, length: 30), to: source), "Overlaps this one")
        XCTAssertEqual(MergePicker.relation(c("x", end: -3 * 24 * 60, length: 1), to: source), "Ended 3 days before this one")
    }

    func testOnlyAPickedOrOnlyRowIsMerged() {
        let a = c("A", end: 5, length: 1), b = c("B", end: 10, length: 1)
        XCTAssertNil(MergePicker.selection(nil, in: [a, b]), "Return must not merge the top match unasked")
        XCTAssertEqual(MergePicker.selection(b.id, in: [a, b]), b.id)
        XCTAssertNil(MergePicker.selection(b.id, in: [a, c("C", end: 20, length: 1)]),
                     "a pick the search hid no longer counts")
        XCTAssertEqual(MergePicker.selection(b.id, in: [a]), a.id, "then the one row left is the pick")
        XCTAssertEqual(MergePicker.selection(nil, in: [a]), a.id, "the only match left is the pick")
    }

    func testLengthFormat() {
        XCTAssertEqual(MergePickerSheet.length(75), "1:15")
        XCTAssertEqual(MergePickerSheet.length(3_725), "1:02:05")
    }

    /// Renders the sheet off-screen so its layout can be looked at without
    /// running a debug build against the live library.
    @MainActor
    func testTheSheetRenders() throws {
        let source = c("Developing Project Scope", end: 0, length: 36)
        let list = [c("Data Team Offer Agent", end: -50, length: 24), c("Voice Isolation Microphone Testing", end: 366, length: 0.3),
                    c("Restarting The Recording Session", end: 364, length: 0.2), c("Offers Agent Usage Assumptions Planning", end: -1_500, length: 36),
                    c("Live Kit Server and Model Deployment", end: -1_560, length: 25), c("Node Version Migration And Integration Testing", end: -1_620, length: 29)]
        // The rows as the sheet lists them (an off-screen render draws no
        // ScrollView content or AppKit text field).
        let ordered = MergePicker.ordered(list, source: source, query: "")
        let view = VStack(spacing: 0) {
            ForEach(ordered) { c in
                MergeCandidateRow(candidate: c, source: source, isSelected: c.id == ordered.first?.id,
                                  onSelect: {}, onMerge: {})
                HairlineSoft()
            }
        }
        .padding(AppMetric.l)
        .frame(width: 520)
        .background(AppColor.base)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("merge-picker.png")
        try png.write(to: out)
        print("merge picker render: \(out.path)")
    }
}
