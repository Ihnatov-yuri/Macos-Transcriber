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

// MARK: - SplitRecordingSheet

/// "Cut this recording in two." Mirrors `RecordingRepository.split()`'s
/// contract — creates two new recordings and leaves the source untouched;
/// a post-success alert offers to delete the source so a bad cut point
/// never costs the original audio before the user has seen the result.
struct SplitRecordingSheet: View {
    let recording: Recording
    let container: AppContainer
    let initialSeconds: Double
    /// `true` if the source recording was deleted (so the caller knows to
    /// close its own view onto it), `false` on cancel or "keep original".
    let onDone: (Bool) -> Void

    @State private var timeText: String
    @State private var isWorking = false
    @State private var error: String?

    init(recording: Recording, container: AppContainer, initialSeconds: Double,
         onDone: @escaping (Bool) -> Void) {
        self.recording = recording
        self.container = container
        self.initialSeconds = initialSeconds
        self.onDone = onDone
        _timeText = State(initialValue: Self.format(initialSeconds))
    }

    var body: some View {
        Sheet {
            VStack(alignment: .leading, spacing: AppMetric.l) {
                HStack {
                    Text("SPLIT RECORDING").monoLabel(11, color: AppColor.ink)
                    Spacer()
                    Text("LENGTH \(Self.format(recording.durationSeconds))").monoLabel(9, color: AppColor.inkSoft)
                }
                Hairline()
                VStack(alignment: .leading, spacing: 4) {
                    Text("SPLIT AT (MM:SS)").monoLabel(9, color: AppColor.inkSoft)
                    TextField("0:00", text: $timeText)
                        .textFieldStyle(.plain)
                        .font(AppFont.inter(15))
                        .foregroundStyle(AppColor.ink)
                        .tint(AppColor.accent)
                        .disabled(isWorking)
                    Hairline()
                }
                Text("Defaults to the player's current position. Produces two new recordings; the original is kept until you choose to delete it.")
                    .font(AppFont.inter(12))
                    .foregroundStyle(AppColor.inkMuted)
                if let error {
                    Text(error.uppercased()).monoLabel(9, color: AppColor.accent)
                }
                Spacer()
                HStack {
                    TapButton { onDone(false) } label: { Text("Cancel") }
                        .foregroundStyle(AppColor.inkSoft)
                        .font(AppFont.mono(11))
                        // Once the split is running it can't actually be
                        // stopped (the Task isn't cancellable mid-flight) —
                        // disabling Cancel here avoids dismissing the sheet
                        // while it keeps running unattended in the
                        // background and then surprises the user with a
                        // delete-confirmation alert for an action they
                        // thought they'd called off.
                        .allowsHitTesting(!isWorking)
                        .opacity(isWorking ? 0.4 : 1)
                    Spacer()
                    TapButton { split() } label: {
                        Text(isWorking ? "SPLITTING…" : "SPLIT").monoLabel(11, color: AppColor.paper)
                            .padding(.horizontal, AppMetric.l)
                            .padding(.vertical, AppMetric.s)
                            .background(AppColor.ink)
                    }
                    .allowsHitTesting(!isWorking)
                }
            }
            .padding(AppMetric.l)
        }
        .frame(minWidth: 420, minHeight: 280)
    }

    private func split() {
        guard let secs = Self.parse(timeText) else {
            error = "Enter a time as mm:ss."
            return
        }
        error = nil
        isWorking = true
        Task { @MainActor in
            do {
                let result = try await container.repository.split(recording, atSeconds: secs)
                isWorking = false
                confirmDeleteOriginal(first: result.first)
            } catch {
                isWorking = false
                self.error = error.localizedDescription
            }
        }
    }

    private func confirmDeleteOriginal(first: Recording) {
        let alert = NSAlert()
        alert.messageText = "Split into two recordings"
        alert.informativeText = "“\(recording.title)” became “\(first.title)” and a second recording. "
            + "Delete the original, or keep all three?"
        alert.addButton(withTitle: "Delete Original")
        alert.addButton(withTitle: "Keep Original")
        guard alert.runModal() == .alertFirstButtonReturn else {
            onDone(false)
            return
        }
        do {
            try container.repository.delete(recording)
            onDone(true)
        } catch {
            // Don't report a delete that didn't happen — onDone(true) would
            // tell the caller to close its view on the original as if it
            // were gone, when it's still sitting right there in the library.
            let failure = NSAlert()
            failure.messageText = "Couldn't delete the original"
            failure.informativeText = error.localizedDescription
            failure.runModal()
            onDone(false)
        }
    }

    private static func format(_ s: Double) -> String {
        let t = Int(s.isFinite ? s.rounded() : 0)
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Accepts "mm:ss", "h:mm:ss", or a bare seconds count. Rejects anything
    /// a user didn't actually mean: a stray/trailing colon (Swift's default
    /// split silently drops empty pieces, so "2:" would otherwise read as
    /// "2 seconds" instead of the malformed "2 minutes, unfinished" it is),
    /// negative components, and a minutes/seconds component ≥60.
    private static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        let nums = parts.compactMap { Double($0) }
        guard nums.count == parts.count, nums.allSatisfy({ $0 >= 0 }) else { return nil }
        switch nums.count {
        case 1:
            return nums[0]
        case 2:
            guard nums[1] < 60 else { return nil }
            return nums[0] * 60 + nums[1]
        case 3:
            guard nums[1] < 60, nums[2] < 60 else { return nil }
            return nums[0] * 3600 + nums[1] * 60 + nums[2]
        default:
            return nil
        }
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
