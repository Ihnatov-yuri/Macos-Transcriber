import SwiftUI
import SwiftData

/// Port of Android `recordings/RecordingDetailScreen.kt`.
struct DetailView: View {
    let recording: Recording
    var onClose: () -> Void = {}
    @Environment(AppContainer.self) private var container
    @Query(sort: \Folder.sortOrder) private var allFolders: [Folder]

    @State private var model: DetailModel?
    @State private var tab: Tab = .transcript
    @State private var proseMode = false
    @State private var showTimestamps = true
    @State private var transcriptStyle: TranscriptStyle = .clean
    @State private var fullscreen = false
    /// Height of the detail pane, to cap the header (see `content`).
    @State private var paneHeight: CGFloat = 800
    /// Top row + tab strip + player + a readable stretch of transcript.
    private static let reservedForTranscript: CGFloat = 400
    @State private var runExpanded = false
    @State private var editingSegment: Segment?
    @State private var renamingSpeaker: String?
    @State private var showingSplit = false
    @State private var findingPeople = false
    /// Read on appear and on change, never per render: it is a file.
    @State private var hasPeople = false
    @State private var peopleNote: String?

    /// Transcript, then one tab per post-processing preset in Settings
    /// order, then any output whose preset was since deleted, then Versions.
    enum Tab: Hashable, Identifiable {
        case transcript
        case output(presetId: String, label: String)
        case versions
        var id: String {
            switch self {
            case .transcript: return "transcript"
            case .output(let presetId, _): return "output:" + presetId
            case .versions: return "versions"
            }
        }
        var label: String {
            switch self {
            case .transcript: return "Transcript"
            case .output(_, let label): return label
            case .versions: return "Versions"
            }
        }
    }

    private var tabs: [Tab] {
        let presets = container.presetStore.presets
        let known = Set(presets.map(\.id))
        var orphans: [Tab] = []
        var seen: Set<String> = []
        for doc in recording.outputs.sorted(by: { $0.createdAtMillis < $1.createdAtMillis })
        where !known.contains(doc.presetId) && seen.insert(doc.presetId).inserted {
            orphans.append(.output(presetId: doc.presetId, label: doc.title))
        }
        return [.transcript]
            + presets.map { .output(presetId: $0.id, label: $0.name.isEmpty ? "Untitled" : $0.name) }
            + orphans
            + [.versions]
    }

    var body: some View {
        Group {
            // The model is swapped in `.task(id:)`, one render after the
            // selection changes; until then it still belongs to the previous
            // recording and must not be drawn under this one.
            if let model, model.recording.id == recording.id {
                content(model)
            } else {
                Sheet { ProgressView().padding() }
            }
        }
        .task(id: recording.id) {
            if model?.recording.id != recording.id {
                model = DetailModel(container: container, recording: recording)
                tab = .transcript
                peopleNote = nil
                proseMode = container.uiPrefs.proseMode
                showTimestamps = container.uiPrefs.showTimestamps
                transcriptStyle = container.uiPrefs.transcriptStyle
            }
        }
    }

    @ViewBuilder
    private func content(_ model: DetailModel) -> some View {
        Sheet {
            VStack(alignment: .leading, spacing: 0) {
                topRow()
                if !fullscreen {
                    // Bounded, and scrolls inside that bound: title + metadata
                    // + an expanded Run block is 500–900 pt of chrome, which
                    // on a 640 pt window left the transcript three rows — or
                    // pushed it, the tabs and the player off the bottom.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            headerBlock(model)
                            runStrip(model)
                            speakerChipRow()
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: max(140, paneHeight - Self.reservedForTranscript))
                    .fixedSize(horizontal: false, vertical: true)
                }
                tabStrip()
                PlayerBar(recording: recording)
                if !fullscreen { HairlineSoft() }
                tabContent(model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
            .onAppear { hasPeople = !PeopleStore.shared.load().isEmpty }
            .onReceive(NotificationCenter.default.publisher(for: PeopleStore.didChange)) { _ in
                hasPeople = !PeopleStore.shared.load().isEmpty
            }
        }
        .sheet(item: $editingSegment) { seg in
            SegmentEditSheet(segment: seg, container: container)
        }
        .sheet(isPresented: Binding(
            get: { renamingSpeaker != nil },
            set: { if !$0 { renamingSpeaker = nil } }
        )) {
            if let key = renamingSpeaker {
                SpeakerRenameSheet(
                    speakerKey: key,
                    initialName: currentSpeakerName(key),
                    recording: recording,
                    container: container
                ) { renamingSpeaker = nil }
            }
        }
        .sheet(isPresented: $showingSplit) {
            SplitRecordingSheet(
                recording: recording,
                container: container,
                // The player is a single shared instance whose currentTime
                // isn't reset synchronously on load(url:) — if the user just
                // switched recordings, it can still read a moment from the
                // PREVIOUS one until the first time-observer tick lands.
                // Falling back to 0 rather than trusting a value that might
                // not even fit this recording's duration.
                initialSeconds: container.audioPlayer.currentTime < recording.durationSeconds
                    ? container.audioPlayer.currentTime : 0
            ) { deletedOriginal in
                showingSplit = false
                if deletedOriginal { onClose() }
            }
        }
    }

    // MARK: - Speaker chips

    @ViewBuilder
    private func speakerChipRow() -> some View {
        let speakers = uniqueSpeakers()
        if !speakers.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                FlowLayout(spacing: 10) {
                    ForEach(speakers, id: \.key) { entry in
                        TapButton { renamingSpeaker = entry.key } label: {
                            HStack(spacing: 6) {
                                Rectangle()
                                    .fill(speakerColor(for: entry.key))
                                    .frame(width: 7, height: 7)
                                Text(entry.display)
                                    .uiLabel(9)
                            }
                        }
                        .contextMenu {
                            // The last 10% of diarization errors are fixed by
                            // a human in two clicks, not by a better clusterer.
                            ForEach(speakers.filter { $0.key != entry.key }, id: \.key) { other in
                                Button("Merge into \(other.display)") {
                                    guard let repo = model?.container.repository else { return }
                                    try? repo.mergeSpeakers(
                                        entry.key, into: other.key, in: recording)
                                }
                            }
                        }

                    }
                    Text("Rename ↗").uiLabel(9, color: AppColor.ink3)
                    if hasPeople {
                        TapButton { findPeople() } label: {
                            Text(findingPeople ? "Finding people…" : (peopleNote ?? "Find people ↗"))
                                .uiLabel(9, color: findingPeople ? AppColor.ink3 : AppColor.accentOnLight)
                        }
                        .help("Name this recording's speakers after the people saved in Settings.")
                    }
                }
                .padding(.horizontal, AppMetric.sheetPadding)
                .padding(.vertical, 8)
                HairlineSoft()
            }
        }
    }

    /// Transcript, versions, outputs with their history and prompts, and
    /// optionally the audio, into a folder the user picks.
    private func exportFolder(includeAudio: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to put the folder for \u{201C}\(recording.title)\u{201D}."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            let folder = try RecordingFolderExporter.export(
                recording, presets: container.presetStore, to: parent, includeAudio: includeAudio)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            AppLog.error("detail", "folder export failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Could not export the recording"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// Saved people are matched after every run; this is for recordings
    /// made before a person was saved.
    private func findPeople() {
        guard !findingPeople, let repo = model?.container.repository else { return }
        findingPeople = true
        Task { @MainActor in
            let named = await PeopleNamer.apply(to: recording, repository: repo)
            if named > 0 { try? TranscriptExporter.export(recording: recording) }
            peopleNote = named == 0 ? "No saved person found ↗"
                : named == 1 ? "1 speaker named ↗" : "\(named) speakers named ↗"
            findingPeople = false
        }
    }

    private func uniqueSpeakers() -> [(key: String, display: String)] {
        var seen = [String: String]()
        var order: [String] = []
        for s in recording.segments {
            guard let key = s.speaker else { continue }
            if seen[key] == nil {
                seen[key] = s.speakerName ?? key
                order.append(key)
            }
        }
        return order.map { ($0, seen[$0] ?? $0) }
    }

    private func currentSpeakerName(_ key: String) -> String {
        recording.segments.first { $0.speaker == key }?.speakerName ?? key
    }

    /// First-appearance order, NOT hashValue (seed-randomized per launch).
    /// Callers that render many rows must precompute the order once — see
    /// tabContent — instead of calling this per row.
    private func speakerColor(for key: String) -> Color {
        let idx = uniqueSpeakers().firstIndex { $0.key == key } ?? 0
        return SpeakerPalette.colors[idx % SpeakerPalette.colors.count]
    }

    // MARK: - Copy / Share / Rename

    private func copyTranscript() {
        let body = recording.segments
            .sorted { $0.startSeconds < $1.startSeconds }
            .map { seg -> String in
                let text = transcriptStyle.apply(seg.text)
                if let name = seg.speakerName ?? seg.speaker {
                    return "\(name): \(text)"
                }
                return text
            }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
    }

    private func shareTranscript() {
        let body = recording.segments
            .sorted { $0.startSeconds < $1.startSeconds }
            .map { seg -> String in
                let text = transcriptStyle.apply(seg.text)
                if let name = seg.speakerName ?? seg.speaker {
                    return "\(name): \(text)"
                }
                return text
            }
            .joined(separator: "\n")
        presentSharePicker(items: [body])
    }

    /// Sidecar kinds for the Share ↗ menu.
    private enum SidecarKind { case txt, srt, json, audio }

    private func shareSidecar(_ kind: SidecarKind) {
        // Make sure the sidecar exists on disk — re-export if needed (cheap,
        // and guarantees the menu items always have something to share).
        try? TranscriptExporter.export(recording: recording)

        let audioURL = URL(fileURLWithPath: recording.audioPath)
        let dir = audioURL.deletingLastPathComponent()
        let stem = audioURL.deletingPathExtension().lastPathComponent
        let url: URL = {
            switch kind {
            case .txt:   return dir.appendingPathComponent("\(stem).txt")
            case .srt:   return dir.appendingPathComponent("\(stem).srt")
            case .json:  return dir.appendingPathComponent("\(stem).json")
            case .audio: return audioURL
            }
        }()
        if FileManager.default.fileExists(atPath: url.path) {
            presentSharePicker(items: [url])
        } else {
            // Fall back to the plain-text share if export didn't produce the
            // requested format (e.g. no diarization → no speakers.json).
            shareTranscript()
        }
    }

    private func presentSharePicker(items: [Any]) {
        let picker = NSSharingServicePicker(items: items)
        if let win = NSApp.keyWindow, let view = win.contentView {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    private func renameRecordingPrompt() {
        let alert = NSAlert()
        alert.messageText = "Rename recording"
        alert.informativeText = ""
        let field = NSTextField(string: recording.title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let new = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !new.isEmpty {
                recording.title = new
                // Explicit save + backup: main-context autosave would get
                // there eventually, but the file shadow only refreshes on
                // repository writes — a manual rename never reached it.
                try? recording.modelContext?.save()
                BackupService.backupRecording(recording)
            }
        }
    }

    // MARK: - Top row

    @ViewBuilder
    private func topRow() -> some View {
        HStack(spacing: AppMetric.m) {
            TapButton { onClose() } label: {
                Text("← Close")
                    .uiLabel(11, color: AppColor.ink2)
            }

            Spacer()

            // Quick actions, always visible (no menu hunt).
            TapButton { copyTranscript() } label: {
                Text("Copy")
                    .uiLabel(10, color: hasTranscript ? AppColor.ink : AppColor.ink3)
                    .padding(.horizontal, AppMetric.s)
                    .padding(.vertical, 4)
                    .overlay(Rectangle().stroke(
                        hasTranscript ? AppColor.hair : AppColor.hair.opacity(0.7),
                        lineWidth: 1
                    ))
            }
            .allowsHitTesting(hasTranscript)

            // Share menu — shows .txt / .srt / .json / audio targets and a
            // catch-all "Share via…" that opens NSSharingServicePicker.
            Menu {
                Button("Share .txt") { shareSidecar(.txt) }.disabled(!hasTranscript)
                Button("Share .srt") { shareSidecar(.srt) }.disabled(!hasTranscript)
                Button("Share .json") { shareSidecar(.json) }.disabled(!hasTranscript)
                Divider()
                Button("Share audio file") { shareSidecar(.audio) }
                Divider()
                Button("Share transcript as text…") { shareTranscript() }.disabled(!hasTranscript)
                Divider()
                Button("Export to a folder…") { exportFolder(includeAudio: false) }
                Button("Export to a folder, with audio…") { exportFolder(includeAudio: true) }
            } label: {
                Text("Share ↗")
                    .uiLabel(10, color: hasTranscript ? AppColor.accentOnLight : AppColor.ink3)
                    .padding(.horizontal, AppMetric.s)
                    .padding(.vertical, 4)
                    .overlay(Rectangle().stroke(
                        hasTranscript ? AppColor.accent.opacity(0.6) : AppColor.hair.opacity(0.7),
                        lineWidth: 1
                    ))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Menu {
                Button(fullscreen ? "Exit fullscreen" : "Fullscreen") { fullscreen.toggle() }
                Divider()
                Button("Reveal in Finder") {
                    let url = URL(fileURLWithPath: recording.audioPath)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Re-export sidecars") {
                    try? TranscriptExporter.export(recording: recording)
                }
                Button("Mark transcript as checked") {
                    // Every line becomes a reference in the benchmark, as
                    // it reads now. Lines already corrected keep their
                    // original machine text.
                    let sources = recording.segments.map { Benchmark.source($0, in: recording) }
                    let tasks = sources.compactMap { Benchmark.enqueue($0, machine: $0.text) }
                    let title = recording.title
                    Task {
                        var added = 0
                        for t in tasks where await t.value != nil { added += 1 }
                        AppLog.info("bench", "marked \(added) of \(sources.count) segments of \"\(title)\" as checked")
                    }
                }
                .disabled(recording.segments.isEmpty || (model?.isRunning ?? false) || !Benchmark.isEnabled)
                Divider()
                Button("Split recording…") {
                    showingSplit = true
                }
                .disabled(model?.isRunning ?? false)
                Divider()
                Button("Rename recording…") {
                    renameRecordingPrompt()
                }
                Button("Delete recording", role: .destructive) {
                    // Same reasoning as the library's Delete: a run still
                    // streaming into this recording must not outlive it.
                    container.jobManager.cancel(recording.id)
                    try? container.repository.delete(recording)
                    onClose()
                }
            } label: {
                Text("More ⋯").uiLabel(11, color: AppColor.ink2)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, AppMetric.sheetPadding)
        .padding(.top, AppMetric.sheetVerticalPadding)
        .padding(.bottom, 10)
    }

    private var hasTranscript: Bool { !recording.segments.isEmpty }

    // MARK: - Header

    @ViewBuilder
    private func headerBlock(_ m: DetailModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            InkRule()
            Spacer().frame(height: AppMetric.l)

            HStack(spacing: 0) {
                Text("03 / ").uiLabel(11, color: AppColor.accentOnLight)
                Text("Session").uiLabel(11)
                Spacer()
            }
            .padding(.horizontal, AppMetric.sheetPadding)

            Spacer().frame(height: AppMetric.s)

            Text(recording.title)
                .font(AppFont.text(26))
                .lineLimit(3)
                .lineSpacing(4)
                .tracking(-0.2)
                .foregroundStyle(AppColor.ink)
                .padding(.horizontal, AppMetric.sheetPadding)

            Spacer().frame(height: AppMetric.m)
            HairlineSoft()
            Spacer().frame(height: AppMetric.s)

            metadataStrip()
                .padding(.horizontal, AppMetric.sheetPadding)

            Spacer().frame(height: AppMetric.s)
            HairlineSoft()
            Spacer().frame(height: AppMetric.s)

            organizeRow()
                .padding(.horizontal, AppMetric.sheetPadding)

            Spacer().frame(height: AppMetric.s)
            HairlineSoft()
            Spacer().frame(height: AppMetric.m)
        }
    }

    @ViewBuilder
    private func organizeRow() -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppMetric.m) {
            folderMenu()
            TagEditorRow(recording: recording)
        }
    }

    @ViewBuilder
    private func folderMenu() -> some View {
        // `@Query`, not a fetch inside the body: the fetch ran on every
        // evaluation of the detail header — which during a run is once per
        // streamed chunk — and it is the same data SwiftData is already
        // keeping up to date for the rest of the screen.
        Menu {
            ForEach(allFolders.filter { $0.id != recording.folder?.id }, id: \.id) { folder in
                Button(folder.name) {
                    try? container.repository.move(recording, to: folder)
                }
            }
            if recording.folder != nil {
                Divider()
                Button("Remove from Folder") {
                    try? container.repository.move(recording, to: nil)
                }
            }
        } label: {
            Text("Folder: \(recording.folder?.name ?? "—") ▾")
                .uiLabel(9, color: recording.folder == nil ? AppColor.ink2 : AppColor.accentOnLight)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func metadataStrip() -> some View {
        let bits: [String] = {
            var out: [String] = []
            let total = Int(recording.durationSeconds)
            out.append(total >= 3600
                ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
                : String(format: "%d:%02d", total / 60, total % 60))
            if let b = recording.transcribedWithBackend, !b.isEmpty {
                out.append(b)
            }
            if let lang = recording.sourceLanguage, !lang.isEmpty {
                out.append(lang)
            }
            let speakers = Set(recording.segments.compactMap { $0.speaker }).count
            if speakers > 0 { out.append("\(speakers) speakers") }
            out.append("\(recording.segments.count) turns")
            if let mc = MeetingContext.decode(recording.meetingContextJSON) {
                var s = "Invite: \(mc.title)"
                if !mc.attendees.isEmpty { s += " · \(mc.attendees.count) people" }
                if mc.pastMeetings > 0 { s += " · \(mc.pastMeetings) earlier meetings" }
                out.append(s)
            }
            return out
        }()
        HStack(spacing: 6) {
            ForEach(Array(bits.enumerated()), id: \.offset) { (i, t) in
                if i > 0 {
                    Text("·").uiLabel(9, color: AppColor.ink3)
                }
                Text(t).uiLabel(9, color: AppColor.ink2)
            }
            Spacer()
        }
    }

    // MARK: - Run strip

    @ViewBuilder
    private func runStrip(_ m: DetailModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TapButton {
                runExpanded.toggle()
            } label: {
                HStack(spacing: AppMetric.s) {
                    Text(runExpanded ? "Run ▾" : "Run ▸").uiLabel(11)
                    Text(runSummary(m)).uiLabel(10, color: AppColor.ink2)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, AppMetric.sheetPadding)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }


            if runExpanded {
                runOptionsBlock(m)
            }

            if let err = m.lastError {
                HStack {
                    Text(err).uiLabel(9, color: AppColor.statusError)
                    Spacer()
                }
                .padding(.horizontal, AppMetric.sheetPadding)
                .padding(.vertical, 6)
                .background(AppColor.baseDeep)
            }

            runStatusBar(m)

            HairlineSoft()
        }
    }

    private func runSummary(_ m: DetailModel) -> String {
        var parts: [String] = [m.backend.displayName]
        parts.append(m.languages.isEmpty ? "auto lang" : m.languages.sorted().joined(separator: ", "))
        if m.translateToEnglish { parts.append("→ english") }
        if m.diarize { parts.append(m.hybridDiarize ? "hybrid diar" : "diar") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func runOptionsBlock(_ m: DetailModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HairlineSoft()
            LedgerRow("Engine") {
                EnginePicker(title: "", kinds: BackendFactory.Kind.allCases.filter(\.supportsAudio), selection: Binding(
                    get: { m.backend }, set: { m.backend = $0 }
                ))
                .labelsHidden()
                .frame(maxWidth: 260)
            }
            HairlineSoft()
            if m.backend == .ensemble {
                // Sub-engine slots for the dual-ASR merge — local engines only.
                // Gemma 4 (text mode) arbitrates the merged transcript.
                let mergeOptions = BackendFactory.Kind.allCases.filter {
                    $0.isLocal && $0.supportsAudio && $0 != .ensemble
                }
                LedgerRow("Merge A") {
                    EnginePicker(title: "", kinds: mergeOptions, selection: Binding(
                        get: { m.container.uiPrefs.ensembleEngineA },
                        set: { newValue in
                            // Keep A ≠ B (same swap policy as Settings → Engines).
                            if newValue == m.container.uiPrefs.ensembleEngineB {
                                m.container.uiPrefs.ensembleEngineB = m.container.uiPrefs.ensembleEngineA
                            }
                            m.container.uiPrefs.ensembleEngineA = newValue
                        }
                    ))
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                HairlineSoft()
                LedgerRow("Merge B") {
                    EnginePicker(title: "", kinds: mergeOptions, selection: Binding(
                        get: { m.container.uiPrefs.ensembleEngineB },
                        set: { newValue in
                            if newValue == m.container.uiPrefs.ensembleEngineA {
                                m.container.uiPrefs.ensembleEngineA = m.container.uiPrefs.ensembleEngineB
                            }
                            m.container.uiPrefs.ensembleEngineB = newValue
                        }
                    ))
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                HairlineSoft()
                Text("Runs both engines per chunk · word-level confidence merge · Gemma arbitrates hard conflicts · all local")
                    .uiLabel(9, color: AppColor.ink2)
                    .padding(.horizontal, AppMetric.sheetPadding)
                    .padding(.vertical, 6)
                HairlineSoft()
            }
            LedgerRow("Lang") {
                HStack(spacing: AppMetric.s) {
                    languagePill("Auto", isOn: m.languages.isEmpty) {
                        m.languages.removeAll()
                    }
                    ForEach(supportedLanguages, id: \.self) { lang in
                        languagePill(lang,
                                     isOn: m.languages.contains(lang)) {
                            if m.languages.contains(lang) {
                                m.languages.remove(lang)
                            } else {
                                m.languages.insert(lang)
                            }
                        }
                    }
                }
            }
            HairlineSoft()
            LedgerRow("Diarize") {
                Toggle("", isOn: Binding(
                    get: { m.diarize }, set: { m.diarize = $0 }
                ))
                .labelsHidden()
            }
            HairlineSoft()
            if m.diarize {
                LedgerRow("Speakers") {
                    HStack(spacing: 12) {
                        Stepper(
                            m.expectedSpeakers == 0 ? "Auto-detect" : "\(m.expectedSpeakers)",
                            value: Binding(get: { m.expectedSpeakers }, set: { m.expectedSpeakers = $0 }),
                            in: 0...8
                        )
                        if m.expectedSpeakers > 0 {
                            TapButton { m.speakersExact.toggle() } label: {
                                Text(m.speakersExact ? "Exactly \(m.expectedSpeakers)" : "Up to \(m.expectedSpeakers)")
                                    .uiLabel(9, color: m.speakersExact ? AppColor.accentOnLight : AppColor.ink2)
                            }
                            .help("Up to: the diarizer may find fewer. Exactly: it re-tries with a finer ear until it can tell this many voices apart (never invents phantoms).")
                        }
                    }
                    .frame(maxWidth: 320, alignment: .leading)
                }
                HairlineSoft()
            }
            if m.diarize && !m.backend.needsDiarizerForSpeakers {
                LedgerRow("Hybrid") {
                    Toggle("", isOn: Binding(
                        get: { m.hybridDiarize }, set: { m.hybridDiarize = $0 }
                    ))
                    .labelsHidden()
                }
                HairlineSoft()
            }
            LedgerRow("Translate") {
                Toggle("", isOn: Binding(
                    get: { m.translateToEnglish }, set: { m.translateToEnglish = $0 }
                ))
                .labelsHidden()
            }
            HairlineSoft()
        }
        .padding(.horizontal, AppMetric.sheetPadding)
    }

    private var supportedLanguages: [String] {
        ["English", "Arabic", "Ukrainian", "Dutch"]
    }

    private func languagePill(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        // TapButton, not Button — the actions capture the @Observable
        // DetailModel (macOS 26.5 _ButtonGesture crash).
        TapButton(action: action) {
            Text(label)
                .uiLabel(9, color: isOn ? AppColor.onNight : AppColor.ink)
                .padding(.horizontal, AppMetric.s)
                .padding(.vertical, 4)
                .background(isOn ? AppColor.night : Color.clear)
                .overlay(
                    Rectangle()
                        .stroke(AppColor.hair, lineWidth: isOn ? 0 : 1)
                )
        }

    }

    @ViewBuilder
    private func runStatusBar(_ m: DetailModel) -> some View {
        // Live status bar only while a run is in flight. Once it finishes or
        // fails, fall back to the Run button — otherwise you could never
        // re-run (e.g. after switching the engine). A failure keeps its
        // reason visible above the button.
        if m.isRunning, let s = m.status {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: max(0, min(1, s.fraction)))
                    .progressViewStyle(.linear)
                    .tint(AppColor.accent)
                HStack {
                    Text(s.stage)
                        .uiLabel(9, color: AppColor.onNight.opacity(0.75))
                    Spacer()
                    // TapButton, not Button — Button's _ButtonGesture
                    // crashes on macOS 26.5 when the action captures a
                    // @MainActor @Observable model (DetailModel here).
                    TapButton { m.cancel() } label: {
                        Text("Cancel")
                            .font(AppFont.display(9, weight: .semibold))
                            .foregroundStyle(AppColor.onNight)
                    }
                }
            }
            .padding(.horizontal, AppMetric.sheetPadding)
            .padding(.vertical, 10)
            .background(AppColor.night, in: Rectangle())
            .litLift(.one, in: Rectangle())
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let s = m.status, s.failed {
                    Text(s.stage)
                        .uiLabel(9, color: AppColor.statusError)
                        .padding(.horizontal, AppMetric.sheetPadding)
                        .padding(.top, 8)
                } else if let note = m.status?.note {
                    Text(note)
                        .uiLabel(9, color: AppColor.ink3)
                        .padding(.horizontal, AppMetric.sheetPadding)
                        .padding(.top, 8)
                }
                // Reuses InverseFooter — this IS its motivating example
                // (RUN TRANSCRIPTION) — rather than a second hand-rolled
                // night-ground bar with its own copy of the lift shadow.
                InverseFooter(
                    m.status == nil ? "Run transcription" : "Re-run transcription",
                    action: { m.run() }
                ) {
                    PulseDot(diameter: 6, animated: false)
                } right: {
                    Text("→").font(AppFont.display(20, weight: .semibold))
                        .foregroundStyle(AppColor.accent)
                }
            }
        }
    }

    // MARK: - Tabs

    @ViewBuilder
    private func tabStrip() -> some View {
        VStack(spacing: 0) {
            HairlineSoft()
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(tabs) { t in
                            TapButton { tab = t } label: {
                                VStack(spacing: 4) {
                                    Text(t.label).uiLabel(10, color: tab.id == t.id ? AppColor.ink : AppColor.ink2)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 10)
                                    Rectangle()
                                        .fill(tab.id == t.id ? AppColor.accent : Color.clear)
                                        .frame(width: 28, height: 1.5)
                                }
                            }
                        }
                    }
                }
                // Tabs that don't fit scroll; the fade says there is more.
                .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                             .init(color: .black, location: 0.94),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                Spacer(minLength: AppMetric.s)
                if tab == .transcript {
                  HStack(spacing: AppMetric.m) {
                    TapButton {
                        proseMode.toggle()
                        container.uiPrefs.proseMode = proseMode
                    } label: {
                        Text(proseMode ? "Cards" : "Prose").uiLabel(9, color: AppColor.ink2)
                    }
                    TapButton {
                        transcriptStyle = transcriptStyle == .clean ? .verbatim : .clean
                        container.uiPrefs.transcriptStyle = transcriptStyle
                    } label: {
                        // Names the mode you would switch TO, like Cards/Prose.
                        Text(transcriptStyle == .clean ? "Verbatim" : "Clean").uiLabel(9, color: AppColor.ink2)
                    }
                    .help(transcriptStyle == .clean
                          ? "Showing clean text (no um/uh, no stutters). Switch to exactly what was heard."
                          : "Showing verbatim text. Switch to clean reading text.")
                    TapButton {
                        showTimestamps.toggle()
                        container.uiPrefs.showTimestamps = showTimestamps
                    } label: {
                        Text(showTimestamps ? "−Times" : "+Times").uiLabel(9, color: AppColor.ink2)
                    }
                    TapButton { fullscreen.toggle() } label: {
                        Text(fullscreen ? "Exit ⤡" : "Read ⤢")
                            .uiLabel(9, color: fullscreen ? AppColor.accentOnLight : AppColor.ink2)
                    }
                  }
                  .fixedSize()
                }
            }
            .padding(.horizontal, AppMetric.sheetPadding)
            HairlineSoft()
        }
    }

    @ViewBuilder
    private func tabContent(_ model: DetailModel) -> some View {
        // A tab whose preset was deleted or renamed meanwhile: match by id,
        // and fall back to the transcript when the tab is gone.
        switch tabs.first(where: { $0.id == tab.id }) ?? .transcript {
        case .transcript:
            TranscriptPane(
                recording: recording,
                player: model.container.audioPlayer,
                proseMode: proseMode,
                showTimestamps: showTimestamps,
                style: transcriptStyle,
                isRunning: model.isRunning,
                runStage: model.status?.stage,
                backgroundRun: model.status?.background ?? false,
                onEditSegment: { editingSegment = $0 },
                onPickAlternative: { seg, k in pickAlternative(seg, disputeIndex: k) },
                speakerColor: { [order = uniqueSpeakers().map(\.key)] key in
                    // Precomputed ONCE per render — calling uniqueSpeakers()
                    // per row walked the SwiftData segments relationship
                    // hundreds of times mid-update and segfaulted SwiftData.
                    SpeakerPalette.colors[(order.firstIndex(of: key) ?? 0) % SpeakerPalette.colors.count]
                }
            )
        case .output(let presetId, _):
            OutputPane(model: model, presetId: presetId)
        case .versions:
            VersionsPane(model: model)
        }
    }
}

// MARK: - Versions pane

/// One saved run per row — engine, date, size — with expandable full text,
/// RESTORE (swap back in as the live transcript) and DELETE. This is how
/// engines are compared on the same audio: run engine 1, run engine 2, open
/// VERSIONS.
extension DetailView {
    /// Switch a disputed word to the other engine's reading, then learn the
    /// choice: the vote prefers it next time the engines split the same way,
    /// and a name or coined term also joins the vocabulary.
    func pickAlternative(_ seg: Segment, disputeIndex k: Int) {
        var list = DisputeIndex.decode(recording.disputesJSON)
        guard list.indices.contains(k) else { return }
        // Found again in the stored text (the row showed the styled text),
        // the way the transcript found it: every dispute, earlier segments
        // claiming theirs first, so the second copy of a word is the one
        // clicked and not the first.
        let ordered = recording.segments.sorted { $0.startSeconds < $1.startSeconds }
        guard let row = ordered.firstIndex(where: { $0.id == seg.id }),
              let hit = DisputeIndex.hit(k, disputes: list,
                                         in: ordered.map { ($0.startSeconds, $0.endSeconds, $0.text) }, row: row)
        else { return }
        let sentenceStart = DisputeLearning.startsSentence(hit.range, in: seg.text)
        let picked = DisputeIndex.pick(hit, in: seg.text)
        seg.text = picked.text
        list[k] = picked.flipped
        recording.disputesJSON = DisputeIndex.encode(list)
        try? container.repository.save(recording)
        try? TranscriptExporter.export(recording: recording)
        let term = DisputeIndex.core(hit.dispute.alternative)
        let isTerm = DisputeLearning.isTerm(term, sentenceStart: sentenceStart)
        switch DisputeLearning.record(loser: hit.dispute.chosen, winner: hit.dispute.alternative, learn: isTerm) {
        case .learned:
            container.promptStore.learnTerm(term, language: recording.sourceLanguage)
        case .undone:
            // The click back: the term the first click added goes too.
            container.promptStore.forgetLearnedTerm(DisputeIndex.core(hit.dispute.chosen))
        case .ignored:
            break
        }
        AppLog.info("detail", "dispute: \"\(hit.dispute.chosen)\" → \"\(hit.dispute.alternative)\"")
    }
}

private struct VersionsPane: View {
    let model: DetailModel
    @Environment(\.modelContext) private var context
    @State private var expandedId: UUID?

    private var versions: [TranscriptVersion] {
        model.recording.versions.sorted { $0.createdAtMillis > $1.createdAtMillis }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if versions.isEmpty {
                    Text("No saved versions yet · every completed run is snapshotted here")
                        .uiLabel(10, color: AppColor.ink2)
                        .padding(AppMetric.sheetPadding)
                } else {
                    ForEach(versions, id: \.id) { v in
                        versionRow(v)
                        HairlineSoft()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func versionRow(_ v: TranscriptVersion) -> some View {
        let isOpen = expandedId == v.id
        VStack(alignment: .leading, spacing: AppMetric.s) {
            TapButton {
                expandedId = isOpen ? nil : v.id
            } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.engineLabel)
                            .uiLabel(10)
                        Text("\(Self.dateFormatter.string(from: Date(timeIntervalSince1970: Double(v.createdAtMillis) / 1000))) · \(v.segmentCount) segments")
                            .uiLabel(9, color: AppColor.ink2)
                    }
                    Spacer()
                    Text(isOpen ? "▾" : "▸")
                        .uiLabel(10, color: AppColor.ink3)
                }
                .contentShape(Rectangle())
            }

            if isOpen {
                let segs = model.container.repository.decodeVersion(v)
                Text(segs.map { seg in
                    let name = seg.speakerName ?? seg.speaker
                    return name.map { "\($0): \(seg.text)" } ?? seg.text
                }.joined(separator: "\n\n"))
                    .font(AppFont.text(15))
                    .lineSpacing(4)
                    .foregroundStyle(AppColor.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: AppMetric.l) {
                    TapButton {
                        // Through the repository, which shares the VIEW's
                        // context now (AppContainer hands it `mainContext`) —
                        // the "parallel world" this button used to work
                        // around is gone. Going around it meant the restore
                        // never refreshed recording.json and never rewrote
                        // the .txt/.srt sidecars, so a crash (or a
                        // `restore-backups` run) resurrected the version the
                        // user had just replaced.
                        do {
                            try model.container.repository.restoreVersion(v, to: model.recording)
                            try? TranscriptExporter.export(recording: model.recording)
                        } catch {
                            AppLog.error("detail", "version restore failed: \(error.localizedDescription)")
                        }
                    } label: {
                        Text("Restore as current")
                            .uiLabel(9, color: AppColor.accentOnLight)
                            .padding(.horizontal, AppMetric.s)
                            .padding(.vertical, 4)
                            .overlay(Rectangle().stroke(AppColor.accent.opacity(0.6), lineWidth: 1))
                    }
                    TapButton {
                        expandedId = nil
                        model.recording.versions.removeAll { $0.id == v.id }
                        context.delete(v)
                        try? context.save()
                    } label: {
                        Text("Delete")
                            .uiLabel(9, color: AppColor.ink2)
                            .padding(.horizontal, AppMetric.s)
                            .padding(.vertical, 4)
                            .overlay(Rectangle().stroke(AppColor.hair, lineWidth: 1))
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, AppMetric.sheetPadding)
        .padding(.vertical, AppMetric.s)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM · HH:mm"
        return f
    }()
}

// MARK: - Transcript pane

struct TranscriptPane: View {
    let recording: Recording
    let player: AudioPlayerController
    let proseMode: Bool
    let showTimestamps: Bool
    let style: TranscriptStyle
    var isRunning: Bool = false
    var runStage: String? = nil
    var backgroundRun: Bool = false
    var onEditSegment: (Segment) -> Void = { _ in }
    /// The user clicked a disputed word: switch it to the other engine's
    /// reading (the Int is the dispute's index in `recording.disputesJSON`).
    var onPickAlternative: (Segment, Int) -> Void = { _, _ in }
    var speakerColor: (String) -> Color = { _ in SpeakerPalette.colors[0] }

    /// Super's disputed words per segment, in playback order (a dispute
    /// shows in the first segment it matches), with the text they were found
    /// in: a hit's ranges index THAT string and are used only while the row
    /// still shows it.
    struct DisputeRow { let text: String; let hits: [DisputeIndex.Hit] }
    @State private var disputeRows: [UUID: DisputeRow] = [:]

    /// What the hits depend on. Cheap to build (utf8 counts are O(1)), so
    /// the playhead ticks that re-run `body` no longer re-scan every
    /// segment against every dispute; the scan reruns only when this changes.
    private struct DisputeKey: Hashable {
        let json: String?
        let style: TranscriptStyle
        let running: Bool
        let texts: [Int]
    }

    private func disputeKey(_ segs: [Segment]) -> DisputeKey {
        DisputeKey(json: recording.disputesJSON, style: style, running: isRunning,
                   texts: segs.map { $0.text.hashValue &+ Int($0.startSeconds * 10) })
    }

    private func disputeHits(in segs: [Segment]) -> [UUID: DisputeRow] {
        let disputes = DisputeIndex.decode(recording.disputesJSON)
        guard !disputes.isEmpty, !isRunning else { return [:] }
        var claimed = Set<Int>()
        var out: [UUID: DisputeRow] = [:]
        for seg in segs {
            let shown = style.apply(seg.text)
            let hits = DisputeIndex.hits(in: shown, start: seg.startSeconds, end: seg.endSeconds,
                                         disputes: disputes, claimed: &claimed)
            if !hits.isEmpty { out[seg.id] = DisputeRow(text: shown, hits: hits) }
        }
        return out
    }

    /// The transcript in playback order, sorted ONCE per body pass.
    ///
    /// `activeID`, `tailID` and the row list each sorted the whole
    /// relationship independently, and `segmentRow` reads
    /// `player.currentTime` — so every time-observer tick re-ran the body
    /// and re-sorted a long diarized transcript three times over. That is
    /// the stutter when scrolling during playback.
    private var sortedSegments: [Segment] {
        recording.segments.sorted { $0.startSeconds < $1.startSeconds }
    }

    /// Last segment ID that contains the current playhead — used to auto-scroll.
    private func activeID(in segs: [Segment]) -> UUID? {
        segs.last { player.currentTime >= $0.startSeconds }?.id
    }

    /// ID of the most recently transcribed segment — for live auto-scroll.
    /// True while the user is scrolled near the bottom — only then does the
    /// live transcript follow new chunks. Auto-scroll that fights a reading
    /// user is the "wobble".
    @State private var nearBottom = true

    private func tailID(in segs: [Segment]) -> UUID? { segs.last?.id }

    var body: some View {
        if recording.segments.isEmpty {
            VStack(alignment: .center, spacing: AppMetric.s) {
                Spacer()
                if isRunning {
                    PulseDot(diameter: 8)
                    Text("Transcribing…")
                        .uiLabel(11, color: AppColor.accentOnLight)
                    if let stage = runStage {
                        Text(stage)
                            .font(AppFont.text(15))
                            .foregroundStyle(AppColor.ink2)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    Text("No transcript yet · press Run above")
                        .uiLabel(11, color: AppColor.ink3)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(AppMetric.xl)
        } else if proseMode {
            ScrollView {
                Text(proseBody)
                    .font(AppFont.text(16))
                    .lineSpacing(6)
                    .foregroundStyle(AppColor.ink)
                    // A readable measure: full screen on a wide display ran
                    // one line to ~2000 pt.
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, AppMetric.sheetPadding)
                    .padding(.vertical, AppMetric.l)
            }
        } else {
            VStack(spacing: 0) {
            if isRunning {
                // Mid-run the transcript is a RAW DRAFT: speakers, echo
                // cleanup, and turn merging all happen in the finalize step
                // after the last chunk. Without this banner every mid-run
                // glance looks like a bug report.
                HStack(spacing: 8) {
                    PulseDot(diameter: 5)
                    Text(backgroundRun
                         ? "Quick draft — Super is refining this in the background and will replace it when done"
                         : "Live draft — speakers, echo cleanup and turn merging apply when the run finishes")
                        .uiLabel(9, color: AppColor.ink2)
                    Spacer()
                }
                .padding(.horizontal, AppMetric.sheetPadding)
                .padding(.vertical, 6)
                .background(AppColor.base)
                HairlineSoft()
            }
            let segs = sortedSegments
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(segs, id: \.id) { seg in
                            HairlineSoft()
                            segmentRow(seg, disputes: disputeRows[seg.id]).id(seg.id)
                        }
                        HairlineSoft()
                        // Sentinel so we can scroll just past the last row.
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .padding(.horizontal, AppMetric.sheetPadding)
                }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height
                        >= geo.contentSize.height - 140
                } action: { _, isNear in
                    nearBottom = isNear
                }
                .task(id: disputeKey(segs)) { disputeRows = disputeHits(in: sortedSegments) }
                .onChange(of: tailID(in: segs)) { _, new in
                    // New chunk arrived → follow, but ONLY if the user is
                    // already at the bottom, and without animation — an
                    // animated chase re-triggered every chunk reads as
                    // wobble, and it hijacks the scroll wheel mid-read.
                    guard let new, nearBottom else { return }
                    proxy.scrollTo(new, anchor: .bottom)
                }
                .onChange(of: activeID(in: segs)) { _, new in
                    // Playback advanced → follow the active segment.
                    guard let new else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
            }
        }
    }

    private var proseBody: String {
        let segs = sortedSegments
        var prev: String? = nil
        var lines: [String] = []
        for seg in segs {
            let name = seg.speakerName ?? seg.speaker
            if let name, name != prev {
                lines.append("\n\(name): \(style.apply(seg.text))")
                prev = name
            } else {
                lines.append(style.apply(seg.text))
            }
        }
        return lines.joined(separator: " ")
    }

    /// The segment's text with its disputed words marked: a dotted
    /// underline, and a link that switches the word to the other reading.
    private func segmentText(_ seg: Segment, disputes: DisputeRow?) -> Text {
        let shown = style.apply(seg.text)
        // Stale cache (the text changed since the scan): plain text this
        // frame; the scan re-runs because the key changed.
        guard let disputes, disputes.text == shown, !disputes.hits.isEmpty else { return Text(shown) }
        let hits = disputes.hits
        var attr = AttributedString(shown)
        for hit in hits {
            guard let r = Range(hit.range, in: attr),
                  let url = URL(string: "transcriberr-dispute:\(hit.index)") else { continue }
            attr[r].link = url
            attr[r].underlineStyle = Text.LineStyle(pattern: .dot, color: AppColor.accentOnLight)
        }
        return Text(attr)
    }

    private func segmentRow(_ seg: Segment, disputes: DisputeRow? = nil) -> some View {
        let hits = disputes?.hits ?? []
        let active = player.currentTime >= seg.startSeconds && player.currentTime <= seg.endSeconds
        return HStack(alignment: .top, spacing: AppMetric.s) {
            VStack(alignment: .leading, spacing: 1) {
                if showTimestamps {
                    Text(timestamp(seg.startSeconds))
                        .uiLabel(9, color: AppColor.ink2)
                }
                if let lang = seg.language, !lang.isEmpty {
                    Text(lang).uiLabel(8, color: AppColor.ink3)
                }
            }
            .frame(width: 46, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                if let name = seg.speakerName ?? seg.speaker {
                    HStack(spacing: 6) {
                        Rectangle().fill(speakerColor(seg.speaker ?? "")).frame(width: 5, height: 5)
                        Text(name).uiLabel(9, color: AppColor.accentOnLight)
                    }
                }
                segmentText(seg, disputes: disputes)
                    .font(AppFont.text(15))
                    .foregroundStyle(AppColor.ink)
                    .tint(AppColor.ink)
                    .textSelection(.enabled)
                    .help(hits.isEmpty ? "" : hits.map { "\($0.dispute.chosen) · other engine heard \"\($0.dispute.alternative)\"" }
                        .joined(separator: "\n") + "\nClick an underlined word to use the other reading.")
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "transcriberr-dispute", let k = Int(url.absoluteString.dropFirst("transcriberr-dispute:".count))
                        else { return .systemAction }
                        onPickAlternative(seg, k)
                        return .handled
                    })
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 2)
        .background(active ? AppColor.accent.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { player.seek(to: seg.startSeconds) }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in onEditSegment(seg) })
    }

    private func timestamp(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Output pane

struct OutputPane: View {
    let model: DetailModel
    let presetId: String
    @State private var showingHistory = false

    private var historyCount: Int {
        model.recording.outputVersions.filter { $0.presetId == presetId }.count
    }

    private var doc: OutputDoc? {
        model.recording.outputs.first { $0.presetId == presetId }
    }

    private var runStatus: PostProcessor.Status {
        model.container.postProcessor.status["\(model.recording.id)|\(presetId)"] ?? .idle
    }

    private var isBusy: Bool {
        runStatus == .queued || runStatus == .loading || runStatus == .running
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HairlineSoft()
            HStack(spacing: AppMetric.m) {
                // Live status so a multi-minute Gemma generation never looks
                // like a dead button.
                switch runStatus {
                case .queued:
                    PulseDot(diameter: 6)
                    Text("Queued — waiting for previous generation…")
                        .uiLabel(10, color: AppColor.ink2)
                case .loading:
                    PulseDot(diameter: 6)
                    Text("Loading text model…").uiLabel(10, color: AppColor.ink2)
                case .running:
                    PulseDot(diameter: 6)
                    Text("Generating… long transcripts take minutes")
                        .uiLabel(10, color: AppColor.ink2)
                case .failed(let reason):
                    Text("Failed: \(reason)")
                        .uiLabel(9, color: AppColor.statusError)
                        .lineLimit(2)
                case .idle, .done:
                    EmptyView()
                }
                Spacer()
                if historyCount > 1 || showingHistory {
                    TapButton { showingHistory.toggle() } label: {
                        Text(showingHistory ? "Back to output" : "History (\(historyCount))")
                            .uiLabel(10, color: AppColor.ink2)
                    }
                    .help("Earlier outputs of this preset, with the prompt and engine that made each.")
                }
                if model.container.presetStore.preset(presetId) == nil {
                    Text("Its preset was deleted · restore it in Settings to generate again")
                        .uiLabel(9, color: AppColor.ink3)
                } else {
                    TapButton {
                        guard !isBusy else { return }
                        Task { @MainActor in
                            // Presets are text generation; speech-only backends
                            // coerce to the configured text engine. Resolve the
                            // model dir for the EFFECTIVE engine (LiteRT and API
                            // engines self-resolve / need none).
                            let effective: BackendFactory.Kind =
                                model.backend.supportsTextGeneration
                                    ? model.backend
                                    : model.container.uiPrefs.textEngine
                            let modelDir: URL? = nil   // LiteRT/cloud self-resolve
                            await model.container.postProcessor.run(
                                presetId: presetId,
                                recording: model.recording,
                                backend: effective,
                                modelDirectory: modelDir
                            )
                        }
                    } label: {
                        Text(isBusy ? "Working…" : "Generate ↗")
                            .uiLabel(10, color: isBusy ? AppColor.ink3 : AppColor.accentOnLight)
                    }
                }
            }
            .padding(.horizontal, AppMetric.sheetPadding)
            .padding(.vertical, 10)
            HairlineSoft()

            if showingHistory {
                OutputHistoryList(model: model, presetId: presetId) { showingHistory = false }
            } else if let doc {
                ScrollView {
                    Text(LocalizedStringKey(doc.markdown))
                        .font(AppFont.text(16))
                        .lineSpacing(6)
                        .foregroundStyle(AppColor.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(AppMetric.sheetPadding)
                }
            } else {
                VStack(alignment: .leading) {
                    Spacer()
                    Text("Not generated yet · press Generate ↗ above")
                        .uiLabel(11, color: AppColor.ink3)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer()
                }
                .padding(AppMetric.xl)
            }
        }
    }
}

// MARK: - Output history

/// Earlier outputs of one preset, newest first: the text, the engine and
/// prompt that made it, Restore (it becomes the tab's output, the current one
/// stays here) and Delete.
private struct OutputHistoryList: View {
    let model: DetailModel
    let presetId: String
    var onRestored: () -> Void
    @State private var expandedId: UUID?
    @State private var showingPrompt: UUID?

    private var versions: [OutputVersion] {
        model.container.repository.outputVersions(presetId: presetId, in: model.recording)
    }

    private var currentMarkdown: String? {
        model.recording.outputs.first { $0.presetId == presetId }?.markdown
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(versions, id: \.id) { v in
                    row(v)
                    HairlineSoft()
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ v: OutputVersion) -> some View {
        let isOpen = expandedId == v.id
        let isCurrent = v.markdown == currentMarkdown
        VStack(alignment: .leading, spacing: AppMetric.s) {
            TapButton { expandedId = isOpen ? nil : v.id } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: AppMetric.s) {
                            Text(VersionsPane.dateFormatter.string(
                                from: Date(timeIntervalSince1970: Double(v.createdAtMillis) / 1000)))
                                .uiLabel(10)
                            if isCurrent { Text("Current").uiLabel(9, color: AppColor.accentOnLight) }
                        }
                        Text(v.engineLabel ?? "Made before 4.5.0")
                            .uiLabel(9, color: AppColor.ink2)
                        if !isOpen {
                            Text(v.markdown.prefix(160).replacingOccurrences(of: "\n", with: " "))
                                .font(AppFont.text(12))
                                .foregroundStyle(AppColor.ink3)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Text(isOpen ? "▾" : "▸").uiLabel(10, color: AppColor.ink3)
                }
                .contentShape(Rectangle())
            }
            if isOpen {
                Text(LocalizedStringKey(v.markdown))
                    .font(AppFont.text(15))
                    .lineSpacing(4)
                    .foregroundStyle(AppColor.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showingPrompt == v.id, let user = v.userPrompt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("System").uiLabel(9, color: AppColor.ink2)
                        Text(v.systemPrompt ?? "").font(AppFont.text(12)).textSelection(.enabled)
                        Text("User template").uiLabel(9, color: AppColor.ink2)
                        Text(user).font(AppFont.text(12)).textSelection(.enabled)
                    }
                    .foregroundStyle(AppColor.ink2)
                    .padding(AppMetric.m)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.55)))
                }
                HStack(spacing: AppMetric.l) {
                    if !isCurrent {
                        TapButton {
                            do {
                                try model.container.repository.restoreOutput(v, to: model.recording)
                                onRestored()
                            } catch {
                                AppLog.error("detail", "output restore failed: \(error.localizedDescription)")
                            }
                        } label: {
                            Text("Restore as current")
                                .uiLabel(9, color: AppColor.accentOnLight)
                                .padding(.horizontal, AppMetric.s)
                                .padding(.vertical, 4)
                                .overlay(Rectangle().stroke(AppColor.accent.opacity(0.6), lineWidth: 1))
                        }
                    }
                    if v.userPrompt != nil {
                        TapButton { showingPrompt = showingPrompt == v.id ? nil : v.id } label: {
                            Text(showingPrompt == v.id ? "Hide prompt" : "Show prompt")
                                .uiLabel(9, color: AppColor.ink2)
                        }
                    }
                    if !isCurrent {
                        TapButton {
                            expandedId = nil
                            try? model.container.repository.deleteOutputVersion(v, from: model.recording)
                        } label: {
                            Text("Delete")
                                .uiLabel(9, color: AppColor.ink2)
                                .padding(.horizontal, AppMetric.s)
                                .padding(.vertical, 4)
                                .overlay(Rectangle().stroke(AppColor.hair, lineWidth: 1))
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, AppMetric.sheetPadding)
        .padding(.vertical, AppMetric.s)
    }
}
