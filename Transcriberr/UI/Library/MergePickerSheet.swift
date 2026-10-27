import SwiftUI

/// What the merge picker needs of a recording, so its ordering and search
/// are testable without a store.
nonisolated struct MergeCandidate: Identifiable, Equatable {
    let id: UUID
    let title: String
    /// `Recording.createdAtMillis` is when it STOPPED.
    let endMillis: Int64
    let durationSeconds: Double
    var startMillis: Int64 { endMillis - Int64(durationSeconds * 1000) }

    /// Seconds between the two, signed: positive when `self` starts after
    /// `source` ends, negative when it ended before `source` started, 0 when
    /// they overlap.
    func gap(from source: MergeCandidate) -> Double {
        if startMillis >= source.endMillis { return Double(startMillis - source.endMillis) / 1000 }
        if endMillis <= source.startMillis { return -Double(source.startMillis - endMillis) / 1000 }
        return 0
    }
}

nonisolated enum MergePicker {
    /// The candidates to merge `source` with: the closest in time first (a
    /// call split by a stopped recording is what usually gets merged),
    /// narrowed to titles containing every word of `query`.
    static func ordered(_ candidates: [MergeCandidate], source: MergeCandidate, query: String) -> [MergeCandidate] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return candidates
            .filter { $0.id != source.id }
            .filter { c in words.allSatisfy { c.title.lowercased().contains($0) } }
            .sorted { abs($0.gap(from: source)) < abs($1.gap(from: source)) }
    }

    /// "Starts 3 min after", "Ended 2 h before", "Overlaps".
    static func relation(_ c: MergeCandidate, to source: MergeCandidate) -> String {
        let g = c.gap(from: source)
        if g == 0 { return "Overlaps this one" }
        let span = abs(g)
        let amount: String
        if span < 60 { amount = "\(Int(span.rounded())) s" }
        else if span < 3600 { amount = "\(Int((span / 60).rounded())) min" }
        else if span < 86_400 * 2 { amount = "\(Int((span / 3600).rounded())) h" }
        else { amount = "\(Int((span / 86_400).rounded())) days" }
        return g > 0 ? "Starts \(amount) after this one" : "Ended \(amount) before this one"
    }
}

/// "Merge with…": every other recording, closest in time first, searchable,
/// with its date, length and distance from this one. Replaced a context
/// submenu that listed all titles with nothing else, taller than the screen.
struct MergePickerSheet: View {
    let source: MergeCandidate
    let sourceTitle: String
    let candidates: [MergeCandidate]
    let onMerge: (UUID) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var selected: UUID?
    @FocusState private var searchFocused: Bool

    private var shown: [MergeCandidate] { MergePicker.ordered(candidates, source: source, query: query) }

    var body: some View {
        Sheet {
            VStack(alignment: .leading, spacing: AppMetric.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Merge with").uiLabel(11)
                    Text(sourceTitle)
                        .font(AppFont.text(12))
                        .foregroundStyle(AppColor.ink3)
                        .lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Find a recording", text: $query)
                        .textFieldStyle(.plain)
                        .font(AppFont.text(15))
                        .foregroundStyle(AppColor.ink)
                        .tint(AppColor.accentOnLight)
                        .focused($searchFocused)
                        .onSubmit { mergeSelected() }
                    Hairline()
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { c in
                            MergeCandidateRow(candidate: c, source: source, isSelected: currentSelection == c.id,
                                              onSelect: { selected = c.id }, onMerge: { onMerge(c.id) })
                            HairlineSoft()
                        }
                        if shown.isEmpty {
                            Text(query.isEmpty ? "No other recordings." : "No recording matches “\(query)”.")
                                .font(AppFont.text(12))
                                .foregroundStyle(AppColor.ink3)
                                .padding(.vertical, AppMetric.m)
                        }
                    }
                }
                .frame(minHeight: 260)
                Text("Makes one new recording of the two, in time order. Both originals stay in the library.")
                    .font(AppFont.text(12))
                    .foregroundStyle(AppColor.ink3)
                HStack {
                    TapButton { onCancel() } label: {
                        LitButtonChrome(.ghost) { Text("Cancel") }
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    TapButton { mergeSelected() } label: {
                        LitButtonChrome(.primary) { Text("Merge") }
                    }
                    .disabled(currentSelection == nil)
                    .opacity(currentSelection == nil ? 0.4 : 1)
                }
            }
            .padding(AppMetric.l)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 460, idealHeight: 540)
        .onAppear { searchFocused = true }
    }

    /// The highlighted row, or the closest one when nothing is highlighted
    /// and the search left it at the top.
    private var currentSelection: UUID? {
        if let selected, shown.contains(where: { $0.id == selected }) { return selected }
        return shown.first?.id
    }

    private func mergeSelected() {
        guard let id = currentSelection else { return }
        onMerge(id)
    }

    static func length(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// One recording in the merge picker: title, start, distance from the
/// recording being merged, length. Click selects, double-click merges.
struct MergeCandidateRow: View {
    let candidate: MergeCandidate
    let source: MergeCandidate
    let isSelected: Bool
    let onSelect: () -> Void
    let onMerge: () -> Void

    var body: some View {
        let c = candidate
        let start = Date(timeIntervalSince1970: TimeInterval(c.startMillis) / 1000)
        return TapButton(action: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: AppMetric.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title)
                        .font(AppFont.text(14, weight: isSelected ? .bold : .regular))
                        .foregroundStyle(AppColor.ink)
                        .lineLimit(1)
                    Text("\(start.formatted(date: .abbreviated, time: .shortened)) · \(MergePicker.relation(c, to: source))")
                        .font(AppFont.text(11))
                        .foregroundStyle(AppColor.ink3)
                }
                Spacer()
                Text(MergePickerSheet.length(c.durationSeconds))
                    .font(AppFont.text(12))
                    .foregroundStyle(AppColor.ink2)
            }
            .padding(.vertical, AppMetric.s)
            .padding(.horizontal, AppMetric.s)
            .background(isSelected ? AppColor.accent.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded(onMerge))
        .accessibilityLabel("\(c.title), \(MergePicker.relation(c, to: source)), \(MergePickerSheet.length(c.durationSeconds))")
    }
}
