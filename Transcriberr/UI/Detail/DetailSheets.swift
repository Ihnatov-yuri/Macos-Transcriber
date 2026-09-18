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
                    Text("Rename speaker").uiLabel(11)
                    Spacer()
                    Text(speakerKey).uiLabel(9, color: AppColor.ink2)
                }
                Hairline()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Display name").uiLabel(9, color: AppColor.ink2)
                    TextField("e.g. Sarah", text: $name)
                        .textFieldStyle(.plain)
                        .font(AppFont.text(15))
                        .foregroundStyle(AppColor.ink)
                        .tint(AppColor.accentOnLight)
                    Hairline()
                }
                Spacer()
                HStack {
                    TapButton { onClose() } label: {
                        LitButtonChrome(.ghost) { Text("Cancel") }
                    }
                    Spacer()
                    TapButton { save() } label: {
                        LitButtonChrome(.primary) { Text("Save") }
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
                    Text("Edit segment").uiLabel(11)
                    Spacer()
                    Text(timestamp(segment.startSeconds)).uiLabel(9, color: AppColor.ink2)
                }
                Hairline()
                TextEditor(text: $text)
                    .font(AppFont.text(15))
                    .foregroundStyle(AppColor.ink)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .background(AppColor.baseDeep)
                Spacer()
                HStack {
                    TapButton { dismiss() } label: {
                        LitButtonChrome(.ghost) { Text("Cancel") }
                    }
                    Spacer()
                    TapButton {
                        // A run that reaches its first chunk (or finishes and
                        // reconciles) wipes and re-inserts every segment, and
                        // a version RESTORE does the same — the sheet can
                        // easily be open across either. Writing into a
                        // deleted SwiftData model crashes, so if this one is
                        // already gone, close without pretending to save.
                        guard !segment.isDeleted, segment.modelContext != nil else {
                            dismiss()
                            return
                        }
                        segment.text = text
                        try? segment.modelContext?.save()
                        if let rec = segment.recording {
                            try? TranscriptExporter.export(recording: rec)
                            // Hand-corrected text is exactly what the
                            // file backup exists to preserve.
                            BackupService.backupRecording(rec)
                        }
                        dismiss()
                    } label: {
                        LitButtonChrome(.primary) { Text("Save") }
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
                    Text("Split recording").uiLabel(11)
                    Spacer()
                    Text("Length \(Self.format(recording.durationSeconds))").uiLabel(9, color: AppColor.ink2)
                }
                Hairline()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Split at (mm:ss)").uiLabel(9, color: AppColor.ink2)
                    TextField("0:00", text: $timeText)
                        .textFieldStyle(.plain)
                        .font(AppFont.text(15))
                        .foregroundStyle(AppColor.ink)
                        .tint(AppColor.accentOnLight)
                        .disabled(isWorking)
                    Hairline()
                }
                Text("Defaults to the player's current position. Produces two new recordings; the original is kept until you choose to delete it.")
                    .font(AppFont.text(12))
                    .foregroundStyle(AppColor.ink3)
                if let error {
                    Text(error).uiLabel(9, color: AppColor.statusError)
                }
                Spacer()
                HStack {
                    TapButton { onDone(false) } label: {
                        LitButtonChrome(.ghost) { Text("Cancel") }
                    }
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
                        LitButtonChrome(.primary) { Text(isWorking ? "Splitting…" : "Split") }
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
            container.jobManager.cancel(recording.id)
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

    /// A subview never gets more than the container's width: a chip with a
    /// long folder or speaker name used to be placed at its unconstrained size
    /// and ran out of a narrow column.
    private func size(of sv: LayoutSubview, within width: CGFloat) -> CGSize {
        let ideal = sv.sizeThatFits(.unspecified)
        guard width.isFinite, ideal.width > width else { return ideal }
        return sv.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var height: CGFloat = 0, rowWidth: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for sv in subviews {
            let s = size(of: sv, within: width)
            if rowWidth > 0, rowWidth + s.width > width {
                height += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            widest = max(widest, rowWidth - spacing)
        }
        height += rowHeight
        // Unbounded proposal → report what the rows actually use, never ∞.
        return CGSize(width: width.isFinite ? width : widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let s = size(of: sv, within: width)
            if x > bounds.minX, x - bounds.minX + s.width > width {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .init(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
