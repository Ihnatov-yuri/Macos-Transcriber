import SwiftUI

// MARK: - SpeakerRenameSheet

/// "Who is this?" for one speaker of a recording: the one place to name a
/// speaker, teach the app their voice, and say two speakers are one person.
/// Listen plays their first clear line; "Sounds like" ranks saved people by
/// voice; naming learns the voice too (through the sameness check) unless
/// switched off.
struct SpeakerRenameSheet: View {
    let speakerKey: String
    let initialName: String
    let recording: Recording
    let container: AppContainer
    /// The other speakers of this recording, for "Same person as".
    var others: [(key: String, display: String)] = []
    /// Set while stepping through unnamed speakers: Save moves on.
    var hasNext = false
    /// Cancel: stops a step-through too (default: close).
    var onCancel: (() -> Void)? = nil
    let onClose: () -> Void

    @State private var name: String
    @State private var learnVoice: Bool
    @State private var working = false
    @State private var note: String?
    @State private var failed = false
    @State private var soundsLike: [(name: String, score: Float)] = []
    @State private var listening = true
    @State private var saved: [String] = []

    init(speakerKey: String, initialName: String, recording: Recording, container: AppContainer,
         others: [(key: String, display: String)] = [], hasNext: Bool = false,
         onCancel: (() -> Void)? = nil, onClose: @escaping () -> Void) {
        self.speakerKey = speakerKey
        self.initialName = initialName
        self.recording = recording
        self.container = container
        self.others = others
        self.hasNext = hasNext
        self.onCancel = onCancel
        self.onClose = onClose
        let unnamed = initialName == speakerKey || SpeakerLabel.isPlaceholder(initialName)
        _name = State(initialValue: unnamed ? "" : initialName)
        _learnVoice = State(initialValue: speakerKey != TranscriptionRunner.micSpeakerKey)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var seconds: Double {
        recording.segments.filter { $0.speaker == speakerKey }.map { $0.endSeconds - $0.startSeconds }.reduce(0, +)
    }
    private var firstLine: Double? {
        recording.segments.filter { $0.speaker == speakerKey }.map(\.startSeconds).min()
    }
    private var savedMatch: Person? {
        PeopleStore.shared.load().first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }
    /// Saved people to pick from, filtered by what is typed.
    private var picks: [String] {
        let q = trimmed.lowercased()
        let names = saved.filter { q.isEmpty || $0.lowercased().contains(q) }
        return Array(names.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }.prefix(6))
    }

    var body: some View {
        Sheet {
            VStack(alignment: .leading, spacing: AppMetric.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Who is this?").cardTitle()
                    Spacer()
                    Text("\(SpeakerLabel.display(initialName.isEmpty ? speakerKey : initialName, key: speakerKey)) · \(PersonPage.duration(seconds))")
                        .uiLabel(9, color: AppColor.ink3)
                }
                HStack(spacing: AppMetric.s) {
                    TapButton { listen() } label: {
                        LitButtonChrome(.secondary, compact: true) { Text("▶ Listen") }
                    }
                    .disabled(firstLine == nil)
                    .help("Play this speaker's first line")
                    if listening {
                        ProgressView().controlSize(.small)
                        Text("Comparing with saved voices…").font(AppFont.text(11)).foregroundStyle(AppColor.ink3)
                    }
                }
                if !listening, soundsLike.isEmpty, !saved.isEmpty {
                    Text("Doesn't sound like anyone saved yet. Name them to start learning their voice.")
                        .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                }
                if !soundsLike.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sounds like").uiLabel(9, color: AppColor.ink2)
                        HStack(spacing: AppMetric.s) {
                            ForEach(soundsLike, id: \.name) { s in
                                TapButton { name = s.name } label: {
                                    LitButtonChrome(s.name == trimmed ? .primary : .secondary, compact: true) {
                                        Text("\(s.name) · \(Int((s.score * 100).rounded()))%")
                                    }
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").uiLabel(9, color: AppColor.ink2)
                    TextField("e.g. Sarah", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(AppFont.text(15))
                        .onSubmit { save() }
                    if !picks.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(picks, id: \.self) { n in
                                TapButton { name = n } label: {
                                    LitButtonChrome(.ghost, compact: true) { Text(n) }
                                }
                            }
                        }
                    }
                }
                Toggle(isOn: $learnVoice) {
                    Text(savedMatch != nil
                         ? "Add this meeting to \(savedMatch!.name)'s voice"
                         : "Remember their voice, so later recordings name them on their own")
                        .font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
                }
                .toggleStyle(.checkbox)
                .disabled(speakerKey == TranscriptionRunner.micSpeakerKey)
                if let note {
                    Text(note).font(AppFont.text(12))
                        .foregroundStyle(failed ? AppColor.statusError : AppColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HairlineSoft()
                HStack(spacing: AppMetric.s) {
                    if !others.isEmpty {
                        Menu {
                            ForEach(others, id: \.key) { o in
                                Button(o.display) { merge(into: o.key) }
                            }
                        } label: {
                            Text("Same person as…").uiLabel(10, color: AppColor.ink2)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("The diarizer split one person in two: join this speaker to another.")
                    }
                    if let p = savedMatch {
                        TapButton {
                            onClose()
                            container.requestPeoplePane(person: p.id)
                        } label: {
                            LitButtonChrome(.ghost, compact: true) { Text("Open \(p.name)'s page") }
                        }
                    }
                    Spacer()
                    TapButton { (onCancel ?? onClose)() } label: { LitButtonChrome(.ghost) { Text("Cancel") } }
                    TapButton { save() } label: {
                        LitButtonChrome(.primary) {
                            Text(working ? "Learning…" : trimmed.isEmpty ? (hasNext ? "Skip" : "Close")
                                 : hasNext ? "Save & next" : "Save")
                        }
                    }
                    .disabled(working)
                }
            }
            .padding(AppMetric.l)
        }
        .frame(minWidth: 520, minHeight: 380)
        .task { await compare() }
    }

    /// Ranks saved people by how much this speaker sounds like them, on
    /// the clip-level scale the matcher uses.
    private func compare() async {
        saved = PeopleStore.shared.load().map(\.name)
        // Already learned from this meeting: saving again would add it twice.
        if let p = savedMatch, (p.learnedFrom ?? []).contains(recording.id) { learnVoice = false }
        defer { listening = false }
        let people = PeopleStore.shared.load()
        let me = TranscriptionRunner.meName(UserDefaults.standard.string(forKey: "ui.myName"))
        let mine = VoiceprintStore.load()
        guard !people.isEmpty || mine != nil, recording.modelContext != nil else { return }
        let segs = recording.segments.sorted { $0.startSeconds < $1.startSeconds }
        let src = PeopleVoice.source(for: speakerKey, in: recording, regions: PeopleVoice.regions(segs))
        guard let samples = try? await AudioDecoder().decodeAll(file: URL(fileURLWithPath: src.path)),
              let clusters = try? await PeopleVoice.clusterEmbeddings(samples: samples, regions: src.regions, only: [speakerKey]),
              let clips = clusters[speakerKey], !clips.isEmpty else { return }
        // The user's own voice is a candidate too: a speaker that is really
        // them gets their name, not a new person.
        let voices = people.map { ($0.name, $0.print.centroid) } + (mine.map { [(me, $0.centroid)] } ?? [])
        soundsLike = voices.map { v in
            (v.0, ClusterVoice.median(clips.map { VoiceActivity.cosine($0, v.1) }))
        }
        .filter { $0.1 >= VoiceActivity.offThreshold }
        .sorted { $0.1 > $1.1 }
        .prefix(3).map { ($0.0, $0.1) }
        // The clearest match goes straight into an empty name field.
        if trimmed.isEmpty, let best = soundsLike.first, best.score >= VoiceActivity.onThreshold { name = best.name }
    }

    private func listen() {
        guard let t = firstLine else { return }
        container.audioPlayer.seek(to: t)
        container.audioPlayer.play()
    }

    private func merge(into other: String) {
        try? container.repository.mergeSpeakers(speakerKey, into: other, in: recording)
        try? TranscriptExporter.export(recording: recording)
        onClose()
    }

    /// Names the speaker; with "remember" on, learns the voice from this
    /// meeting too. A voice the sameness check refuses is not added, and
    /// the speaker stays named: the user said who it is.
    private func save() {
        guard !working else { return }
        // Skipping an unnamed speaker leaves them as they are.
        if trimmed.isEmpty, SpeakerLabel.isPlaceholder(initialName) || initialName == speakerKey || initialName.isEmpty {
            onClose()
            return
        }
        // The user's own name: named, never learned as a "person".
        let meName = TranscriptionRunner.meName(UserDefaults.standard.string(forKey: "ui.myName"))
        if trimmed.caseInsensitiveCompare(meName) == .orderedSame { learnVoice = false }
        let value: String? = trimmed.isEmpty ? nil : trimmed
        try? container.repository.setSpeakerName(value, for: speakerKey, in: recording)
        try? TranscriptExporter.export(recording: recording)
        guard let value, learnVoice, speakerKey != TranscriptionRunner.micSpeakerKey else { onClose(); return }
        working = true
        note = nil
        Task { @MainActor in
            defer { working = false }
            let id = recording.id
            let before = PeopleVoice.signature(recording)
            do {
                let print = try await PeopleVoice.learn(speaker: speakerKey, in: recording)
                guard recording.modelContext != nil, PeopleVoice.signature(recording) == before else {
                    failed = true
                    note = "The transcript changed while the voice was read. Named, but the voice was not added."
                    return
                }
                try PeopleStore.shared.remember(print, as: value, from: id)
                onClose()
            } catch {
                failed = true
                note = "Named \(value). The voice was not added: \(error.localizedDescription)"
            }
        }
    }
}

/// How a speaker key reads when no one has named it.
enum SpeakerLabel {
    /// "SPEAKER_01" reads as "Speaker 2"; "GUEST" as "Guest".
    static func display(_ name: String?, key: String) -> String {
        if let name, !name.isEmpty, name != key { return name }
        if key.hasPrefix("SPEAKER_"), let n = Int(key.dropFirst("SPEAKER_".count)) { return "Speaker \(n + 1)" }
        if key == "GUEST" { return "Guest" }
        if key == TranscriptionRunner.micSpeakerKey { return "You" }
        return key
    }

    static func isPlaceholder(_ name: String) -> Bool {
        name.hasPrefix("SPEAKER_") || name == "GUEST" || name.hasPrefix(RecordingRepository.taggedKeyPrefix)
    }
}

// MARK: - SegmentEditSheet

struct SegmentEditSheet: View {
    let segment: Segment
    let container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saveError: String?
    /// Copied at init: the body must not read the model, which a run or a
    /// version restore can delete while the sheet is open (see Save).
    private let startSeconds: Double

    init(segment: Segment, container: AppContainer) {
        self.segment = segment
        self.container = container
        let alive = !segment.isDeleted && segment.modelContext != nil
        _text = State(initialValue: alive ? segment.text : "")
        startSeconds = alive ? segment.startSeconds : 0
    }

    var body: some View {
        Sheet {
            VStack(alignment: .leading, spacing: AppMetric.l) {
                HStack {
                    Text("Edit segment").uiLabel(11)
                    Spacer()
                    Text(timestamp(startSeconds)).uiLabel(9, color: AppColor.ink2)
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
                        let before = segment.text
                        let changed: Bool
                        do {
                            changed = try container.repository.correctSegment(segment, to: text)
                        } catch {
                            saveError = error.localizedDescription
                            return
                        }
                        if let rec = segment.recording, changed {
                            // A correction is a checked reference.
                            let source = Benchmark.source(segment, in: rec)
                            Benchmark.enqueue(source, machine: before)
                        }
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
        .alert("Could not save the correction", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text("Your text is still in the editor. \(saveError ?? "")")
        }
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
                    // .disabled, not hit-testing only: an accessibility
                    // press went straight past .allowsHitTesting.
                    .disabled(isWorking)
                    .opacity(isWorking ? 0.4 : 1)
                    Spacer()
                    TapButton { split() } label: {
                        LitButtonChrome(.primary) { Text(isWorking ? "Splitting…" : "Split") }
                    }
                    .disabled(isWorking)
                }
            }
            .padding(AppMetric.l)
        }
        .frame(minWidth: 420, minHeight: 280)
    }

    private func split() {
        guard !isWorking else { return }
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
