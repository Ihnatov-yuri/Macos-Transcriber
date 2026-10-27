import SwiftUI
import SwiftData

/// Port of Android `recordings/RecordingDetailScreen.kt`.
struct DetailView: View {
    let recording: Recording
    var onClose: () -> Void = {}
    /// Seconds to open the player at (from the person page).
    var startAt: Double? = nil
    /// A person whose lines are marked (opened from their page).
    var focusName: String? = nil
    /// The Library search that found this recording: its words are marked
    /// in the transcript.
    var searchQuery: String = ""
    @State private var focus: String?
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
    /// Unnamed speakers still to go after the one being named ("Name them").
    @State private var namingQueue: [String] = []
    @State private var showingSplit = false
    @State private var findingPeople = false
    @State private var confirmingDelete = false
    /// Read on appear and on change, never per render: it is a file.
    @State private var hasPeople = false
    @State private var peopleNames: [String] = []
    @State private var savedPeople: [(id: UUID, name: String)] = []
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
        .confirmationDialog("Delete “\(recording.title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                // Same reasoning as the library's Delete: a run still
                // streaming into this recording must not outlive it.
                container.jobManager.cancel(recording.id)
                try? container.repository.delete(recording)
                onClose()
            }
        } message: {
            Text("The transcript, outputs and versions are removed from Transcriberr. The audio file stays on disk.")
        }
        .task(id: recording.id) {
            focus = focusName
            foldSpeakersIfIdle()
            // Another recording's Find people must not report here.
            findingPeople = false
            peopleNote = nil
            if model?.recording.id != recording.id {
                model = DetailModel(container: container, recording: recording)
                tab = .transcript
                peopleNote = nil
                proseMode = container.uiPrefs.proseMode
                showTimestamps = container.uiPrefs.showTimestamps
                transcriptStyle = container.uiPrefs.transcriptStyle
            }
        }
        // Skipped above while a run was queued or running: done once it ends
        // (finished, failed or cancelled), the page still open.
        .onChange(of: container.jobManager.isActive(recording.id)) { _, active in
            if !active { foldSpeakersIfIdle() }
        }
    }

    /// Recordings named before 5.0 may still show one person as two
    /// speakers of the same name. Not while a run for this recording is
    /// queued or running: its speakers are a draft the run replaces.
    private func foldSpeakersIfIdle() {
        guard !recording.isDeleted, recording.modelContext != nil,
              !container.jobManager.isActive(recording.id) else { return }
        if (try? container.repository.foldSameNamedSpeakers(in: recording)) ?? 0 > 0 {
            try? TranscriptExporter.export(recording: recording)
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
                PlayerBar(recording: recording, startAt: startAt)
                if !fullscreen { HairlineSoft() }
                tabContent(model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
            .onAppear { loadPeople() }
            .onReceive(NotificationCenter.default.publisher(for: PeopleStore.didChange)) { _ in loadPeople() }
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
                    container: container,
                    others: uniqueSpeakers().filter { $0.key != key },
                    hasNext: !namingQueue.isEmpty,
                    onCancel: { namingQueue = []; renamingSpeaker = nil }
                ) {
                    // Saved: on to the next unnamed speaker, if stepping through.
                    if namingQueue.isEmpty { renamingSpeaker = nil } else { renamingSpeaker = namingQueue.removeFirst() }
                }
                // A fresh sheet per speaker, or the name typed for the
                // previous one would carry over.
                .id(key)
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
            let words = wordsBySpeaker()
            let total = max(1, words.values.reduce(0, +))
            // Who still needs a name: anyone the diarizer found who says
            // enough to matter, never the microphone (that is the user).
            let unnamed = speakers.filter {
                $0.key != TranscriptionRunner.micSpeakerKey && isUnnamed($0) && (words[$0.key] ?? 0) >= 40
            }
            VStack(alignment: .leading, spacing: 0) {
                if !unnamed.isEmpty, !(model?.isRunning ?? false) {
                    HStack(spacing: AppMetric.s) {
                        Rectangle().fill(AppColor.accent).frame(width: 3, height: 14)
                        Text(unnamed.count == 1 ? "1 person in this meeting isn't named yet"
                             : "\(unnamed.count) people in this meeting aren't named yet")
                            .uiLabel(10)
                        Spacer()
                        TapButton {
                            namingQueue = Array(unnamed.dropFirst().map(\.key))
                            renamingSpeaker = unnamed.first?.key
                        } label: {
                            LitButtonChrome(.secondary, compact: true) {
                                Text(unnamed.count == 1 ? "Name them" : "Name all \(unnamed.count), one by one")
                            }
                        }
                        .help("Opens Who is this? for each unnamed speaker in turn: listen, pick a name (people on the invite come first) or type one, or skip.")
                    }
                    .padding(.horizontal, AppMetric.sheetPadding)
                    .padding(.vertical, 6)
                    .background(AppColor.accent.opacity(0.06))
                    HairlineSoft()
                }
                FlowLayout(spacing: 8) {
                    ForEach(speakers, id: \.key) { entry in
                        let named = !isUnnamed(entry)
                        let recognised = savedPerson(named: entry.display) != nil
                        let share = Int((100 * Double(words[entry.key] ?? 0) / Double(total)).rounded())
                        TapButton { namingQueue = []; renamingSpeaker = entry.key } label: {
                            HStack(spacing: 6) {
                                Rectangle()
                                    .fill(speakerColor(for: entry.key))
                                    .frame(width: 7, height: 7)
                                Text(named ? entry.display : "\(SpeakerLabel.display(nil, key: entry.key)) · who?")
                                    .uiLabel(10, color: named ? AppColor.ink : AppColor.accentOnLight)
                                if recognised {
                                    Text("✓").uiLabel(9, color: AppColor.statusSuccess)
                                        .accessibilityLabel("voice saved")
                                }
                                Text("\(share)%").uiLabel(9, color: AppColor.ink3)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.6)))
                        }
                        .help(recognised ? "\(entry.display): voice saved. Click to rename, listen, or open their page."
                              : named ? "\(entry.display): named, voice not saved yet. Click to save it."
                              : "Who is this? Click to listen and name them.")
                        .contextMenu {
                            if let person = savedPerson(named: entry.display) {
                                Button("Open \(person.name)'s page") {
                                    container.requestPeoplePane(person: person.id)
                                }
                                Divider()
                            }
                            // The last 10% of diarization errors are fixed by
                            // a human in two clicks, not by a better clusterer.
                            ForEach(speakers.filter { $0.key != entry.key }, id: \.key) { other in
                                Button("Same person as \(other.display)") {
                                    guard let repo = model?.container.repository else { return }
                                    try? repo.mergeSpeakers(
                                        entry.key, into: other.key, in: recording)
                                    // As the sheet's "Same person as…": the
                                    // transcript file must not keep two speakers.
                                    try? TranscriptExporter.export(recording: recording)
                                }
                            }
                        }
                    }
                    if hasPeople {
                        TapButton { findPeople() } label: {
                            Text(findingPeople ? "Finding people…" : (peopleNote ?? "Find saved people ↗"))
                                .uiLabel(9, color: findingPeople ? AppColor.ink3 : AppColor.accentOnLight)
                        }
                        // Not mid-run: the speakers it would name are about
                        // to be replaced by the run's own.
                        .disabled(model?.isRunning ?? false)
                        .help("Name this recording's speakers after the people saved in People, by voice.")
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

    private func loadPeople() {
        savedPeople = PeopleStore.shared.load().map { (id: $0.id, name: $0.name) }
        peopleNames = savedPeople.map(\.name)
        hasPeople = !peopleNames.isEmpty
    }

    /// One line's speaker, picked in the transcript.
    private func tag(_ seg: Segment, _ choice: TranscriptPane.TagChoice) {
        guard !seg.isDeleted, seg.modelContext != nil else { return }
        let repo = container.repository
        do {
            switch choice {
            case .speaker(let key): try repo.tagSegment(seg, toSpeaker: key, in: recording)
            case .name(let name): try repo.tagSegment(seg, as: name, in: recording)
            case .clear: try repo.untagSegment(seg, in: recording)
            case .someoneElse:
                let alert = NSAlert()
                alert.messageText = "Who said this?"
                alert.informativeText = "This line goes to a speaker of that name, or a new one."
                let field = NSTextField(string: "")
                field.placeholderString = "Name"
                field.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
                alert.accessoryView = field
                alert.addButton(withTitle: "Tag")
                alert.addButton(withTitle: "Cancel")
                alert.window.initialFirstResponder = field
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                try repo.tagSegment(seg, as: name, in: recording)
            }
            try? TranscriptExporter.export(recording: recording)
        } catch {
            AppLog.error("detail", "tag line failed: \(error.localizedDescription)")
        }
    }

    /// Saved people are matched after every run; this is for recordings
    /// made before a person was saved.
    private func findPeople() {
        guard !findingPeople, let repo = model?.container.repository else { return }
        findingPeople = true
        let id = recording.id
        Task { @MainActor in
            let rec = recording
            let named = await PeopleNamer.apply(to: rec, repository: repo)
            if named > 0, rec.modelContext != nil { try? TranscriptExporter.export(recording: rec) }
            // The user may have moved to another recording meanwhile: the
            // live model, not this view's captured `recording`, says which.
            guard model?.recording.id == id else { return }
            peopleNote = named == 0 ? "No saved person found ↗"
                : named == 1 ? "1 speaker named ↗" : "\(named) speakers named ↗"
            findingPeople = false
        }
    }

    /// The saved person a speaker is named after, if any.
    /// From the list read on appear: the chip menus are built on every
    /// render (once per chunk during a run), too often to read a file.
    private func savedPerson(named name: String) -> (id: UUID, name: String)? {
        savedPeople.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func uniqueSpeakers() -> [(key: String, display: String)] {
        var seen = [String: String]()
        var order: [String] = []
        for s in recording.segments {
            guard let key = s.speaker else { continue }
            if seen[key] == nil {
                seen[key] = SpeakerLabel.display(s.speakerName, key: key)
                order.append(key)
            }
        }
        return order.map { ($0, seen[$0] ?? $0) }
    }

    /// No name of its own: still "Speaker 2" or "Guest".
    private func isUnnamed(_ entry: (key: String, display: String)) -> Bool {
        let name = recording.segments.first { $0.speaker == entry.key }?.speakerName
        return name == nil || name!.isEmpty || name == entry.key || SpeakerLabel.isPlaceholder(name!)
    }

    /// Words each speaker said: the talk share on their chip.
    private func wordsBySpeaker() -> [String: Int] {
        var out: [String: Int] = [:]
        for s in recording.segments { if let k = s.speaker { out[k, default: 0] += s.text.split(separator: " ").count } }
        return out
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
        // Nothing to copy must not wipe the clipboard (an accessibility
        // press reaches this even where the click was blocked).
        guard hasTranscript else { return }
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
            .disabled(!hasTranscript)

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
                Button("Delete recording…", role: .destructive) { confirmingDelete = true }
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
            ForEach(allFolders.filter { $0.id != recording.folder?.id && !$0.isDictation }, id: \.id) { folder in
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
            if speakers > 0 { out.append(speakers == 1 ? "1 speaker" : "\(speakers) speakers") }
            let turns = recording.segments.count
            out.append(turns == 1 ? "1 turn" : "\(turns) turns")
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
                speakerChoices: uniqueSpeakers(),
                peopleNames: peopleNames,
                onTag: { seg, choice in tag(seg, choice) },
                onPickAlternative: { seg, k in pickAlternative(seg, disputeIndex: k) },
                speakerColor: { [order = uniqueSpeakers().map(\.key)] key in
                    // Precomputed ONCE per render — calling uniqueSpeakers()
                    // per row walked the SwiftData segments relationship
                    // hundreds of times mid-update and segfaulted SwiftData.
                    SpeakerPalette.colors[(order.firstIndex(of: key) ?? 0) % SpeakerPalette.colors.count]
                },
                focusName: focus,
                onClearFocus: { focus = nil },
                searchQuery: searchQuery
            )
        case .output(let presetId, _):
            // Its own identity per preset and recording: History open on
            // Summary must not carry over to Minutes or another recording.
            OutputPane(model: model, presetId: presetId)
                .id("\(presetId)-\(recording.id)")
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
    @State private var expandedId: UUID?
    @State private var deletingVersion: TranscriptVersion?

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
        .confirmationDialog("Delete this version?",
                            isPresented: Binding(get: { deletingVersion != nil }, set: { if !$0 { deletingVersion = nil } }),
                            titleVisibility: .visible, presenting: deletingVersion) { v in
            Button("Delete", role: .destructive) {
                expandedId = nil
                guard !model.recording.isDeleted else { return }
                try? model.container.repository.deleteVersion(v, from: model.recording)
            }
        } message: { _ in
            Text("This saved transcript is removed. The current transcript stays as it is.")
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
                    // A run in flight writes into the current transcript: a
                    // restore now would be mixed with it or overwritten.
                    .disabled(model.isRunning)
                    .help(model.isRunning ? "Wait for the run to finish, then restore." : "")
                    TapButton { deletingVersion = v } label: {
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
    /// Who said a line, picked on the line itself (its speaker name is a
    /// menu, and so is a right-click on it).
    enum TagChoice { case speaker(String), name(String), someoneElse, clear }
    var speakerChoices: [(key: String, display: String)] = []
    var peopleNames: [String] = []
    var onTag: (Segment, TagChoice) -> Void = { _, _ in }
    /// The user clicked a disputed word: switch it to the other engine's
    /// reading (the Int is the dispute's index in `recording.disputesJSON`).
    var onPickAlternative: (Segment, Int) -> Void = { _, _ in }
    var speakerColor: (String) -> Color = { _ in SpeakerPalette.colors[0] }
    /// A person whose lines are marked, with a bar to step through them.
    var focusName: String? = nil
    var onClearFocus: () -> Void = {}
    /// The Library search that found this recording: its matches are
    /// marked, the first one is scrolled to, and a bar steps through them.
    var searchQuery: String = ""
    /// Lines that contain the search, in order (computed once per query
    /// and text, not on every playhead tick).
    @State private var searchHits: [UUID] = []
    /// No shown line has it, but the raw text does: the Clean view left the
    /// words out (the Library searches the raw transcript).
    @State private var searchOnlyRaw = false
    @State private var searchPosition = 0
    @State private var searchTarget: UUID?
    /// The query the user hid the marks for.
    @State private var hiddenQuery: String?
    private var activeQuery: String {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return q == hiddenQuery ? "" : q
    }

    private func isFocused(_ seg: Segment) -> Bool {
        guard let focusName else { return false }
        return seg.speakerName?.caseInsensitiveCompare(focusName) == .orderedSame
    }

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
    /// The line playing now: the latest to start among those that contain
    /// the playhead, so none is lit in a silence or after the last line.
    private func activeID(in segs: [Segment]) -> UUID? {
        let t = player.currentTime
        return segs.last { t >= $0.startSeconds && t <= $0.endSeconds + 0.25 }?.id
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
            if let focusName {
                focusBar(focusName, starts: segs.filter(isFocused).map(\.startSeconds))
                HairlineSoft()
            }
            if !activeQuery.isEmpty {
                searchBar(activeQuery)
                HairlineSoft()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // One playing line: the latest to start. Padded mic lines
                        // overlap the call's, and "contains the playhead" lit
                        // up to three rows at once.
                        let playing = activeID(in: segs)
                        ForEach(segs, id: \.id) { seg in
                            HairlineSoft()
                            segmentRow(seg, disputes: disputeRows[seg.id], active: seg.id == playing).id(seg.id)
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
                .task(id: SearchKey(query: activeQuery, texts: disputeKey(segs).texts)) {
                    let q = activeQuery
                    let segs = sortedSegments
                    let hits = q.isEmpty ? [] : segs.filter { SearchHighlight.matches(q, style.apply($0.text)) }.map(\.id)
                    let first = hits.first != searchHits.first || searchHits.isEmpty
                    searchHits = hits
                    searchOnlyRaw = !q.isEmpty && hits.isEmpty && segs.contains { SearchHighlight.matches(q, $0.text) }
                    if first {
                        searchPosition = 0
                        searchTarget = hits.first
                    }
                }
                .onChange(of: searchTarget) { _, target in
                    // First match on open, then Previous / Next.
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
                }
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
        let found = activeQuery.isEmpty ? [] : SearchHighlight.ranges(of: activeQuery, in: shown)
        // Stale cache (the text changed since the scan): no dispute marks
        // this frame; the scan re-runs because the key changed.
        let hits = (disputes.map { $0.text == shown } ?? false) ? disputes!.hits : []
        guard !hits.isEmpty || !found.isEmpty else { return Text(shown) }
        var attr = AttributedString(shown)
        for r in found {
            guard let range = Range(r, in: attr) else { continue }
            attr[range].backgroundColor = AppColor.accent.opacity(0.28)
        }
        for hit in hits {
            guard let r = Range(hit.range, in: attr),
                  let url = URL(string: "transcriberr-dispute:\(hit.index)") else { continue }
            attr[r].link = url
            attr[r].underlineStyle = Text.LineStyle(pattern: .dot, color: AppColor.accentOnLight)
        }
        return Text(attr)
    }

    private func segmentRow(_ seg: Segment, disputes: DisputeRow? = nil, active: Bool) -> some View {
        let hits = disputes?.hits ?? []
        let focused = isFocused(seg)
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
                Menu {
                    tagMenu(seg)
                } label: {
                    if seg.speakerName != nil || seg.speaker != nil {
                        HStack(spacing: 6) {
                            Rectangle().fill(speakerColor(seg.speaker ?? "")).frame(width: 5, height: 5)
                            Text(SpeakerLabel.display(seg.speakerName, key: seg.speaker ?? "")).uiLabel(9, color: AppColor.accentOnLight)
                        }
                    } else {
                        Text("Who said this?").uiLabel(9, color: AppColor.ink3)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Tag who said this line")
                segmentText(seg, disputes: disputes)
                    .font(AppFont.text(15))
                    // Everyone else steps back while one person is marked.
                    .foregroundStyle(focusName == nil || focused ? AppColor.ink : AppColor.ink3)
                    .tint(AppColor.ink)
                    // Not selectable: on macOS a selectable Text takes the
                    // mouse-down for itself, so a click on the words started
                    // a selection and never reached the row's seek — only
                    // clicks on the margin jumped the audio. Copy is in the
                    // context menu; the prose view stays selectable.
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
        .padding(.horizontal, focused ? 8 : 2)
        .background(active ? AppColor.accent.opacity(0.16) : focused ? AppColor.accent.opacity(0.07) : Color.clear)
        .overlay(alignment: .leading) {
            if focused { Rectangle().fill(AppColor.accent).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onTapGesture { player.seek(to: seg.startSeconds) }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in onEditSegment(seg) })
        .contextMenu {
            tagMenu(seg)
            Divider()
            Button("Copy line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(style.apply(seg.text), forType: .string)
            }
            Button("Edit text…") { onEditSegment(seg) }
        }
    }

    /// "Lana's lines are marked": how many, and a way to step through them
    /// (the transcript follows the playhead) or show everyone again.
    private func focusBar(_ name: String, starts: [Double]) -> some View {
        HStack(spacing: AppMetric.m) {
            Rectangle().fill(AppColor.accent).frame(width: 3, height: 14)
            Text("\(name)'s lines are marked").uiLabel(10)
            Text(starts.count == 1 ? "1 line" : "\(starts.count) lines").uiLabel(9, color: AppColor.ink3)
            Spacer()
            TapButton { jump(in: starts, forward: false) } label: {
                LitButtonChrome(.ghost, compact: true) { Text("Previous") }
            }
            .disabled(starts.isEmpty)
            TapButton { jump(in: starts, forward: true) } label: {
                LitButtonChrome(.ghost, compact: true) { Text("Next") }
            }
            .disabled(starts.isEmpty)
            TapButton { onClearFocus() } label: {
                LitButtonChrome(.secondary, compact: true) { Text("Show all") }
            }
            .help("Stop marking \(name)'s lines")
        }
        .padding(.horizontal, AppMetric.sheetPadding)
        .padding(.vertical, 6)
        .background(AppColor.base)
    }

    private struct SearchKey: Hashable { let query: String; let texts: [Int] }

    private func searchBar(_ query: String) -> some View {
        let count = searchHits.count
        return HStack(spacing: AppMetric.m) {
            Rectangle().fill(AppColor.accent).frame(width: 3, height: 14)
            Text(count > 0 ? "“\(query)” in \(count == 1 ? "1 line" : "\(count) lines")"
                 : searchOnlyRaw ? "“\(query)” is only in words the Clean view leaves out: turn Clean off to see it"
                 : "No line here contains “\(query)”").uiLabel(10)
            if count > 1 {
                Text("\(searchPosition + 1) of \(count)").uiLabel(9, color: AppColor.ink3)
            }
            Spacer()
            TapButton { stepSearch(forward: false) } label: {
                LitButtonChrome(.ghost, compact: true) { Text("Previous") }
            }
            .disabled(count < 2)
            TapButton { stepSearch(forward: true) } label: {
                LitButtonChrome(.ghost, compact: true) { Text("Next") }
            }
            .disabled(count < 2)
            TapButton { hiddenQuery = query } label: {
                LitButtonChrome(.secondary, compact: true) { Text("Hide") }
            }
            .help("Stop marking “\(query)”")
        }
        .padding(.horizontal, AppMetric.sheetPadding)
        .padding(.vertical, 6)
        .background(AppColor.base)
    }

    private func stepSearch(forward: Bool) {
        guard !searchHits.isEmpty else { return }
        let n = searchHits.count
        searchPosition = (searchPosition + (forward ? 1 : n - 1)) % n
        // Re-set even when unchanged, so the same line scrolls back into view.
        searchTarget = nil
        DispatchQueue.main.async { searchTarget = searchHits[searchPosition] }
    }

    private func jump(in starts: [Double], forward: Bool) {
        let now = player.currentTime
        let target = forward
            ? starts.first { $0 > now + 0.5 } ?? starts.first
            : starts.last { $0 < now - 0.5 } ?? starts.last
        if let target { player.seek(to: target) }
    }

    /// The speakers of this recording, then saved people who are not one of
    /// them yet, then a new name.
    @ViewBuilder
    private func tagMenu(_ seg: Segment) -> some View {
        Section("Who said this?") {
            ForEach(speakerChoices, id: \.key) { choice in
                Button {
                    onTag(seg, .speaker(choice.key))
                } label: {
                    if choice.key == seg.speaker {
                        Label(choice.display, systemImage: "checkmark")
                    } else {
                        Text(choice.display)
                    }
                }
            }
        }
        let present = Set(speakerChoices.map { $0.display.lowercased() })
        let others = peopleNames.filter { !present.contains($0.lowercased()) }
        if !others.isEmpty {
            Section("Saved people") {
                ForEach(others, id: \.self) { name in
                    Button(name) { onTag(seg, .name(name)) }
                }
            }
        }
        Button("Someone else…") { onTag(seg, .someoneElse) }
        if seg.speaker != nil {
            Divider()
            Button("Remove speaker") { onTag(seg, .clear) }
        }
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
