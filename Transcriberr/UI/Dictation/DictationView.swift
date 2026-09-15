import AppKit
import AVFoundation
import SwiftUI

/// In-app dictation pane: a scratch editor that the hotkey (or the footer
/// button) fills in, plus permission status and the session options.
/// System-wide dictation into other apps needs no window at all — this
/// screen is where you set it up and where text lands when nothing else
/// has focus.
struct DictationView: View {
    @Environment(AppContainer.self) private var container
    @State private var showSetup = false
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        let controller = container.dictation
        @Bindable var editor = controller
        Sheet {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    BrandStrip { badge(controller) }
                        .padding(.horizontal, AppMetric.sheetPadding)
                        .padding(.top, AppMetric.sheetVerticalPadding)

                    Spacer().frame(height: AppMetric.sheetVerticalPadding)
                    InkRule()
                    Spacer().frame(height: AppMetric.l)

                    SectionIndex(3, "Dictate", summary: summary(controller))
                        .padding(.horizontal, AppMetric.sheetPadding)

                    Spacer().frame(height: AppMetric.l)

                    if showSetup || !controller.settings.onboarded {
                        setupBlock(controller)
                            .padding(.horizontal, AppMetric.sheetPadding)
                        Spacer().frame(height: AppMetric.l)
                    }

                    optionsRow(controller)
                        .padding(.horizontal, AppMetric.sheetPadding)

                    Spacer().frame(height: AppMetric.m)
                    HairlineSoft()
                    Spacer().frame(height: AppMetric.m)

                    permissionStrip(controller)
                        .padding(.horizontal, AppMetric.sheetPadding)

                    Spacer().frame(height: AppMetric.m)
                    meterStrip(controller)

                    Spacer().frame(height: AppMetric.m)
                    editorBlock(controller, text: $editor.paneText)
                        .padding(.horizontal, AppMetric.sheetPadding)

                    Spacer().frame(height: AppMetric.xl)
                }
            }

            if let err = controller.lastError {
                HStack {
                    Text(err).uiLabel(9, color: AppColor.statusError)
                    Spacer()
                }
                .padding(.horizontal, AppMetric.sheetPadding)
                .padding(.vertical, 6)
                .background(AppColor.baseDeep)
            }
            footer(controller)
        }
        .onAppear {
            controller.paneVisible = true
            controller.refreshTrust()
        }
        .onDisappear { controller.paneVisible = false }
    }

    // MARK: - Header

    @ViewBuilder
    private func badge(_ c: DictationController) -> some View {
        switch c.phase {
        case .listening:
            HStack(spacing: 8) {
                PulseDot(diameter: 6)
                Text(c.micOpen ? "Listening" : "Opening mic").uiLabel(10, color: AppColor.accentOnLight)
            }
        case .transcribing, .inserting:
            Text("Recognizing").uiLabel(10, color: AppColor.ink2)
        default:
            HStack(spacing: AppMetric.m) {
                TapButton { showSetup.toggle() } label: {
                    Text("Setup").uiLabel(10, color: AppColor.ink3)
                }
                Text(c.hotkeyArmed ? "Hotkey · \(c.settings.hotkey.glyph)" : "Hotkey · off")
                    .uiLabel(10, color: c.hotkeyArmed ? AppColor.ink : AppColor.ink3)
            }
        }
    }

    private func summary(_ c: DictationController) -> String {
        let s = c.settings
        let engine = s.engine.displayName
        let lang = s.languages.isEmpty ? "auto-detect" : s.languages.sorted().joined(separator: ", ")
        let how: String
        switch (s.hotkey, s.mode) {
        case (.off, _):     how = "No global hotkey — use the button below or the menu bar."
        case (_, .hold):    how = "Hold \(s.hotkey.label) in any app, speak, release."
        case (_, .toggle):  how = "Tap \(s.hotkey.label) in any app to start, tap again to stop."
        }
        return "\(how) Engine: \(engine). Language: \(lang)."
    }

    // MARK: - Setup (first run)

    @ViewBuilder
    private func setupBlock(_ c: DictationController) -> some View {
        let s = c.settings
        let micOK = micStatus == .authorized
        let allDone = micOK && c.accessibilityTrusted && c.inputMonitoringGranted
        VStack(alignment: .leading, spacing: AppMetric.s) {
            HStack {
                Text("Setup · \(allDone ? "all set" : "three permissions, once")")
                    .uiLabel(10, color: allDone ? AppColor.ink : AppColor.accentOnLight)
                Spacer()
                if allDone || s.onboarded {
                    TapButton {
                        s.onboarded = true
                        showSetup = false
                    } label: { Text(allDone ? "Done" : "Hide").uiLabel(10, color: AppColor.ink2) }
                }
            }
            setupRow(1, "Microphone", done: micOK,
                     detail: micOK ? "Granted." : "Needed to hear you. Nothing is recorded until you press the key.",
                     action: micOK ? nil : ("Allow", {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            DispatchQueue.main.async { micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
                        }
                     }))
            setupRow(2, "Accessibility", done: c.accessibilityTrusted,
                     detail: c.accessibilityTrusted ? "Granted." : "Lets the app see the hotkey in other apps and paste the text at the cursor.",
                     action: c.accessibilityTrusted ? nil : ("Grant", { c.requestAccessibility() }))
            setupRow(3, "Input monitoring", done: c.inputMonitoringGranted,
                     detail: c.inputMonitoringGranted ? "Granted." : "Lets the app receive the key press itself. Usually ticked together with Accessibility.",
                     action: c.inputMonitoringGranted ? nil : ("Grant", { c.requestInputMonitoring() }))
            setupRow(4, "Try it", done: !c.lastHotkeyEvent.isEmpty,
                     detail: c.lastHotkeyEvent.isEmpty
                        ? "Press \(s.hotkey.label) once. This line changes the moment the key is seen."
                        : "Seen: \(c.lastHotkeyEvent). \(s.mode == .hold ? "Hold it and talk." : "Tap to start, tap to stop — or hold to talk.")",
                     action: nil)
        }
        .padding(AppMetric.m)
        .overlay(Rectangle().stroke(allDone ? AppColor.hair : AppColor.accent, lineWidth: 1))
        .onAppear { micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
    }

    @ViewBuilder
    private func setupRow(
        _ n: Int, _ title: String, done: Bool, detail: String,
        action: (String, () -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: AppMetric.m) {
            Rectangle().fill(done ? AppColor.accent : AppColor.ink4).frame(width: 8, height: 8).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(n) · \(title)").uiLabel(10, color: done ? AppColor.ink : AppColor.ink2)
                Text(detail).font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            Spacer()
            if let action {
                TapButton(action: action.1) {
                    LitButtonChrome(.primary, compact: true) { Text(action.0) }
                }
            }
        }
    }

    // MARK: - Options

    @ViewBuilder
    private func optionsRow(_ c: DictationController) -> some View {
        let s = c.settings
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Text("Dictation options · tap a value to change")
                .uiLabel(10, color: AppColor.ink2)
            HStack(alignment: .top, spacing: AppMetric.l) {
                option("Hotkey", s.hotkey.glyph, active: s.hotkey != .off,
                       hint: "modifier key that\nstarts dictation") { cycleHotkey(s) }
                option("Mode", s.mode == .hold ? "Hold" : "Toggle", active: s.mode == .toggle,
                       hint: s.mode == .hold ? "hold to talk,\nrelease to insert" : "tap to start, tap to\nstop · or hold to talk") {
                    s.mode = s.mode == .hold ? .toggle : .hold
                }
                option("Mode · default", s.defaultMode == .smart ? "Smart" : s.defaultMode == .verbatim ? "Verbatim" : "Clean",
                       active: s.defaultMode == .smart,
                       hint: "apps without a rule ·\nsmart = Gemma, context-aware") { cycleMode(s) }
                option("History", s.keepHistory ? "On" : "Off", active: s.keepHistory,
                       hint: "save each passage to\nthe Dictation folder") { s.keepHistory.toggle() }
                option("Lang", s.languages.isEmpty ? "Auto" : s.languages.sorted().joined(separator: ", "),
                       active: !s.languages.isEmpty,
                       hint: "spoken language") { cycleLanguage(s) }
                option("Engine", s.engine.displayName, active: false,
                       hint: "speech engine for\nsingle passages") { cycleEngine(s) }
                option("Mic", s.voiceProcessing ? "Filtered" : "Raw", active: s.voiceProcessing,
                       hint: s.voiceProcessing ? "Apple echo/noise filter ·\n~1 s slower start" : "instant start · filter\nturns other apps down") {
                    s.voiceProcessing.toggle()
                }
                Spacer()
            }
        }
    }

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

    private func cycleMode(_ s: DictationSettings) {
        let opts = DictationSettings.FormatMode.allCases
        if let i = opts.firstIndex(of: s.defaultMode) { s.defaultMode = opts[(i + 1) % opts.count] }
    }

    private func cycleHotkey(_ s: DictationSettings) {
        let opts = DictationSettings.Hotkey.allCases
        if let i = opts.firstIndex(of: s.hotkey) { s.hotkey = opts[(i + 1) % opts.count] }
    }

    private func cycleLanguage(_ s: DictationSettings) {
        let opts = ["English", "Dutch", "Ukrainian", "German", "French", "Spanish"]
        if s.languages.isEmpty {
            s.languages = [opts[0]]
        } else if let cur = s.languages.sorted().first,
                  let i = opts.firstIndex(of: cur), i + 1 < opts.count {
            s.languages = [opts[i + 1]]
        } else {
            s.languages = []
        }
    }

    private func cycleEngine(_ s: DictationSettings) {
        let opts = BackendFactory.Kind.allCases.filter { kind in
            guard kind.supportsLive else { return false }
            if kind.isLocal { return true }
            switch kind {
            case .openAI: return container.apiKeys.isSet(.openAI)
            case .gemini: return container.apiKeys.isSet(.gemini)
            default:      return false
            }
        }
        if let i = opts.firstIndex(of: s.engine) { s.engine = opts[(i + 1) % opts.count] }
        else { s.engine = .parakeet }
    }

    // MARK: - Permissions

    @ViewBuilder
    private func permissionStrip(_ c: DictationController) -> some View {
        HStack(alignment: .center, spacing: AppMetric.l) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(c.accessibilityTrusted ? AppColor.accent : AppColor.ink4)
                        .frame(width: 8, height: 8)
                    Text("Accessibility · \(c.accessibilityTrusted ? "granted" : "not granted")")
                        .uiLabel(10, color: c.accessibilityTrusted ? AppColor.ink : AppColor.ink2)
                }
                Text(c.accessibilityTrusted
                     ? "The global hotkey works in every app and text is inserted at the cursor."
                     : "Needed for the global hotkey and for inserting text into other apps. Without it, dictation still works here and copies to the clipboard.")
                    .font(AppFont.text(12))
                    .foregroundStyle(AppColor.ink2)
                    .frame(maxWidth: 520, alignment: .leading)
                if c.accessibilityTrusted, !c.inputMonitoringGranted {
                    HStack(spacing: AppMetric.m) {
                        Text("Input monitoring · not granted — the hotkey stays deaf without it")
                            .uiLabel(9, color: AppColor.statusWarning)
                        TapButton { c.requestInputMonitoring() } label: {
                            LitButtonChrome(.accent, compact: true) { Text("Grant input monitoring") }
                        }
                    }
                }
                if c.accessibilityTrusted, c.settings.hotkey != .off {
                    Text(c.hotkeyArmed
                         ? "Hotkey \(c.settings.hotkey.glyph) · \(c.hotkeyMechanism) · last event: \(c.lastHotkeyEvent.isEmpty ? "none yet — press it" : c.lastHotkeyEvent)"
                         : "Hotkey not armed — relaunch Transcriberr")
                        .uiLabel(9, color: c.hotkeyArmed && !c.lastHotkeyEvent.isEmpty ? AppColor.ink : AppColor.ink2)
                        .lineLimit(2)
                }
                if !c.accessibilityTrusted, DictationController.isAdHocSigned {
                    Text("Already ticked in System Settings? The entry belongs to an earlier build whose signature no longer matches: remove Transcriberr from the Accessibility list with −, then add /Applications/Transcriberr.app again. Builds from 3.1.1 on keep the grant across updates. The strip updates by itself once it's granted.")
                        .font(AppFont.text(11))
                        .foregroundStyle(AppColor.statusWarning)
                        .frame(maxWidth: 520, alignment: .leading)
                }
            }
            Spacer()
            if !c.accessibilityTrusted {
                HStack(spacing: AppMetric.s) {
                    TapButton {
                        c.openAccessibilitySettings()
                    } label: {
                        LitButtonChrome(.secondary) { Text("Open Settings") }
                    }
                    TapButton {
                        c.requestAccessibility()
                    } label: {
                        LitButtonChrome(.primary) { Text("Grant access") }
                    }
                }
            }
        }
    }

    // MARK: - Meter

    @ViewBuilder
    private func meterStrip(_ c: DictationController) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            HStack(alignment: .center, spacing: AppMetric.l) {
                let t = Int(c.capture.elapsedSeconds)
                BigNumber(String(format: "%d:%02d", t / 60, t % 60), size: 42)
                    .opacity(c.phase == .listening ? 1 : 0.4)
                GeometryReader { geo in
                    let bars = c.capture.peakHistory
                    let gap: CGFloat = 2
                    let w = max(2, (geo.size.width - CGFloat(bars.count - 1) * gap) / CGFloat(bars.count))
                    HStack(alignment: .center, spacing: gap) {
                        ForEach(Array(bars.enumerated()), id: \.offset) { idx, peak in
                            let db = 20 * log10(max(1e-4, Double(peak)))
                            let n = max(0, min(1, CGFloat((db + 60) / 60)))
                            Rectangle()
                                .fill(idx == bars.count - 1 ? AppColor.accent : AppColor.ink.opacity(0.85))
                                .frame(width: w, height: max(2, geo.size.height * 0.9 * n))
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 40)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(phaseLabel(c)).uiLabel(9, color: c.phase == .listening ? AppColor.accentOnLight : AppColor.ink2)
                    Text("\(c.sessionCount) passages · session").uiLabel(9, color: AppColor.ink3)
                }
            }
            .padding(.horizontal, AppMetric.sheetPadding)
            .padding(.vertical, AppMetric.m)
            Hairline()
        }
    }

    private func phaseLabel(_ c: DictationController) -> String {
        switch c.phase {
        case .idle:          return "Ready"
        case .listening:
            guard c.micOpen else { return "Opening mic" }
            return c.pendingPasses > 0 ? "Listening · writing…" : "Listening"
        case .transcribing:  return "Recognizing"
        case .inserting:     return "Inserting"
        case .message(let m): return m
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private func editorBlock(_ c: DictationController, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            EyebrowRow("Scratch pad · text dictated while this screen is open lands here") {
                EmptyView()
            } right: {
                HStack(spacing: AppMetric.m) {
                    LitChip(label: "Copy") { copyAll(text.wrappedValue) }
                    LitChip(label: "Save to library") { saveToLibrary(c, text.wrappedValue) }
                    LitChip(label: "Clear") { text.wrappedValue = "" }
                }
            }
            if !c.suggestedNames.isEmpty {
                HStack(spacing: AppMetric.s) {
                    Text("New names · tap to add to vocabulary").uiLabel(9, color: AppColor.ink2)
                    ForEach(c.suggestedNames.prefix(6), id: \.self) { name in
                        HStack(spacing: 4) {
                            TapButton { c.addToVocabulary(name) } label: {
                                Text("+ \(name)")
                                    .font(AppFont.display(10, weight: .semibold))
                                    .foregroundStyle(AppColor.ink)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .overlay(Rectangle().stroke(AppColor.accent, lineWidth: 1))
                            }
                            TapButton { c.dismissSuggestion(name) } label: {
                                Text("×").uiLabel(10, color: AppColor.ink3)
                            }
                        }
                    }
                    Spacer()
                }
            }
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(c.phase == .listening && !c.previewText.isEmpty
                         ? c.previewText + " …"
                         : c.settings.hotkey == .off
                         ? "Press Dictate below and start talking."
                         : "Hold \(c.settings.hotkey.label) and start talking — or press Dictate below.")
                        .font(AppFont.text(20))
                        .foregroundStyle(AppColor.ink2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .font(AppFont.text(15))
                    .lineSpacing(4)
                    .foregroundStyle(AppColor.ink)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 240)
            }
            .background(AppColor.baseDeep)
            .overlay(Rectangle().stroke(AppColor.hair, lineWidth: 1))
        }
    }

    private func copyAll(_ text: String) {
        guard !text.isEmpty else { return }
        TextInserter.copyOnly(text)
    }

    private func saveToLibrary(_ c: DictationController, _ text: String) {
        c.saveScratchPad()
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(_ c: DictationController) -> some View {
        switch c.phase {
        case .listening:
            InverseFooter("Stop & insert", subtitle: c.settings.mode == .toggle ? "Flushes on pauses · tap to finish" : "Release the key or tap here",
                          action: { c.finish() }) {
                PulseDot()
            } right: {
                TapButton { c.cancel() } label: {
                    Text("Cancel").uiLabel(10, color: AppColor.onNight.opacity(0.7))
                        .padding(.horizontal, AppMetric.m)
                        .padding(.vertical, 8)
                        .overlay(Rectangle().stroke(AppColor.onNight.opacity(0.4), lineWidth: 1))
                }
            }
        case .transcribing, .inserting:
            InverseFooter("Recognizing…", subtitle: c.activeMode == .smart ? "Parakeet → Gemma formatting" : "Parakeet on the Neural Engine", left: {
                ProgressView().controlSize(.small).tint(AppColor.onNight)
            })
        default:
            InverseFooter("Dictate", subtitle: c.hotkeyArmed
                            ? "or hold \(c.settings.hotkey.glyph) in any app"
                            : (c.settings.hotkey == .off ? "Global hotkey off" : "Grant Accessibility for the global hotkey"),
                          action: { c.begin(target: .pane) }) {
                PulseDot()
            } right: {
                Rectangle()
                    .fill(AppColor.accent)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13, weight: .semibold))
                            // On an accent fill, per Lit Field's .btn-accent
                            // recipe, the mark reads in ink — not onNight.
                            .foregroundStyle(AppColor.ink)
                    }
            }
        }
    }
}
