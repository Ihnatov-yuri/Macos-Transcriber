import SwiftUI

/// Pieces the You page, person pages and the overview share.

extension Text {
    /// A card's heading: Lit Field's Title role (Archivo, 17 pt), so each
    /// card reads as a section and not as one more label.
    func cardTitle() -> some View {
        font(AppFont.display(17, weight: .semibold)).foregroundStyle(AppColor.ink)
    }
}

/// A small line of values, oldest left. Drawn, not charted: a dozen points
/// in a tile need no axes.
struct Sparkline: View {
    let values: [Double]
    var target: Double? = nil
    var body: some View {
        GeometryReader { geo in
            let all = values + (target.map { [$0] } ?? [])
            let lo = all.min() ?? 0, hi = all.max() ?? 1
            let span = max(hi - lo, 0.0001)
            let y: (Double) -> CGFloat = { geo.size.height * (1 - CGFloat(($0 - lo) / span)) }
            ZStack {
                if let target {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y(target)))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y(target)))
                    }
                    .stroke(AppColor.ink3, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if values.count > 1 {
                    Path { p in
                        for (i, v) in values.enumerated() {
                            let pt = CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(values.count - 1), y: y(v))
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                    .stroke(AppColor.ink, lineWidth: 1.5)
                }
                if let last = values.last {
                    Circle().fill(AppColor.accent).frame(width: 6, height: 6)
                        .position(x: values.count > 1 ? geo.size.width : geo.size.width / 2, y: y(last))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// One measured number with its recent history.
struct MetricTile: View {
    let metric: SpeechMetric
    let meetings: [MeetingSpeech]
    var language: String? = nil

    /// The newest meetings with a value, oldest first: the same ones the
    /// headline averages.
    private var series: [Double] { SpeechMeasure.series(metric, over: meetings, language: language) }

    var body: some View {
        let avg = SpeechMeasure.average(metric, over: meetings, language: language)
        VStack(alignment: .leading, spacing: 6) {
            Text(metric.title).uiLabel(10, color: AppColor.ink2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(avg.map(metric.format) ?? "–").font(AppFont.display(24, weight: .semibold))
                    .monospacedDigit().foregroundStyle(AppColor.ink)
                Text(metric.unit).uiLabel(9, color: AppColor.ink3)
            }
            if series.count > 1 {
                Sparkline(values: series).frame(height: 26)
            } else {
                // One point is not a line: say so instead of drawing a dot.
                Text(series.isEmpty ? "Not measured yet" : "One meeting so far")
                    .font(AppFont.text(11)).foregroundStyle(AppColor.ink4)
                    .frame(height: 26, alignment: .leading)
            }
            if series.isEmpty {
                Text(emptyReason)
                    .font(AppFont.text(11)).foregroundStyle(AppColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let trend {
                Text(trend)
                    .font(AppFont.text(11)).foregroundStyle(AppColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // What the number is, always on the tile (it used to show only
            // when there was no trend, or on hover).
            Text(metric.explanation)
                .font(AppFont.text(10)).foregroundStyle(AppColor.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppMetric.m)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .litGlass()
        .help(metric.explanation)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title): \(avg.map(metric.format) ?? "not measured") \(metric.unit). \(trend ?? "")")
    }

    /// Why a tile has no number, in plain words.
    private var emptyReason: String {
        switch metric {
        case .pace: return "Needs more short, well-timed lines than these meetings have."
        case .fillers, .hedges: return "Counted in English and Ukrainian only, from 150 words up."
        default: return "Not enough speech in these meetings to measure."
        }
    }

    /// The newer half against the older half of the same meetings, when
    /// each half has three.
    private var trend: String? {
        let s = series
        guard s.count >= 6 else { return s.isEmpty ? nil : "From the last \(s.count == 1 ? "meeting" : "\(s.count) meetings")." }
        let old = s.prefix(s.count / 2), new = s.suffix(s.count / 2)
        let a = old.reduce(0, +) / Double(old.count), b = new.reduce(0, +) / Double(new.count)
        guard abs(b - a) >= max(0.05 * abs(a), 0.05) else { return "Steady over the last \(s.count) meetings." }
        return "\(metric.format(b)) lately, \(b < a ? "down" : "up") from \(metric.format(a)) before (last \(s.count) meetings)."
    }
}

/// Talk split as one bar: the person, the user, everyone else.
struct ShareBar: View {
    let parts: [(label: String, value: Double, color: Color)]
    var body: some View {
        let total = max(parts.map(\.value).reduce(0, +), 0.0001)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts.indices, id: \.self) { i in
                        Rectangle().fill(parts[i].color)
                            .frame(width: max(0, geo.size.width * parts[i].value / total - 2))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            HStack(spacing: AppMetric.m) {
                ForEach(parts.indices, id: \.self) { i in
                    HStack(spacing: 5) {
                        Rectangle().fill(parts[i].color).frame(width: 7, height: 7)
                        Text("\(parts[i].label) \(Int((100 * parts[i].value / total).rounded()))%")
                            .uiLabel(9, color: AppColor.ink2)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Grid of tiles that wraps at the pane's width.
struct TileGrid<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: AppMetric.m, alignment: .top)],
                  alignment: .leading, spacing: AppMetric.m) { content }
    }
}

extension SpeechMetric {
    /// "English" / "Ukrainian" for a language code.
    static func languageName(_ code: String?) -> String {
        switch code {
        case "en": return "English"
        case "uk": return "Ukrainian"
        case nil: return "All languages"
        default: return code ?? ""
        }
    }
}
