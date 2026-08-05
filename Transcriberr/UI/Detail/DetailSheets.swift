import SwiftUI

// MARK: - SpeakerRenameSheet

struct SpeakerRenameSheet: View {
    let speakerKey: String
    let initialName: String
    let recording: Recording
    let container: AppContainer
    let onClose: () -> Void

    @State private var name: String

    init(speakerKey: String, initialName: String, recording: Recording,
         container: AppContainer, onClose: @escaping () -> Void) {
        self.speakerKey = speakerKey
        self.initialName = initialName
        self.recording = recording
        self.container = container
        self.onClose = onClose
        _name = State(initialValue: initialName == speakerKey ? "" : initialName)
    }

    var body: some View {
        Sheet {
            VStack(alignment: .leading, spacing: AppMetric.l) {
                HStack {
                    Text("RENAME SPEAKER").monoLabel(11, color: AppColor.ink)
                    Spacer()
                    Text(speakerKey.uppercased()).monoLabel(9, color: AppColor.inkSoft)
                }
                Hairline()
                VStack(alignment: .leading, spacing: 4) {
                    Text("DISPLAY NAME").monoLabel(9, color: AppColor.inkSoft)
                    TextField("e.g. Sarah", text: $name)
                        .textFieldStyle(.plain)
                        .font(AppFont.inter(15))
                        .foregroundStyle(AppColor.ink)
                        .tint(AppColor.accent)
                    Hairline()
                }
                Spacer()
                HStack {
                    TapButton { onClose() } label: { Text("Cancel") }

                        .foregroundStyle(AppColor.inkSoft)
                        .font(AppFont.mono(11))
                    Spacer()
                    TapButton {
                        save()
                    } label: {
                        Text("Save").monoLabel(11, color: AppColor.paper)
                            .padding(.horizontal, AppMetric.l)
                            .padding(.vertical, AppMetric.s)
                            .background(AppColor.ink)
                    }

                }
            }
            .padding(AppMetric.l)
        }
        .frame(minWidth: 360, minHeight: 200)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        try? container.repository.setSpeakerName(value, for: speakerKey, in: recording)
        try? TranscriptExporter.export(recording: recording)
        onClose()
    }
}

// MARK: - SegmentEditSheet

struct SegmentEditSheet: View {
    let segment: Segment
    let container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        Sheet {
            VStack(alignment: .leading, spacing: AppMetric.l) {
                HStack {
                    Text("EDIT SEGMENT").monoLabel(11, color: AppColor.ink)
                    Spacer()
                    Text(timestamp(segment.startSeconds)).monoLabel(9, color: AppColor.inkSoft)
                }
                Hairline()
                TextEditor(text: $text)
                    .font(AppFont.inter(15))
                    .foregroundStyle(AppColor.ink)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .background(AppColor.paperEdge)
                Spacer()
                HStack {
                    TapButton { dismiss() } label: { Text("Cancel") }

                        .foregroundStyle(AppColor.inkSoft)
                        .font(AppFont.mono(11))
                    Spacer()
                    TapButton {
                        segment.text = text
            try? segment.modelContext?.save()
                        if let rec = segment.recording {
                            try? TranscriptExporter.export(recording: rec)
                        }
                        dismiss()
                    } label: {
                        Text("Save").monoLabel(11, color: AppColor.paper)
                            .padding(.horizontal, AppMetric.l)
                            .padding(.vertical, AppMetric.s)
                            .background(AppColor.ink)
                    }

                }
            }
            .padding(AppMetric.l)
        }
        .frame(minWidth: 460, minHeight: 280)
        .onAppear { text = segment.text }
    }

    private func timestamp(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}

// MARK: - FlowLayout (simple wrapping HStack)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var rows: [[CGSize]] = [[]]
        var rowWidth: CGFloat = 0
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        for s in sizes {
            if rowWidth + s.width > width, !rows.last!.isEmpty {
                rows.append([])
                rowWidth = 0
            }
            rows[rows.count - 1].append(s)
            rowWidth += s.width + spacing
        }
        let height = rows.reduce(0) { partial, r in
            partial + (r.map(\.height).max() ?? 0) + (partial > 0 ? spacing : 0)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for (i, sv) in subviews.enumerated() {
            let s = sv.sizeThatFits(.unspecified)
            if x - bounds.minX + s.width > width, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .init(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            _ = i
        }
    }
}
