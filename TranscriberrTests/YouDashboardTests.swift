import XCTest
import SwiftUI
@testable import Transcriberr

/// The You page: goal charts with dates, and renders of the goal chart and
/// the metric tiles so their layout can be looked at off-screen.
final class YouDashboardTests: XCTestCase {
    private func meeting(_ day: Double, fillers: Int, lang: String? = "en", words: Int = 1400) -> MeetingSpeech {
        MeetingSpeech(recordingId: UUID(), title: "m", date: Date(timeIntervalSince1970: 1_790_000_000 + day * 86_400),
                      language: lang, participants: 2, talkSeconds: 300, spanSeconds: 600, words: 700,
                      meetingWords: words, paceWords: 700, paceSeconds: 300, turns: 5, longestTurn: 40,
                      interruptions: 0, interrupted: 0, questions: 3, fillers: fillers, hedges: 0, others: ["Anna": 700])
    }

    private func fillerGoal() -> SpeechGoal {
        SpeechGoal(id: UUID(), metric: .fillers, language: "en", lowerIsBetter: true, target: 6.3, baseline: 9.0,
                   title: "Reduce filler words and pauses", why: "w", tips: [],
                   created: Date(timeIntervalSince1970: 1_790_000_000), revised: Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testTheVerdictKeepsEachMeetingsDate() {
        let ms = [meeting(1, fillers: 30), meeting(3, fillers: 50), meeting(2, fillers: 40)]
        let v = GoalJudge.judge(fillerGoal(), meetings: ms)
        XCTAssertEqual(v.values.count, v.dates.count)
        XCTAssertEqual(v.dates, v.dates.sorted(by: >), "newest first, like the values")
        XCTAssertEqual(v.dates.first, ms[1].date)
    }

    @MainActor
    private func render<V: View>(_ view: V, _ name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
            .representation(using: .png, properties: [:]))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try png.write(to: out)
        print("you render: \(out.path)")
    }

    /// The goal from the 27 Oct screenshot: 6.3 at most, started at 9.0.
    @MainActor
    func testGoalChartRenders() throws {
        // 700 words = 5 min of speaking at 140 wpm: fillers / 5 per min.
        let ms = [meeting(1, fillers: 31), meeting(2, fillers: 32), meeting(3, fillers: 36), meeting(4, fillers: 25), meeting(5, fillers: 50)]
        let goal = fillerGoal()
        let v = GoalJudge.judge(goal, meetings: ms)
        try render(GoalChart(goal: goal, verdict: v).padding(18).frame(width: 640).background(AppColor.base), "you-goal.png")
    }

    @MainActor
    func testMetricTilesRender() throws {
        let ms = (1...8).map { meeting(Double($0), fillers: 20 + $0 * 3) }
        let view = VStack(alignment: .leading, spacing: 12) {
            TileGrid {
                MetricTile(metric: .fillers, meetings: ms)
                MetricTile(metric: .questions, meetings: ms)
                MetricTile(metric: .talkShare, meetings: ms)
            }
            ForEach(YouDashboard.aboutNumbers, id: \.self) { Text($0).font(AppFont.text(11)) }
        }
        .padding(18).frame(width: 760).background(AppColor.base)
        try render(view, "you-tiles.png")
    }
}
