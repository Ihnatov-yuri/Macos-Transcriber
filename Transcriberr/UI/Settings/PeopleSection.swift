import SwiftUI
import SwiftData

/// "People": voices saved from recordings (Rename speaker → Remember this
/// voice). Each can be renamed or deleted; deleting removes the voice from
/// this Mac and leaves names already in recordings as they are.
struct PeopleSection: View {
    @State private var people = PeopleStore.shared.load()
    @State private var editing: UUID?
    @State private var draft = ""
    @State private var deleting: Person?
    @State private var confirmDeleteAll = false
    @State private var error: String?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Text("People")
                .font(AppFont.text(13, weight: .bold))
            Text(people.isEmpty
                 ? "No one saved yet. Add person records someone reading at this Mac, or learns them from a speaker in a recording. Later recordings then name that person on their own."
                 : "Later recordings name these people on their own. Adding the same name again, from another recording or a new reading, makes their voice easier to find.")
                .font(AppFont.text(11))
                .foregroundStyle(AppColor.ink2)
                .frame(maxWidth: 520, alignment: .leading)

            TapButton { adding = true } label: {
                LitButtonChrome(people.isEmpty ? .primary : .secondary, compact: true) { Text("Add person…") }
            }
            .help("Teach Transcriberr someone's voice: record them reading at this Mac, or pick them in a recording.")

            ForEach(people) { person in
                HStack(spacing: AppMetric.m) {
                    if editing == person.id {
                        TextField("Name", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                            .onSubmit { commitRename(person) }
                        TapButton { commitRename(person) } label: {
                            LitButtonChrome(.secondary, compact: true) { Text("Save") }
                        }
                    } else {
                        Text(person.name).font(AppFont.text(13))
                        Text(detail(person)).font(AppFont.text(11)).foregroundStyle(AppColor.ink3)
                        Spacer()
                        TapButton { editing = person.id; draft = person.name } label: {
                            LitButtonChrome(.ghost, compact: true) { Text("Rename") }
                        }
                        TapButton { deleting = person } label: {
                            LitButtonChrome(.ghost, compact: true) { Text("Delete…") }
                        }
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
            }

            if people.count > 1 {
                TapButton { confirmDeleteAll = true } label: {
                    LitButtonChrome(.ghost, compact: true) { Text("Delete everyone…") }
                }
            }
            if let error {
                Text(error).font(AppFont.text(11)).foregroundStyle(AppColor.statusError)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PeopleStore.didChange)) { _ in
            people = PeopleStore.shared.load()
        }
        .sheet(isPresented: $adding) { AddPersonSheet { adding = false } }
        .confirmationDialog(
            "Delete \(deleting?.name ?? "")'s voice?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { person in
            Button("Delete", role: .destructive) { run { try PeopleStore.shared.delete(person.id) } }
        } message: { _ in
            Text("The voice is removed from this Mac. Names already in recordings stay.")
        }
        .confirmationDialog("Delete all \(people.count) saved voices?", isPresented: $confirmDeleteAll,
                            titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { run { try PeopleStore.shared.deleteAll() } }
        }
    }

    private func detail(_ p: Person) -> String {
        let from = p.sources == 1 ? "1 recording" : "\(p.sources) recordings"
        return "\(Int(p.print.seconds)) s from \(from)"
    }

    private func commitRename(_ person: Person) {
        run { try PeopleStore.shared.rename(person.id, to: draft) }
        editing = nil
    }

    private func run(_ body: () throws -> Void) {
        do { try body(); error = nil } catch { self.error = error.localizedDescription }
    }
}

/// Settings → People → Add person: teach a voice either by recording the
/// person reading at this Mac, or from a speaker in a recording.
struct AddPersonSheet: View {
    @Environment(AppContainer.self) private var container
    @Query(sort: \Recording.createdAtMillis, order: .reverse) private var recordings: [Recording]
    var onClose: () -> Void

    enum Source: String, CaseIterable { case reading = "Record them now", recording = "From a recording" }
    enum Phase: Equatable { case idle, recording, learning }

    @State private var name = ""
    @State private var source: Source = .reading
    @State private var phase: Phase = .idle
    @State private var capture: UtteranceCapture?
    @State private var ticker: Task<Void, Never>?
    @State private var recordingId: UUID?
    @State private var speakerKey: String?
    @State private var note: String?
    @State private var failed = false

    /// Made once when the sheet opens: walking every recording's segments
    /// on each render (the reading timer redraws five times a second) is the
    /// kind of SwiftData relationship walk that has crashed mid-update.
    @State private var withSpeakers: [Recording] = []
    private var chosen: Recording? { withSpeakers.first { $0.id == recordingId } }
    private var elapsed: Double { capture?.elapsedSeconds ?? 0 }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Sheet {
            VStack(alignment: .leading, spacing: AppMetric.l) {
                Text("Add a person").uiLabel(11)
                Hairline()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").uiLabel(9, color: AppColor.ink2)
                    TextField("e.g. Kate", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .disabled(phase != .idle)
                }
                Picker("", selection: $source) {
                    ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(phase != .idle)

                switch source {
                case .reading: readingPane
                case .recording: recordingPane
                }

                if let note {
                    Text(note)
                        .font(AppFont.text(12))
                        .foregroundStyle(failed ? AppColor.statusError : AppColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                HStack {
                    Spacer()
                    TapButton { close() } label: {
                        LitButtonChrome(.ghost) { Text(failed || note == nil ? "Close" : "Done") }
                    }
                }
            }
            .padding(AppMetric.l)
        }
        .frame(minWidth: 480, minHeight: 460)
        .onAppear {
            withSpeakers = Array(recordings.lazy.filter { $0.segments.contains { $0.speaker != nil } }.prefix(60))
        }
        .onDisappear { if phase == .recording { _ = capture?.stop(); ticker?.cancel() } }
    }

    // MARK: Record them now

    @ViewBuilder private var readingPane: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Text("Ask them to read this aloud at this Mac, about 30 seconds, in any language. It stops by itself.")
                .font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text(VoiceprintSection.passage)
                .font(AppFont.text(13))
                .foregroundStyle(phase == .recording ? AppColor.ink : AppColor.ink3)
                .lineSpacing(3)
                .padding(AppMetric.m)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.55)))
            if phase == .recording {
                ProgressView(value: min(elapsed, VoiceprintSection.targetSeconds), total: VoiceprintSection.targetSeconds)
                    .tint(AppColor.accent)
            }
            HStack(spacing: AppMetric.s) {
                switch phase {
                case .idle:
                    TapButton { startReading() } label: {
                        LitButtonChrome(.primary, compact: true) { Text("Start recording") }
                    }
                case .recording:
                    TapButton { finishReading() } label: {
                        LitButtonChrome(.accent, compact: true) {
                            Text(elapsed >= VoiceprintSection.minimumSeconds ? "Done"
                                 : "Keep reading… \(Int(VoiceprintSection.minimumSeconds - elapsed)) s")
                        }
                    }
                    .disabled(elapsed < VoiceprintSection.minimumSeconds)
                    TapButton { cancelReading() } label: {
                        LitButtonChrome(.ghost, compact: true) { Text("Cancel") }
                    }
                case .learning:
                    ProgressView().controlSize(.small)
                    Text("Learning the voice…").font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
                }
            }
        }
    }

    private func startReading() {
        guard checkName() else { return }
        note = nil
        Task { @MainActor in
            do {
                let c = capture ?? UtteranceCapture()
                capture = c
                c.voiceProcessing = false
                try await c.start()
                phase = .recording
                ticker = Task { @MainActor in
                    while !Task.isCancelled, phase == .recording {
                        if elapsed >= VoiceprintSection.targetSeconds { finishReading(); break }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            } catch {
                show(error)
                phase = .idle
            }
        }
    }

    private func finishReading() {
        guard phase == .recording, let capture, elapsed >= VoiceprintSection.minimumSeconds else { return }
        ticker?.cancel()
        let samples = capture.stop()
        phase = .learning
        Task { @MainActor in
            do {
                let print = try await PeopleVoice.learn(reading: samples)
                saved(try PeopleStore.shared.remember(print, as: trimmedName), seconds: print.seconds)
            } catch {
                show(error)
            }
            phase = .idle
        }
    }

    private func cancelReading() {
        ticker?.cancel()
        _ = capture?.stop()
        phase = .idle
    }

    // MARK: From a recording

    @ViewBuilder private var recordingPane: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            if withSpeakers.isEmpty {
                Text("No recording has separate speakers yet. Transcribe one with speakers on, then come back.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
            } else {
                Picker("Recording", selection: $recordingId) {
                    Text("Choose a recording").tag(UUID?.none)
                    ForEach(withSpeakers) { r in Text(r.title).tag(UUID?.some(r.id)) }
                }
                .onChange(of: recordingId) { speakerKey = nil }
                if let rec = chosen {
                    let time = PeopleVoice.speakingTime(rec.segments)
                    Picker("Speaker", selection: $speakerKey) {
                        Text("Choose who it is").tag(String?.none)
                        ForEach(time.keys.sorted(), id: \.self) { key in
                            Text("\(displayName(key, in: rec)) · \(Int(time[key] ?? 0)) s").tag(String?.some(key))
                        }
                    }
                }
                Text("Pick the speaker who is this person. At least \(Int(PeopleVoice.minLearnSeconds)) s of them talking without anyone over them is needed; more is better.")
                    .font(AppFont.text(11)).foregroundStyle(AppColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: AppMetric.s) {
                    TapButton { learnFromRecording() } label: {
                        LitButtonChrome(.primary, compact: true) {
                            Text(phase == .learning ? "Listening…" : "Learn this voice")
                        }
                    }
                    .disabled(phase != .idle || chosen == nil || speakerKey == nil)
                    if phase == .learning { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    private func displayName(_ key: String, in rec: Recording) -> String {
        rec.segments.first { $0.speaker == key && ($0.speakerName?.isEmpty == false) }?.speakerName ?? key
    }

    private func learnFromRecording() {
        guard checkName(), let rec = chosen, let key = speakerKey else { return }
        phase = .learning
        note = nil
        Task { @MainActor in
            do {
                let print = try await PeopleVoice.learn(speaker: key, in: rec)
                let person = try PeopleStore.shared.remember(print, as: trimmedName)
                try container.repository.setSpeakerName(person.name, for: key, in: rec)
                try? TranscriptExporter.export(recording: rec)
                saved(person, seconds: print.seconds)
            } catch {
                show(error)
            }
            phase = .idle
        }
    }

    // MARK: Shared

    private func checkName() -> Bool {
        guard !trimmedName.isEmpty else {
            failed = true
            note = "Type the person's name first."
            return false
        }
        return true
    }

    private func saved(_ person: Person, seconds: Double) {
        failed = false
        note = person.sources == 1
            ? "Saved \(person.name)'s voice (\(Int(seconds)) s of speech). Recordings from now on name them on their own; Find people names older ones."
            : "Added to \(person.name)'s voice, now learned from \(person.sources) recordings."
    }

    private func show(_ error: Error) {
        failed = true
        note = error.localizedDescription
    }

    private func close() {
        if phase == .recording { cancelReading() }
        onClose()
    }
}
