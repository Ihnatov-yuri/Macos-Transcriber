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

                    SectionIndex(4, String(localized: "Dictate", comment: "Dictation screen section title"), summary: summary(controller))
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
                (c.micOpen ? Text("Listening") : Text("Opening mic")).uiLabel(10, color: AppColor.accentOnLight)
            }
        case .transcribing, .inserting:
            Text("Recognizing").uiLabel(10, color: AppColor.ink2)
        default:
            HStack(spacing: AppMetric.m) {
                TapButton { showSetup.toggle() } label: {
                    Text("Setup").uiLabel(10, color: AppColor.ink3)
                }
                (c.hotkeyArmed ? Text("Hotkey · \(c.settings.hotkey.glyph)") : Text("Hotkey · off"))
                    .uiLabel(10, color: c.hotkeyArmed ? AppColor.ink : AppColor.ink3)
            }
        }
    }

    private func summary(_ c: DictationController) -> String {
        let s = c.settings
        let engine = s.engine.displayName
        let lang = s.languages.isEmpty
            ? String(localized: "auto-detect", comment: "Dictation summary: spoken language not set")
            : s.languages.sorted().map(SettingsLanguageNames.name).joined(separator: ", ")
        let how: String
        let key = s.hotkey.label
        switch (s.hotkey, s.mode) {
        case (.off, _):     how = String(localized: "No global hotkey — use the button below or the menu bar.")
        case (_, .hold):    how = String(localized: "Hold \(key) in any app, speak, release.")
        case (_, .toggle):  how = String(localized: "Tap \(key) in any app to start, tap again to stop.")
        }
        return String(localized: "\(how) Engine: \(engine). Language: \(lang).",
                      comment: "Dictation summary; the first argument is a whole sentence on how to use the hotkey")
    }

    // MARK: - Setup (first run)

    @ViewBuilder
    private func setupBlock(_ c: DictationController) -> some View {
        let s = c.settings
        let micOK = micStatus == .authorized
        let allDone = micOK && c.accessibilityTrusted && c.inputMonitoringGranted
        VStack(alignment: .leading, spacing: AppMetric.s) {
            HStack {
                (allDone ? Text("Setup · all set") : Text("Setup · three permissions, once"))
                    .uiLabel(10, color: allDone ? AppColor.ink : AppColor.accentOnLight)
                Spacer()
                if allDone || s.onboarded {
                    TapButton {
                        s.onboarded = true
                        showSetup = false
                    } label: { (allDone ? Text("Done") : Text("Hide")).uiLabel(10, color: AppColor.ink2) }
                }
            }
            setupRow(1, String(localized: "Microphone"), done: micOK,
                     detail: micOK ? String(localized: "Granted.")
                        : String(localized: "Needed to hear you. Nothing is recorded until you press the key."),
                     action: micOK ? nil : (String(localized: "Allow", comment: "Dictation setup: allow microphone access"), {
                        // The completion form calls back on a private queue; a
                        // main-actor closure there traps in Swift 6.
                        // `_ =`: a bare `Task {}` as the closure's only expression
                        // made it return a Task where `() -> Void` is expected,
                        // which crashed the Swift 6.3 compiler.
                        _ = Task {
                            _ = await AVCaptureDevice.requestAccess(for: .audio)
                            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                        }
                     }))
            setupRow(2, String(localized: "Accessibility", comment: "macOS privacy permission name"), done: c.accessibilityTrusted,
                     detail: c.accessibilityTrusted ? String(localized: "Granted.")
                        : String(localized: "Lets the app see the hotkey in other apps and paste the text at the cursor."),
                     action: c.accessibilityTrusted ? nil
                        : (String(localized: "Grant", comment: "Dictation setup: grant a permission"), { c.requestAccessibility() }))
            setupRow(3, String(localized: "Input monitoring", comment: "macOS privacy permission name"), done: c.inputMonitoringGranted,
                     detail: c.inputMonitoringGranted ? String(localized: "Granted.")
                        : String(localized: "Lets the app receive the key press itself. Usually ticked together with Accessibility."),
                     action: c.inputMonitoringGranted ? nil
                        : (String(localized: "Grant", comment: "Dictation setup: grant a permission"), { c.requestInputMonitoring() }))
            setupRow(4, String(localized: "Try it"), done: !c.lastHotkeyEvent.isEmpty,
                     detail: tryItDetail(c),
                     action: nil)
        }
        .padding(AppMetric.m)
        .overlay(Rectangle().stroke(allDone ? AppColor.hair : AppColor.accent, lineWidth: 1))
        .onAppear { micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
    }

    private func tryItDetail(_ c: DictationController) -> String {
        let seen = c.lastHotkeyEvent
        if seen.isEmpty {
            return String(localized: "Press \(c.settings.hotkey.label) once. This line changes the moment the key is seen.")
        }
        return c.settings.mode == .hold
            ? String(localized: "Seen: \(seen). Hold it and talk.")
            : String(localized: "Seen: \(seen). Tap to start, tap to stop — or hold to talk.")
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
            // Wraps: the row needs ~1000 pt, the pane has ~740 at the
            // minimum window.
            FlowLayout(spacing: AppMetric.l) {
                option(String(localized: "Hotkey", comment: "Dictation option: the key that starts dictation"),
                       s.hotkey.glyph, active: s.hotkey != .off,
                       hint: String(localized: "modifier key that\nstarts dictation")) { cycleHotkey(s) }
                option(String(localized: "Mode", comment: "Dictation option: hold or toggle the hotkey"),
                       s.mode == .hold
                           ? String(localized: "Hold", comment: "Dictation mode value: hold the key while speaking")
                           : String(localized: "Toggle", comment: "Dictation mode value: tap to start, tap to stop"),
                       active: s.mode == .toggle,
                       hint: s.mode == .hold ? String(localized: "hold to talk,\nrelease to insert")
                           : String(localized: "tap to start, tap to\nstop · or hold to talk")) {
                    s.mode = s.mode == .hold ? .toggle : .hold
                }
                option(String(localized: "Mode · default", comment: "Dictation option: default text formatting"),
                       defaultModeValue(s.defaultMode),
                       active: s.defaultMode == .smart,
                       hint: String(localized: "apps without a rule ·\nsmart = text model, context-aware")) { cycleMode(s) }
                option(String(localized: "Write as", comment: "Dictation option: rewrite the whole dictation as a message, letter or bullets"),
                       s.style.label, active: s.style != .off,
                       hint: s.style.hint) { cycleStyle(s) }
                option(String(localized: "History", comment: "Dictation option: keep dictated passages in the Library"),
                       s.keepHistory ? String(localized: "On", comment: "Option value: switched on")
                           : String(localized: "Off", comment: "Option value: switched off"),
                       active: s.keepHistory,
                       hint: String(localized: "save each passage to\nthe Dictation folder")) { s.keepHistory.toggle() }
                option(String(localized: "Lang", comment: "Dictation option, short for spoken language"),
                       s.languages.isEmpty
                           ? String(localized: "Auto", comment: "Option value: language detected automatically")
                           : s.languages.sorted().map(SettingsLanguageNames.name).joined(separator: ", "),
                       active: !s.languages.isEmpty,
                       hint: String(localized: "spoken language")) { cycleLanguage(s) }
                option(String(localized: "Engine", comment: "Dictation option: speech engine"),
                       s.engine.displayName, active: false,
                       hint: String(localized: "speech engine for\nsingle passages")) { cycleEngine(s) }
                option(String(localized: "Mic", comment: "Dictation option: microphone processing"),
                       s.voiceProcessing
                           ? String(localized: "Filtered", comment: "Dictation mic value: Apple echo and noise filter on")
                           : String(localized: "Raw", comment: "Dictation mic value: no filter"),
                       active: s.voiceProcessing,
                       hint: s.voiceProcessing ? String(localized: "Apple echo/noise filter ·\n~1 s slower start")
                           : String(localized: "instant start · filter\nturns other apps down")) {
                    s.voiceProcessing.toggle()
                }
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

    private func defaultModeValue(_ mode: DictationSettings.FormatMode) -> String {
        switch mode {
        case .smart:    return String(localized: "Smart", comment: "Dictation formatting: the text model formats, context-aware")
        case .verbatim: return String(localized: "Verbatim", comment: "Dictation formatting: exactly as spoken")
        case .clean:    return String(localized: "Clean", comment: "Dictation formatting: text with fillers removed")
        }
    }

    private func cycleMode(_ s: DictationSettings) {
        let opts = DictationSettings.FormatMode.allCases
        if let i = opts.firstIndex(of: s.defaultMode) { s.defaultMode = opts[(i + 1) % opts.count] }
    }

    private func cycleStyle(_ s: DictationSettings) {
        let opts = DictationStyle.allCases
        if let i = opts.firstIndex(of: s.style) { s.style = opts[(i + 1) % opts.count] }
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
                    (c.accessibilityTrusted ? Text("Accessibility · granted") : Text("Accessibility · not granted"))
                        .uiLabel(10, color: c.accessibilityTrusted ? AppColor.ink : AppColor.ink2)
                }
                (c.accessibilityTrusted
                     ? Text("The global hotkey works in every app and text is inserted at the cursor.")
                     : Text("Needed for the global hotkey and for inserting text into other apps. Without it, dictation still works here and copies to the clipboard."))
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
                    hotkeyStatus(c)
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

    private func hotkeyStatus(_ c: DictationController) -> Text {
        guard c.hotkeyArmed else { return Text("Hotkey not armed — relaunch Transcriberr") }
        let glyph = c.settings.hotkey.glyph
        let mechanism = c.hotkeyMechanism
        let event = c.lastHotkeyEvent
        return event.isEmpty
            ? Text("Hotkey \(glyph) · \(mechanism) · last event: none yet — press it")
            : Text("Hotkey \(glyph) · \(mechanism) · last event: \(event)")
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
        case .idle:          return String(localized: "Ready", comment: "Dictation state")
        case .listening:
            guard c.micOpen else { return String(localized: "Opening mic") }
            return c.pendingPasses > 0 ? String(localized: "Listening · writing…") : String(localized: "Listening")
        case .transcribing:  return String(localized: "Recognizing")
        case .inserting:     return String(localized: "Inserting")
        case .message(let m): return m
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private func editorBlock(_ c: DictationController, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            EyebrowRow(String(localized: "Scratch pad · text dictated while this screen is open lands here")) {
                EmptyView()
            } right: {
                HStack(spacing: AppMetric.m) {
                    Group {
                        LitChip(label: String(localized: "Copy")) { copyAll(text.wrappedValue) }
                        LitChip(label: String(localized: "Save to library")) { saveToLibrary(c, text.wrappedValue) }
                        LitChip(label: String(localized: "Clear", comment: "Empty the scratch pad")) { text.wrappedValue = "" }
                    }
                    .disabled(text.wrappedValue.isEmpty)
                    .opacity(text.wrappedValue.isEmpty ? 0.45 : 1)
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
            rewriteRow(c, text: text.wrappedValue)
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder(c))
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

    /// "Rewrite as" — the whole pad becomes a message, a letter or a list.
    @ViewBuilder
    private func rewriteRow(_ c: DictationController, text: String) -> some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let busy = c.padRewriting != nil
        HStack(spacing: AppMetric.m) {
            Text("Rewrite the pad as").uiLabel(9, color: AppColor.ink2)
            ForEach(DictationStyle.allCases.filter { $0 != .off }, id: \.rawValue) { style in
                LitChip(label: style.label, active: c.padRewriting == style) {
                    Task { await c.rewritePad(as: style) }
                }
                .disabled(empty || busy)
                .opacity(empty || (busy && c.padRewriting != style) ? 0.45 : 1)
            }
            if c.canUndoPadRewrite, !busy {
                LitChip(label: String(localized: "Undo rewrite")) { c.undoPadRewrite() }
            }
            if let style = c.padRewriting {
                ProgressView().controlSize(.small)
                Text(style.workingLabel).uiLabel(9, color: AppColor.accentOnLight)
            } else if let notice = c.padNotice {
                Text(notice).uiLabel(9, color: AppColor.statusWarning)
            }
            Spacer()
        }
    }

    /// The live preview while listening, otherwise how to start.
    private func placeholder(_ c: DictationController) -> String {
        if c.phase == .listening && !c.previewText.isEmpty { return c.previewText + " …" }
        if c.settings.hotkey == .off { return String(localized: "Press Dictate below and start talking.") }
        let key = c.settings.hotkey.label
        return c.settings.mode == .hold
            ? String(localized: "Hold \(key) and start talking — or press Dictate below.")
            : String(localized: "Tap \(key) and start talking — or press Dictate below.")
    }

    private func copyAll(_ text: String) {
        guard !text.isEmpty else { return }
        TextInserter.copyOnly(text)
    }

    private func saveToLibrary(_ c: DictationController, _ text: String) {
        c.saveScratchPad()
    }

    // MARK: - Footer

    private func footerSubtitle(_ c: DictationController) -> String {
        guard c.hotkeyArmed else {
            return c.settings.hotkey == .off ? String(localized: "Global hotkey off")
                : String(localized: "Grant Accessibility for the global hotkey")
        }
        let glyph = c.settings.hotkey.glyph
        return c.settings.mode == .hold
            ? String(localized: "or hold \(glyph) in any app")
            : String(localized: "or tap \(glyph) in any app")
    }

    @ViewBuilder
    private func footer(_ c: DictationController) -> some View {
        switch c.phase {
        case .listening:
            InverseFooter(String(localized: "Stop & insert"),
                          subtitle: c.settings.mode == .toggle ? String(localized: "Flushes on pauses · tap to finish")
                              : String(localized: "Release the key or tap here"),
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
            InverseFooter(String(localized: "Recognizing…"),
                          subtitle: c.restyling?.workingLabel
                              ?? (c.activeStyle != .off ? c.activeStyle.workingLabel
                              : c.activeMode == .smart ? String(localized: "Speech, then the text model formats")
                              : String(localized: "On the Neural Engine")), left: {
                ProgressView().controlSize(.small).tint(AppColor.onNight)
            })
        default:
            InverseFooter(String(localized: "Dictate", comment: "Dictation footer button: start dictating"),
                          subtitle: footerSubtitle(c),
                          action: { c.begin(target: .pane) }) {
                PulseDot(animated: false)
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
