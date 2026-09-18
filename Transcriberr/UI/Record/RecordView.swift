import SwiftUI

/// Port of Android `record/RecordScreen.kt`.
struct RecordView: View {
    @Environment(AppContainer.self) private var container
    /// Owned by AppShell (app lifetime), NOT a view-scoped @State: this view
    /// is torn down every time the sidebar switches sections, and a model
    /// that died with it forgot an in-progress recording — coming back
    /// mid-recording showed an idle screen with no Stop button and no live
    /// captions while the recorder kept running underneath.
    let model: RecordModel

    var body: some View {
        content(model)
            .task { await consumePendingNewRecording() }
            .onChange(of: container.newRecordingRequested) { _, _ in
                Task { @MainActor in await consumePendingNewRecording() }
            }
    }

    /// ⌘N while already on this screen (onChange) or arriving here because
    /// of it (task) — either way, start a recording if nothing is running.
    private func consumePendingNewRecording() async {
        guard container.pendingNewRecording else { return }
        container.pendingNewRecording = false
        switch model.uiState {
        case .idle, .finished: await model.toggleRecord()
        case .recording, .paused: break
        }
    }

    @ViewBuilder
    private func content(_ model: RecordModel) -> some View {
        Sheet {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    BrandStrip {
                        recordingBadge(model.uiState)
                    }
                    .padding(.horizontal, AppMetric.sheetPadding)
                    .padding(.top, AppMetric.sheetVerticalPadding)

                    Spacer().frame(height: AppMetric.sheetVerticalPadding)
                    InkRule()
                    Spacer().frame(height: AppMetric.l)

                    SectionIndex(2, "Capture",
                                 summary: liveSummary(model))
                        .padding(.horizontal, AppMetric.sheetPadding)

                    Spacer().frame(height: AppMetric.l)

                    optionsRow(model)
                        .padding(.horizontal, AppMetric.sheetPadding)

                    Spacer().frame(height: AppMetric.m)
                    HairlineSoft()
                    Spacer().frame(height: AppMetric.m)

                    timerStrip(model)
                    waveform(model)
                    waveformAxis(model)

                    Spacer().frame(height: AppMetric.l)
                    HairlineSoft()
                    Spacer().frame(height: AppMetric.m)

                    lastHeardCard(model)
                        .padding(.horizontal, AppMetric.sheetPadding)

                    Spacer().frame(height: AppMetric.xl)
                }
            }

            if let err = model.lastError {
                HStack {
                    Text(err).uiLabel(9, color: AppColor.statusError)
                    Spacer()
                }
                .padding(.horizontal, AppMetric.sheetPadding)
                .padding(.vertical, 6)
                .background(AppColor.baseDeep)
            }
            recordFooter(model)
        }
    }

    // MARK: - Top right badge

    @ViewBuilder
    private func recordingBadge(_ state: RecordModel.UIState) -> some View {
        switch state {
        case .recording:
            HStack(spacing: 8) {
                PulseDot(diameter: 6)
                Text("Recording").uiLabel(10, color: AppColor.accentOnLight)
            }
        case .paused:
            HStack(spacing: 8) {
                Circle().fill(AppColor.ink2).frame(width: 6, height: 6)
                Text("Paused").uiLabel(10, color: AppColor.ink2)
            }
        default:
            Text("Library →").uiLabel(10, color: AppColor.ink3)
        }
    }

    private func liveSummary(_ m: RecordModel) -> String {
        let engine = m.liveEngine.displayName
        let langs = m.liveLanguages.isEmpty ? "auto-detect" : m.liveLanguages.sorted().joined(separator: ", ")
        return "Live engine: \(engine). Language: \(langs)."
    }

    // MARK: - Timer + level

    @ViewBuilder
    private func timerStrip(_ m: RecordModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            HStack(alignment: .top) {
                BigNumber(formatElapsed(m.elapsedMs), size: 66)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.0f dB", max(-60, 20 * log10(max(0.0001, Double(m.level))))))
                        .font(AppFont.display(17, weight: .semibold))
                        .tracking(0.2)
                        .foregroundStyle(AppColor.ink)
                    Text("Level · \(m.level > 0.6 ? "hot" : "clean")")
                        .uiLabel(9, color: AppColor.ink2)
                    Text("16 kHz · mono")
                        .uiLabel(9, color: AppColor.ink3)
                }
            }
            .padding(.horizontal, AppMetric.sheetPadding)
            .padding(.vertical, AppMetric.sheetVerticalPadding)
            Hairline()
        }
    }

    // MARK: - Waveform

    @ViewBuilder
    private func waveform(_ m: RecordModel) -> some View {
        // 64-bar rolling history from WavRecorder.peakHistory. Newest bar at
        // the right gets the accent; older bars fade into a soft ink. Mirrors
        // the Android record-screen meter rhythm.
        GeometryReader { geo in
            let bars = m.meetingActive ? m.container.meetingRecorder.peakHistory
                                       : m.container.recorder.peakHistory
            let cols = bars.count
            let gap: CGFloat = 2
            let barWidth = max(2, (geo.size.width - CGFloat(cols - 1) * gap) / CGFloat(cols))
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(bars.enumerated()), id: \.offset) { idx, peak in
                    let isLast = idx == cols - 1
                    // Perceptual (dB) scaling. Linear amplitude makes anything
                    // below ~-30 dB collapse to the 2px floor (a flat dashed
                    // line); mapping -60…0 dB onto 0…1 keeps speech visible.
                    let db = 20 * log10(max(1e-4, Double(peak)))
                    let normalized = max(0, min(1, CGFloat((db + 60) / 60)))
                    let height = max(2, geo.size.height * 0.92 * normalized)
                    Rectangle()
                        .fill(isLast ? AppColor.accent : AppColor.ink.opacity(0.85))
                        .frame(width: barWidth, height: height)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 72)
        .padding(.horizontal, AppMetric.sheetPadding)
        .padding(.vertical, AppMetric.s)
    }

    @ViewBuilder
    private func waveformAxis(_ m: RecordModel) -> some View {
        HStack {
            Text("−5 s").uiLabel(9, color: AppColor.ink2)
            Spacer()
            Text("\(formatElapsed(m.elapsedMs)) ▸ now").uiLabel(9)
        }
        .padding(.horizontal, AppMetric.sheetPadding)
    }

    // MARK: - Last heard

    @ViewBuilder
    private func lastHeardCard(_ m: RecordModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last heard\(statusSuffix(m.liveWorker.status))")
                .uiLabel(10, color: AppColor.ink2)

            let last = m.liveWorker.lines.last
            Text(last?.text ?? "Live captions will appear here while recording.")
                .font(AppFont.text(22))
                .lineSpacing(4)
                .tracking(-0.2)
                .foregroundStyle(last == nil ? AppColor.ink2 : AppColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let last {
                Text("\(formatElapsed(Int64(last.startSeconds * 1000))) · live")
                    .uiLabel(9, color: AppColor.ink3)
            }
        }
    }

    private func statusSuffix(_ s: LiveTranscriber.Status) -> String {
        switch s {
        case .idle:                return ""
        case .loading:             return " · loading model"
        case .running:             return " · live"
        case .modelMissing(let b): return " · model missing (\(b))"
        case .failed(let r):       return " · failed \(r)"
        }
    }

    // MARK: - Options row

    @ViewBuilder
    private func optionsRow(_ m: RecordModel) -> some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Text("Recording options · tap a value to change")
                .uiLabel(10, color: AppColor.ink2)
            // Wraps: the row needs ~1000 pt, the pane has ~740 at the
            // minimum window.
            FlowLayout(spacing: AppMetric.l) {
                option("Auto-run", m.autoTranscribe ? "On" : "Off",
                       active: m.autoTranscribe,
                       hint: "transcribe as soon\nas you press stop") { m.autoTranscribe.toggle() }
                option("Live", m.liveEnabled ? "On" : "Off",
                       active: m.liveEnabled,
                       hint: "rough live text\nwhile you record") { m.liveEnabled.toggle() }
                option("Meeting", m.meetingMode ? "On" : "Off",
                       active: m.meetingMode,
                       hint: "also record system\naudio (calls, zoom)") { m.meetingMode.toggle() }
                option("Mic boost", RecorderSettings.shared.micSensitivity.label,
                       active: RecorderSettings.shared.micSensitivity != .auto,
                       hint: "input volume · auto\nor fixed 2–6×") { cycleMicSensitivity() }
                if m.liveEnabled {
                    option("Engine", m.liveEngine.displayName,
                           active: false,
                           hint: "engine for the\nlive preview") { cycleEngine(m) }
                    option("Lang", m.liveLanguages.isEmpty
                               ? "Auto"
                               : m.liveLanguages.sorted().joined(separator: ", "),
                           active: !m.liveLanguages.isEmpty,
                           hint: "spoken language\nfor live preview") { cycleLanguage(m) }
                }
            }
        }
    }

    /// One option pill + a permanent two-line explanation underneath — the
    /// cycling pills were unlabeled mystery buttons ("MIC AUTO") before.
    @ViewBuilder
    private func option(
        _ label: String, _ value: String, active: Bool,
        hint: String, action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TagPair(label: label, value: value, active: active, action: action)
            Text(hint)
                .uiLabel(8, color: AppColor.ink2.opacity(0.75))
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cycleMicSensitivity() {
        let opts = RecorderSettings.MicSensitivity.allCases
        let cur = RecorderSettings.shared.micSensitivity
        if let idx = opts.firstIndex(of: cur) {
            RecorderSettings.shared.micSensitivity = opts[(idx + 1) % opts.count]
        }
    }

    /// AUTO → English → Arabic → Ukrainian → Dutch → AUTO.
    private func cycleLanguage(_ m: RecordModel) {
        let opts = ["English", "Arabic", "Ukrainian", "Dutch"]
        if m.liveLanguages.isEmpty {
            m.liveLanguages = [opts[0]]
        } else if let cur = m.liveLanguages.sorted().first,
                  let i = opts.firstIndex(of: cur), i + 1 < opts.count {
            m.liveLanguages = [opts[i + 1]]
        } else {
            m.liveLanguages = []
        }
    }

    private func cycleEngine(_ m: RecordModel) {
        // supportsLive excludes the dual-engine merge and Gemma audio; cloud
        // engines only qualify when their API key is stored.
        let opts = BackendFactory.Kind.allCases.filter { kind in
            guard kind.supportsLive else { return false }
            if kind.isLocal { return true }
            switch kind {
            case .openAI: return container.apiKeys.isSet(.openAI)
            case .gemini: return container.apiKeys.isSet(.gemini)
            default:      return false
            }
        }
        if let idx = opts.firstIndex(of: m.liveEngine) {
            m.liveEngine = opts[(idx + 1) % opts.count]
        } else {
            m.liveEngine = opts.first ?? .parakeet
        }
    }

    // MARK: - Footer

    // NOTE: SwiftUI's `Button` is wrapped in `_ButtonGesture` whose action
    // dispatch hits a regression in macOS 26.5 (crash in
    // `swift_task_isMainExecutorImpl` when the action captures a
    // @MainActor @Observable model). We avoid `Button` for the record /
    // pause / stop controls and use `.onTapGesture` on plain shapes /
    // TapButton throughout.

    @ViewBuilder
    private func recordFooter(_ m: RecordModel) -> some View {
        switch m.uiState {
        case .idle, .finished:
            InverseFooter(
                "Record",
                subtitle: m.autoTranscribe ? "Auto-transcribe on stop" : "Manual run",
                action: { triggerToggleRecord(m) }
            ) {
                PulseDot()
            } right: {
                Rectangle()
                    .fill(AppColor.accent)
                    .frame(width: 28, height: 28)
                    .overlay {
                        // On an accent fill, per Lit Field's .btn-accent
                        // recipe, the mark reads in ink — not onNight.
                        Rectangle().fill(AppColor.ink).frame(width: 12, height: 12)
                    }
            }

        case .recording, .paused:
            HStack(spacing: 0) {
                Text(m.uiState == .recording ? "Pause" : "Resume")
                    .uiLabel(11)
                    .padding(.horizontal, AppMetric.l)
                    .frame(maxHeight: .infinity)
                    .background(AppColor.base)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        triggerPauseToggle(m)
                    }

                VStack(spacing: 2) {
                    Text("Stop & transcribe")
                        .font(AppFont.display(17, weight: .semibold))
                        .tracking(0.1)
                        .foregroundStyle(AppColor.onNight)
                    Text(m.autoTranscribe ? "Auto-run after stop" : "Open detail to run")
                        .uiLabel(9, color: AppColor.onNight2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppMetric.sheetVerticalPadding)
                .contentShape(Rectangle())
                .onTapGesture { triggerToggleRecord(m) }

                Rectangle().fill(AppColor.ink).frame(width: 12, height: 12)
                    .padding(.horizontal, AppMetric.l)
                    .frame(maxHeight: .infinity)
                    .background(AppColor.accent)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        triggerToggleRecord(m)
                    }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(AppColor.night, in: Rectangle())
            .litLift(.one, in: Rectangle())
        }
    }

    /// Indirection so the tap closure doesn't directly capture `m` for an
    /// async hop — moves the `Task` creation out of the gesture closure.
    private func triggerToggleRecord(_ m: RecordModel) {
        Task { @MainActor [weak m] in
            await m?.toggleRecord()
        }
    }

    private func triggerPauseToggle(_ m: RecordModel) {
        Task { @MainActor [weak m] in
            guard let m else { return }
            if case .recording = m.uiState {
                m.pause()
            } else {
                m.resume()
            }
        }
    }

    private func formatElapsed(_ ms: Int64) -> String {
        let total = max(0, ms / 1000)
        let h = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, mins, secs) }
        return String(format: "%02d:%02d", mins, secs)
    }
}
