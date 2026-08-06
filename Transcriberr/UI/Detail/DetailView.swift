import SwiftUI

/// Editorial port of Android `recordings/RecordingDetailScreen.kt`.
struct DetailView: View {
    let recording: Recording
    var onClose: () -> Void = {}
    @Environment(AppContainer.self) private var container

    @State private var model: DetailModel?
    @State private var tab: Tab = .transcript
    @State private var proseMode = false
    @State private var showTimestamps = true
    @State private var fullscreen = false
    @State private var runExpanded = false
    @State private var editingSegment: Segment?
    @State private var renamingSpeaker: String?

    enum Tab: String, CaseIterable, Identifiable {
        case transcript, summary, clean, translate, context, versions
        var id: String { rawValue }
        var label: String {
            switch self {
            case .transcript: return "TRANSCRIPT"
            case .summary:    return "SUMMARY"
            case .clean:      return "CLEAN"
            case .translate:  return "TRANSLATE"
            case .context:    return "CONTEXT-REWRITE"
            case .versions:   return "VERSIONS"
            }
        }
        var presetId: String {
            switch self {
            case .transcript, .versions: return ""
            case .summary:    return "summary"
            case .clean:      return "clean"
            case .translate:  return "translate_polish"
            case .context:    return "context_rewrite"
            }
        }
    }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                Sheet { ProgressView().padding() }
            }
        }
        .task(id: recording.id) {
            if model?.recording.id != recording.id {
                model = DetailModel(container: container, recording: recording)
                tab = .transcript
                proseMode = container.uiPrefs.proseMode
                showTimestamps = container.uiPrefs.showTimestamps
            }
        }
    }

    @ViewBuilder
    private func content(_ model: DetailModel) -> some View {
        Sheet {
            VStack(alignment: .leading, spacing: 0) {
                topRow()
                if !fullscreen {
                    headerBlock(model)
                    runStrip(model)
                    speakerChipRow()
                }
                tabStrip()
                PlayerBar(recording: recording)
                if !fullscreen { HairlineSoft() }
                tabContent(model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                                Text(entry.display.uppercased())
                                    .monoLabel(9, color: AppColor.ink)
                            }
                        }

                    }
                    Text("RENAME ↗").monoLabel(9, color: AppColor.inkMuted)
                }
                .padding(.horizontal, AppMetric.sheetPadding)
                .padding(.vertical, 8)
                HairlineSoft()
            }
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

    static let speakerPalette: [Color] = [
        AppColor.accent,
        Color(red: 0.45, green: 0.60, blue: 0.50),  // sage
        Color(red: 0.40, green: 0.52, blue: 0.72),  // slate blue
        Color(red: 0.65, green: 0.45, blue: 0.62),  // plum
        Color(red: 0.78, green: 0.62, blue: 0.30),  // amber
        Color(red: 0.55, green: 0.55, blue: 0.55),  // gray
    ]

    /// First-appearance order, NOT hashValue (seed-randomized per launch).
    /// Callers that render many rows must precompute the order once — see
    /// tabContent — instead of calling this per row.
    private func speakerColor(for key: String) -> Color {
        let idx = uniqueSpeakers().firstIndex { $0.key == key } ?? 0
        return Self.speakerPalette[idx % Self.speakerPalette.count]
    }

    // MARK: - Copy / Share / Rename

    private func copyTranscript() {
        let body = recording.segments
            .sorted { $0.startSeconds < $1.startSeconds }
            .map { seg -> String in
                if let name = seg.speakerName ?? seg.speaker {
                    return "\(name): \(seg.text)"
                }
                return seg.text
            }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
    }

    private func shareTranscript() {
        let body = recording.segments
            .sorted { $0.startSeconds < $1.startSeconds }
            .map { seg -> String in
                if let name = seg.speakerName ?? seg.speaker {
                    return "\(name): \(seg.text)"
                }
                return seg.text
            }
            .joined(separator: "\n")
        presentSharePicker(items: [body])
    }

    /// Sidecar kinds for the SHARE ↗ menu.
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
            }
        }
    }

    // MARK: - Top row

    @ViewBuilder
    private func topRow() -> some View {
        HStack(spacing: AppMetric.m) {
            TapButton { onClose() } label: {
                Text("← CLOSE")
                    .monoLabel(11, color: AppColor.inkSoft)
            }

            Spacer()

            // Quick actions, always visible (no menu hunt).
            TapButton { copyTranscript() } label: {
                Text("COPY")
                    .monoLabel(10, color: hasTranscript ? AppColor.ink : AppColor.inkMuted)
                    .padding(.horizontal, AppMetric.s)
                    .padding(.vertical, 4)
                    .overlay(Rectangle().stroke(
                        hasTranscript ? AppColor.hairline : AppColor.hairlineSoft,
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
            } label: {
                Text("SHARE ↗")
                    .monoLabel(10, color: hasTranscript ? AppColor.accent : AppColor.inkMuted)
                    .padding(.horizontal, AppMetric.s)
                    .padding(.vertical, 4)
                    .overlay(Rectangle().stroke(
                        hasTranscript ? AppColor.accent.opacity(0.6) : AppColor.hairlineSoft,
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
                Divider()
                Button("Rename recording…") {
                    renameRecordingPrompt()
                }
                Button("Delete recording", role: .destructive) {
                    try? container.repository.delete(recording)
                    onClose()
                }
            } label: {
                Text("MORE ⋯").monoLabel(11, color: AppColor.inkSoft)
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
                Text("03 / ").monoLabel(11, color: AppColor.accent)
                Text("SESSION").monoLabel(11, color: AppColor.ink)
                Spacer()
            }
            .padding(.horizontal, AppMetric.sheetPadding)

            Spacer().frame(height: AppMetric.s)

            Text(recording.title)
                .font(AppFont.fraunces(26))
                .lineSpacing(4)
                .tracking(-0.38)
                .foregroundStyle(AppColor.ink)
                .padding(.horizontal, AppMetric.sheetPadding)

            Spacer().frame(height: AppMetric.m)
            HairlineSoft()
            Spacer().frame(height: AppMetric.s)

            metadataStrip()
                .padding(.horizontal, AppMetric.sheetPadding)

            Spacer().frame(height: AppMetric.s)
            HairlineSoft()
            Spacer().frame(height: AppMetric.m)
        }
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
                out.append(b.uppercased())
            }
            if let lang = recording.sourceLanguage, !lang.isEmpty {
                out.append(lang.uppercased())
            }
            let speakers = Set(recording.segments.compactMap { $0.speaker }).count
            if speakers > 0 { out.append("\(speakers) SPEAKERS") }
            out.append("\(recording.segments.count) TURNS")
            return out
        }()
        HStack(spacing: 6) {
            ForEach(Array(bits.enumerated()), id: \.offset) { (i, t) in
                if i > 0 {
                    Text("·").monoLabel(9, color: AppColor.inkMuted)
                }
                Text(t).monoLabel(9, color: AppColor.inkSoft)
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
                    Text(runExpanded ? "RUN ▾" : "RUN ▸").monoLabel(11, color: AppColor.ink)
                    Text(runSummary(m)).monoLabel(10, color: AppColor.inkSoft)
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
                    Text(err.uppercased()).monoLabel(9, color: AppColor.accent)
                    Spacer()
                }
                .padding(.horizontal, AppMetric.sheetPadding)
                .padding(.vertical, 6)
                .background(AppColor.paperEdge)
            }

            runStatusBar(m)

            HairlineSoft()
        }
    }

    private func runSummary(_ m: DetailModel) -> String {
        var parts: [String] = [m.backend.displayName.uppercased()]
        parts.append(m.languages.isEmpty ? "AUTO LANG" : m.languages.sorted().joined(separator: ",").uppercased())
        if m.translateToEnglish { parts.append("→ ENGLISH") }
        if m.diarize { parts.append(m.hybridDiarize ? "HYBRID DIAR" : "DIAR") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func runOptionsBlock(_ m: DetailModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HairlineSoft()
            LedgerRow("ENGINE") {
                Picker("", selection: Binding(
                    get: { m.backend }, set: { m.backend = $0 }
                )) {
                    ForEach(BackendFactory.Kind.allCases.filter(\.supportsAudio), id: \.rawValue) { k in
                        Text(k.displayName).tag(k)
                    }
                }
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
                LedgerRow("MERGE A") {
                    Picker("", selection: Binding(
                        get: { m.container.uiPrefs.ensembleEngineA },
                        set: { newValue in
                            // Keep A ≠ B (same swap policy as Settings → Engines).
                            if newValue == m.container.uiPrefs.ensembleEngineB {
                                m.container.uiPrefs.ensembleEngineB = m.container.uiPrefs.ensembleEngineA
                            }
                            m.container.uiPrefs.ensembleEngineA = newValue
                        }
                    )) {
                        ForEach(mergeOptions, id: \.rawValue) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                HairlineSoft()
                LedgerRow("MERGE B") {
                    Picker("", selection: Binding(
                        get: { m.container.uiPrefs.ensembleEngineB },
                        set: { newValue in
                            if newValue == m.container.uiPrefs.ensembleEngineA {
                                m.container.uiPrefs.ensembleEngineA = m.container.uiPrefs.ensembleEngineB
                            }
                            m.container.uiPrefs.ensembleEngineB = newValue
                        }
                    )) {
                        ForEach(mergeOptions, id: \.rawValue) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                HairlineSoft()
                Text("RUNS BOTH ENGINES PER CHUNK · WORD-LEVEL CONFIDENCE MERGE · GEMMA ARBITRATES HARD CONFLICTS · ALL LOCAL")
                    .monoLabel(9, color: AppColor.inkSoft)
                    .padding(.horizontal, AppMetric.sheetPadding)
                    .padding(.vertical, 6)
                HairlineSoft()
            }
            LedgerRow("LANG") {
                HStack(spacing: AppMetric.s) {
                    languagePill("AUTO", isOn: m.languages.isEmpty) {
                        m.languages.removeAll()
                    }
                    ForEach(supportedLanguages, id: \.self) { lang in
                        languagePill(lang.uppercased(),
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
            LedgerRow("DIARIZE") {
                Toggle("", isOn: Binding(
                    get: { m.diarize }, set: { m.diarize = $0 }
                ))
                .labelsHidden()
            }
            HairlineSoft()
            if m.diarize {
                LedgerRow("SPEAKERS") {
                    Stepper(
                        m.expectedSpeakers == 0 ? "Auto-detect" : "\(m.expectedSpeakers)",
                        value: Binding(get: { m.expectedSpeakers }, set: { m.expectedSpeakers = $0 }),
                        in: 0...8
                    )
                    .frame(maxWidth: 200, alignment: .leading)
                }
                HairlineSoft()
            }
            if m.diarize && !m.backend.needsDiarizerForSpeakers {
                LedgerRow("HYBRID") {
                    Toggle("", isOn: Binding(
                        get: { m.hybridDiarize }, set: { m.hybridDiarize = $0 }
                    ))
                    .labelsHidden()
                }
                HairlineSoft()
            }
            LedgerRow("TRANSLATE") {
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
                .monoLabel(9, color: isOn ? AppColor.paper : AppColor.ink)
                .padding(.horizontal, AppMetric.s)
                .padding(.vertical, 4)
                .background(isOn ? AppColor.ink : Color.clear)
                .overlay(
                    Rectangle()
                        .stroke(AppColor.hairline, lineWidth: isOn ? 0 : 1)
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
                    Text(s.stage.uppercased())
                        .monoLabel(9, color: AppColor.paper.opacity(0.75))
                    Spacer()
                    // TapButton, not Button — Button's _ButtonGesture
                    // crashes on macOS 26.5 when the action captures a
                    // @MainActor @Observable model (DetailModel here).
                    TapButton { m.cancel() } label: {
                        Text("CANCEL")
                            .foregroundStyle(AppColor.paper)
                            .font(AppFont.mono(9))
                    }
                }
            }
            .padding(.horizontal, AppMetric.sheetPadding)
            .padding(.vertical, 10)
            .background(AppColor.ink)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let s = m.status, s.failed {
                    Text(s.stage.uppercased())
                        .monoLabel(9, color: AppColor.accent)
                        .padding(.horizontal, AppMetric.sheetPadding)
                        .padding(.top, 8)
                }
                // TapButton, not Button — see note above (m.run() captures
                // the @MainActor @Observable DetailModel → _ButtonGesture crash).
                TapButton { m.run() } label: {
                    HStack {
                        PulseDot(diameter: 6)
                        Text(m.status == nil ? "Run Transcription" : "Re-run Transcription")
                            .font(AppFont.saira(15, weight: .semibold))
                            .tracking(0.4)
                            .textCase(.uppercase)
                            .foregroundStyle(AppColor.paper)
                        Spacer()
                        Text("→").font(AppFont.saira(20, weight: .semibold))
                            .foregroundStyle(AppColor.accent)
                    }
                    .padding(.horizontal, AppMetric.sheetPadding)
                    .padding(.vertical, 10)
                }
            }
            .background(AppColor.ink)
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
                        ForEach(Tab.allCases) { t in
                            TapButton { tab = t } label: {
                                VStack(spacing: 4) {
                                    Text(t.label).monoLabel(10, color: tab == t ? AppColor.ink : AppColor.inkSoft)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 10)
                                    Rectangle()
                                        .fill(tab == t ? AppColor.accent : Color.clear)
                                        .frame(width: 28, height: 1.5)
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: AppMetric.s)
                if tab == .transcript {
                    TapButton {
                        proseMode.toggle()
                        container.uiPrefs.proseMode = proseMode
                    } label: {
                        Text(proseMode ? "CARDS" : "PROSE").monoLabel(9, color: AppColor.inkSoft)
                    }
                    TapButton {
                        showTimestamps.toggle()
                        container.uiPrefs.showTimestamps = showTimestamps
                    } label: {
                        Text(showTimestamps ? "—TIMES" : "+TIMES").monoLabel(9, color: AppColor.inkSoft)
                    }
                    TapButton { fullscreen.toggle() } label: {
                        Text(fullscreen ? "EXIT ⤡" : "READ ⤢")
                            .monoLabel(9, color: fullscreen ? AppColor.accent : AppColor.inkSoft)
                    }
                }
            }
            .padding(.horizontal, AppMetric.sheetPadding)
            HairlineSoft()
        }
    }

    @ViewBuilder
    private func tabContent(_ model: DetailModel) -> some View {
        switch tab {
        case .transcript:
            TranscriptPane(
                recording: recording,
                player: model.container.audioPlayer,
                proseMode: proseMode,
                showTimestamps: showTimestamps,
                isRunning: model.isRunning,
                runStage: model.status?.stage,
                onEditSegment: { editingSegment = $0 },
                speakerColor: { [order = uniqueSpeakers().map(\.key)] key in
                    // Precomputed ONCE per render — calling uniqueSpeakers()
                    // per row walked the SwiftData segments relationship
                    // hundreds of times mid-update and segfaulted SwiftData.
                    Self.speakerPalette[(order.firstIndex(of: key) ?? 0) % Self.speakerPalette.count]
                }
            )
        case .summary, .clean, .translate, .context:
            OutputPane(model: model, presetId: tab.presetId)
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
                    Text("NO SAVED VERSIONS YET · EVERY COMPLETED RUN IS SNAPSHOTTED HERE")
                        .monoLabel(10, color: AppColor.inkSoft)
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
                        Text(v.engineLabel.uppercased())
                            .monoLabel(10, color: AppColor.ink)
                        Text("\(Self.dateFormatter.string(from: Date(timeIntervalSince1970: Double(v.createdAtMillis) / 1000))) · \(v.segmentCount) SEGMENTS")
                            .monoLabel(9, color: AppColor.inkSoft)
                    }
                    Spacer()
                    Text(isOpen ? "▾" : "▸")
                        .monoLabel(10, color: AppColor.inkMuted)
                }
                .contentShape(Rectangle())
            }

            if isOpen {
                let segs = model.container.repository.decodeVersion(v)
                Text(segs.map { seg in
                    let name = seg.speakerName ?? seg.speaker
                    return name.map { "\($0): \(seg.text)" } ?? seg.text
                }.joined(separator: "\n\n"))
                    .font(AppFont.fraunces(15))
                    .lineSpacing(4)
                    .foregroundStyle(AppColor.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: AppMetric.l) {
                    TapButton {
                        // Restore through the VIEW's context — the repository
                        // context is a parallel world; mutating view-context
                        // objects there is a silent no-op (same as the old
                        // delete bug).
                        let segs = model.container.repository.decodeVersion(v)
                        let names = model.container.repository.storedSpeakerNames(model.recording)
                        for old in model.recording.segments { context.delete(old) }
                        model.recording.segments = []
                        for raw in segs {
                            let seg = Segment(
                                startSeconds: raw.start, endSeconds: raw.end, text: raw.text,
                                speaker: raw.speaker,
                                speakerName: raw.speakerName ?? raw.speaker.flatMap { names[$0] }
                            )
                            seg.recording = model.recording
                            context.insert(seg)
                            model.recording.segments.append(seg)
                        }
                        try? context.save()
                    } label: {
                        Text("RESTORE AS CURRENT")
                            .monoLabel(9, color: AppColor.accent)
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
                        Text("DELETE")
                            .monoLabel(9, color: AppColor.inkSoft)
                            .padding(.horizontal, AppMetric.s)
                            .padding(.vertical, 4)
                            .overlay(Rectangle().stroke(AppColor.hairline, lineWidth: 1))
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, AppMetric.sheetPadding)
        .padding(.vertical, AppMetric.s)
    }

    private static let dateFormatter: DateFormatter = {
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
    var isRunning: Bool = false
    var runStage: String? = nil
    var onEditSegment: (Segment) -> Void = { _ in }
    var speakerColor: (String) -> Color = { _ in AppColor.accent }

    /// Last segment ID that contains the current playhead — used to auto-scroll.
    private var activeID: UUID? {
        recording.segments
            .sorted { $0.startSeconds < $1.startSeconds }
            .last { player.currentTime >= $0.startSeconds }?
            .id
    }

    /// ID of the most recently transcribed segment — for live auto-scroll.
    private var tailID: UUID? {
        recording.segments
            .sorted { $0.startSeconds < $1.startSeconds }
            .last?
            .id
    }

    var body: some View {
        if recording.segments.isEmpty {
            VStack(alignment: .center, spacing: AppMetric.s) {
                Spacer()
                if isRunning {
                    PulseDot(diameter: 8)
                    Text("TRANSCRIBING…")
                        .monoLabel(11, color: AppColor.accent)
                    if let stage = runStage {
                        Text(stage)
                            .font(AppFont.fraunces(15, italic: true))
                            .foregroundStyle(AppColor.inkSoft)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    Text("NO TRANSCRIPT YET · PRESS RUN ABOVE")
                        .monoLabel(11, color: AppColor.inkMuted)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(AppMetric.xl)
        } else if proseMode {
            ScrollView {
                Text(proseBody)
                    .font(AppFont.fraunces(16, italic: false))
                    .lineSpacing(6)
                    .foregroundStyle(AppColor.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, AppMetric.sheetPadding)
                    .padding(.vertical, AppMetric.l)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let segs = recording.segments.sorted { $0.startSeconds < $1.startSeconds }
                        ForEach(segs, id: \.id) { seg in
                            HairlineSoft()
                            segmentRow(seg).id(seg.id)
                        }
                        HairlineSoft()
                        // Sentinel so we can scroll just past the last row.
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .padding(.horizontal, AppMetric.sheetPadding)
                }
                .onChange(of: tailID) { _, new in
                    // New chunk arrived → scroll to bottom.
                    guard let new else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(new, anchor: .bottom)
                    }
                }
                .onChange(of: activeID) { _, new in
                    // Playback advanced → follow the active segment.
                    guard let new else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
    }

    private var proseBody: String {
        let segs = recording.segments.sorted { $0.startSeconds < $1.startSeconds }
        var prev: String? = nil
        var lines: [String] = []
        for seg in segs {
            let name = seg.speakerName ?? seg.speaker
            if let name, name != prev {
                lines.append("\n\(name): \(seg.text)")
                prev = name
            } else {
                lines.append(seg.text)
            }
        }
        return lines.joined(separator: " ")
    }

    private func segmentRow(_ seg: Segment) -> some View {
        let active = player.currentTime >= seg.startSeconds && player.currentTime <= seg.endSeconds
        return HStack(alignment: .top, spacing: AppMetric.s) {
            VStack(alignment: .leading, spacing: 1) {
                if showTimestamps {
                    Text(timestamp(seg.startSeconds))
                        .monoLabel(9, color: AppColor.inkSoft)
                }
                if let lang = seg.language, !lang.isEmpty {
                    Text(lang.uppercased()).monoLabel(8, color: AppColor.inkMuted)
                }
            }
            .frame(width: 46, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                if let name = seg.speakerName ?? seg.speaker {
                    HStack(spacing: 6) {
                        Rectangle().fill(speakerColor(seg.speaker ?? "")).frame(width: 5, height: 5)
                        Text(name).monoLabel(9, color: AppColor.accent)
                    }
                }
                Text(seg.text)
                    .font(AppFont.inter(15))
                    .foregroundStyle(AppColor.ink)
                    .textSelection(.enabled)
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
                    Text("QUEUED — WAITING FOR PREVIOUS GENERATION…")
                        .monoLabel(10, color: AppColor.inkSoft)
                case .loading:
                    PulseDot(diameter: 6)
                    Text("LOADING TEXT MODEL…").monoLabel(10, color: AppColor.inkSoft)
                case .running:
                    PulseDot(diameter: 6)
                    Text("GENERATING… LONG TRANSCRIPTS TAKE MINUTES")
                        .monoLabel(10, color: AppColor.inkSoft)
                case .failed(let reason):
                    Text("FAILED: \(reason.uppercased())")
                        .monoLabel(9, color: AppColor.accent)
                        .lineLimit(2)
                case .idle, .done:
                    EmptyView()
                }
                Spacer()
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
                    Text(isBusy ? "WORKING…" : "GENERATE ↗")
                        .monoLabel(10, color: isBusy ? AppColor.inkMuted : AppColor.accent)
                }
            }
            .padding(.horizontal, AppMetric.sheetPadding)
            .padding(.vertical, 10)
            HairlineSoft()

            if let doc {
                ScrollView {
                    Text(LocalizedStringKey(doc.markdown))
                        .font(AppFont.fraunces(16, italic: false))
                        .lineSpacing(6)
                        .foregroundStyle(AppColor.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(AppMetric.sheetPadding)
                }
            } else {
                VStack(alignment: .leading) {
                    Spacer()
                    Text("NOT GENERATED YET · PRESS GENERATE ↗ ABOVE")
                        .monoLabel(11, color: AppColor.inkMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer()
                }
                .padding(AppMetric.xl)
            }
        }
    }
}
