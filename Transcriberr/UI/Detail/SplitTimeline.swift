import SwiftUI

// MARK: - SplitPlan

/// Where a recording could be cut in two, and what the cut would do, worked
/// out from its transcript before anything is touched. Pure, so the split
/// sheet can show the result of a cut while the pointer is still moving.
nonisolated enum SplitPlan {
    /// One line of the transcript, as far as a cut is concerned.
    struct Line: Equatable, Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    /// A stretch where nobody speaks: a likely border between two meetings.
    struct Pause: Equatable, Sendable, Identifiable {
        /// Where the cut goes: just before the next line begins.
        let at: Double
        let length: Double
        var id: Double { at }
    }

    /// What ends up on each side of a cut.
    struct Sides: Equatable, Sendable {
        /// The last line of the first recording.
        let before: Line?
        /// The first line of the second recording.
        let after: Line?
        /// A line being spoken at the cut. `RecordingRepository.split` cannot
        /// slice text, so it goes whole to the side holding its midpoint.
        let through: Line?
        /// Whether `through` goes to the first recording.
        let throughStaysInFirst: Bool
    }

    /// A pause shorter than this is a breath, not the end of a meeting.
    static let pauseWorthSuggesting = 30.0
    /// The cut sits this long before the line that follows a pause, so the
    /// second recording does not begin on the first syllable.
    static let leadIn = 0.5

    /// How close to either end a cut may be: what `RecordingRepository.split`
    /// itself accepts. One rule for the picture, the nudges and a typed time,
    /// so no way of choosing a place can reach one the others cannot.
    static let edge = 0.25

    /// `nil` when the recording is too short to cut at all.
    static func range(total: Double) -> ClosedRange<Double>? {
        guard total.isFinite, total - edge > edge else { return nil }
        return edge ... (total - edge)
    }

    static func clamp(_ seconds: Double, total: Double) -> Double {
        guard let r = range(total: total), seconds.isFinite else { return 0 }
        return min(r.upperBound, max(r.lowerBound, seconds))
    }

    /// The longest pauses, in the order they occur. Lines may overlap (two
    /// people talking), so a pause starts where the last of them has ended.
    static func pauses(in lines: [Line], total: Double, limit: Int = 3) -> [Pause] {
        guard let r = range(total: total) else { return [] }
        var found: [Pause] = []
        var saidUntil = 0.0
        for (i, line) in lines.sorted(by: { $0.start < $1.start }).enumerated() {
            let length = line.start - saidUntil
            if i > 0, length >= pauseWorthSuggesting {
                let at = max(saidUntil, line.start - leadIn)
                if r.contains(at) { found.append(Pause(at: at, length: length)) }
            }
            saidUntil = max(saidUntil, line.end)
        }
        return found.sorted { $0.length > $1.length }.prefix(limit).sorted { $0.at < $1.at }
    }

    /// Mirrors how `RecordingRepository.split` divides the transcript: a line
    /// belongs to the first recording when its midpoint is before the cut.
    static func sides(of lines: [Line], cut: Double) -> Sides {
        let ordered = lines.sorted { $0.start < $1.start }
        let first = ordered.filter { ($0.start + $0.end) / 2 < cut }
        let second = ordered.filter { ($0.start + $0.end) / 2 >= cut }
        let through = ordered.first { $0.start < cut && $0.end > cut }
        return Sides(before: first.last, after: second.first, through: through,
                     throughStaysInFirst: through.map { ($0.start + $0.end) / 2 < cut } ?? false)
    }

    /// What a time typed into the field does to the cut. The field shows whole
    /// seconds, so a typed time that is just the cut as displayed changes
    /// nothing and the exact place chosen on the picture is kept; any other
    /// time inside the recording becomes the cut. `nil`: leave the cut alone
    /// (a time outside the recording is for the split itself to refuse).
    static func typed(_ seconds: Double, replacing cut: Double, total: Double) -> Double? {
        guard let r = range(total: total), seconds.isFinite, r.contains(seconds) else { return nil }
        return abs(seconds - cut.rounded()) > 0.5 || seconds != seconds.rounded() ? seconds : nil
    }

    /// Where Split cuts, from the time in the field and the cut on the
    /// picture. The field shows the cut rounded to a second, so at either
    /// end it reads a time just outside the recording ("10:00" for a cut at
    /// 9:59.75): that is still the cut, not a typed time to refuse. A time
    /// really typed outside the recording, or any time when the length is
    /// unknown, is passed on as typed and the repository says why not.
    static func secondsToSplit(typed seconds: Double, cut: Double, total: Double) -> Double {
        if let moved = typed(seconds, replacing: cut, total: total) { return moved }
        guard let r = range(total: total) else { return seconds }
        if !r.contains(seconds), seconds != cut.rounded() { return seconds }
        return cut
    }

    /// A suggested pause under a press on the picture, if the press is on its
    /// mark. One point of width is several seconds of a long recording, so a
    /// press on a mark's number would otherwise land well inside the line
    /// that follows the pause.
    static func pause(under x: Double, width: Double, total: Double, in pauses: [Pause],
                      reach: Double = 10) -> Pause? {
        guard width > 0, total > 0 else { return nil }
        return pauses
            .map { (pause: $0, distance: abs($0.at / total * width - x)) }
            .filter { $0.distance <= reach }
            .min { $0.distance < $1.distance }?.pause
    }

    /// The last few words of a line.
    static func tail(_ text: String, words: Int = 10) -> String {
        let all = text.split(whereSeparator: \.isWhitespace)
        return all.suffix(words).joined(separator: " ")
    }

    /// The first few words of a line.
    static func head(_ text: String, words: Int = 10) -> String {
        let all = text.split(whereSeparator: \.isWhitespace)
        return all.prefix(words).joined(separator: " ")
    }

    static func clock(_ seconds: Double) -> String {
        let t = Int(seconds.isFinite ? max(0, seconds).rounded() : 0)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - SplitTimeline

/// The whole recording as a picture: you above the line and the others below
/// when the two tracks were kept, numbered marks at the longest pauses, and
/// the cut as an accent line with what becomes the second recording tinted.
/// Drag anywhere to move the cut.
struct SplitTimeline: View {
    /// Peaks of the microphone track, or of the mix when there are no tracks.
    let upper: [Float]
    /// Peaks of the call track. Empty mirrors `upper`.
    let lower: [Float]
    let total: Double
    let pauses: [SplitPlan.Pause]
    @Binding var cut: Double

    private let height: CGFloat = 104

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                draw(&context, size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard geo.size.width > 0, total > 0 else { return }
                    // A press on a mark means that pause, exactly; a drag
                    // follows the pointer.
                    let still = abs(value.translation.width) < 3 && abs(value.translation.height) < 3
                    if still, let mark = SplitPlan.pause(under: Double(value.startLocation.x),
                                                         width: Double(geo.size.width), total: total, in: pauses) {
                        cut = mark.at
                    } else {
                        cut = SplitPlan.clamp(Double(value.location.x / geo.size.width) * total, total: total)
                    }
                }
            )
        }
        .frame(height: height)
        .background(AppColor.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement()
        .accessibilityLabel(Text("The whole recording. The cut is at \(SplitPlan.clock(cut))."))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: cut = SplitPlan.clamp(cut + 1, total: total)
            case .decrement: cut = SplitPlan.clamp(cut - 1, total: total)
            @unknown default: break
            }
        }
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        guard total > 0, size.width > 0 else { return }
        let mid = size.height / 2
        func x(_ seconds: Double) -> CGFloat { CGFloat(seconds / total) * size.width }

        // What the cut would turn into the second recording.
        let cutX = x(cut)
        context.fill(Path(CGRect(x: cutX, y: 0, width: size.width - cutX, height: size.height)),
                     with: .color(AppColor.accent.opacity(0.10)))
        context.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)),
                     with: .color(AppColor.ink.opacity(0.15)))

        // One bar per point of width: the loudest moment that falls in it.
        // Silence stays empty, which is what makes a pause visible.
        func bars(_ peaks: [Float], upward: Bool, opacity: Double) {
            guard !peaks.isEmpty else { return }
            var path = Path()
            let columns = Int(size.width)
            for column in 0 ..< columns {
                let from = column * peaks.count / columns
                let to = max(from + 1, (column + 1) * peaks.count / columns)
                let peak = peaks[from ..< min(peaks.count, to)].max() ?? 0
                guard peak >= 0.02 else { continue }
                let h = max(1, CGFloat(min(1, peak)) * (mid - 8))
                path.addRect(CGRect(x: CGFloat(column), y: upward ? mid - 1 - h : mid + 1, width: 1, height: h))
            }
            context.fill(path, with: .color(AppColor.ink.opacity(opacity)))
        }
        bars(upper, upward: true, opacity: 1)
        bars(lower.isEmpty ? upper : lower, upward: false, opacity: lower.isEmpty ? 0.35 : 0.55)

        // The cut itself, under the marks so a mark's number stays readable
        // when the cut sits on it.
        context.fill(Path(CGRect(x: cutX.rounded() - 1.5, y: 0, width: 3, height: size.height)),
                     with: .color(AppColor.accent))

        // Suggested places: a thin line with its number on top.
        for (index, pause) in pauses.enumerated() {
            let px = x(pause.at).rounded()
            context.fill(Path(CGRect(x: px, y: 0, width: 1, height: size.height)), with: .color(AppColor.ink))
            context.fill(Path(ellipseIn: CGRect(x: px - 9, y: 2, width: 18, height: 18)), with: .color(AppColor.ink))
            context.draw(
                Text(verbatim: "\(index + 1)").font(AppFont.display(11, weight: .semibold)).foregroundStyle(Color.white),
                at: CGPoint(x: px, y: 11))
        }
    }
}
