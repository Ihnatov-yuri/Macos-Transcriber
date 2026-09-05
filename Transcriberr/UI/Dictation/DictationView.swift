import AppKit
import SwiftUI

/// In-app dictation pane: a scratch editor that the hotkey (or the footer
/// button) fills in, plus permission status and the session options.
/// System-wide dictation into other apps needs no window at all — this
/// screen is where you set it up and where text lands when nothing else
/// has focus.
struct DictationView: View {
    @Environment(AppContainer.self) private var container

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

                    SectionIndex(3, "DICTATE", summary: summary(controller))
                        .padding(.horizontal, AppMetric.sheetPadding)

                    Spacer().frame(height: AppMetric.l)

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
                    Text(err.uppercased()).monoLabel(9, color: AppColor.accent)
                    Spacer()
                }
                .padding(.horizontal, AppMetric.sheetPadding)
                .padding(.vertical, 6)
                .background(AppColor.paperEdge)
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
                Text("LISTENING").monoLabel(10, color: AppColor.accent)
            }
        case .transcribing, .inserting:
            Text("RECOGNIZING").monoLabel(10, color: AppColor.inkSoft)
        default:
            Text(c.hotkeyArmed ? "HOTKEY · \(c.settings.hotkey.glyph)" : "HOTKEY · OFF")
                .monoLabel(10, color: c.hotkeyArmed ? AppColor.ink : AppColor.inkMuted)
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

    // MARK: - Options

    @ViewBuilder
    private func optionsRow(_ c: DictationController) -> some View {
        let s = c.settings
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Text("DICTATION OPTIONS · TAP A VALUE TO CHANGE")
                .monoLabel(10, color: AppColor.inkSoft)
            HStack(alignment: .top, spacing: AppMetric.l) {
                option("HOTKEY", s.hotkey.glyph, active: s.hotkey != .off,
                       hint: "modifier key that\nstarts dictation") { cycleHotkey(s) }
                option("MODE", s.mode == .hold ? "HOLD" : "TOGGLE", active: s.mode == .toggle,
                       hint: s.mode == .hold ? "hold to talk,\nrelease to insert" : "tap to start, tap\nto stop · flushes on pauses") {
                    s.mode = s.mode == .hold ? .toggle : .hold
                }
                option("MODE·DEFAULT", s.defaultMode == .smart ? "SMART" : s.defaultMode == .verbatim ? "VERBATIM" : "CLEAN",
                       active: s.defaultMode == .smart,
                       hint: "apps without a rule ·\nsmart = Gemma, context-aware") { cycleMode(s) }
                option("HISTORY", s.keepHistory ? "ON" : "OFF", active: s.keepHistory,
                       hint: "save each passage to\nthe Dictation folder") { s.keepHistory.toggle() }
                option("LANG", s.languages.isEmpty ? "AUTO" : s.languages.sorted().joined(separator: ",").uppercased(),
                       active: !s.languages.isEmpty,
                       hint: "spoken language") { cycleLanguage(s) }
                option("ENGINE", s.engine.displayName.uppercased(), active: false,
                       hint: "speech engine for\nsingle passages") { cycleEngine(s) }
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
                .monoLabel(8, color: AppColor.inkSoft.opacity(0.75))
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
                        .fill(c.accessibilityTrusted ? AppColor.accent : AppColor.inkFaint)
                        .frame(width: 8, height: 8)
                    Text("ACCESSIBILITY · \(c.accessibilityTrusted ? "GRANTED" : "NOT GRANTED")")
                        .monoLabel(10, color: c.accessibilityTrusted ? AppColor.ink : AppColor.inkSoft)
                }
                Text(c.accessibilityTrusted
                     ? "The global hotkey works in every app and text is inserted at the cursor."
                     : "Needed for the global hotkey and for inserting text into other apps. Without it, dictation still works here and copies to the clipboard.")
                    .font(AppFont.inter(12))
                    .foregroundStyle(AppColor.inkSoft)
                    .frame(maxWidth: 520, alignment: .leading)
                if !c.accessibilityTrusted, DictationController.isAdHocSigned {
                    Text("Already ticked in System Settings? This build is ad-hoc signed, so an entry from an earlier Transcriberr doesn't count: remove Transcriberr from the Accessibility list with −, then add /Applications/Transcriberr.app again. The strip updates by itself once it's granted.")
                        .font(AppFont.inter(11))
                        .foregroundStyle(AppColor.accent)
                        .frame(maxWidth: 520, alignment: .leading)
                }
            }
            Spacer()
            if !c.accessibilityTrusted {
                HStack(spacing: AppMetric.s) {
                    TapButton {
                        c.openAccessibilitySettings()
                    } label: {
                        Text("OPEN SETTINGS")
                            .monoLabel(10, color: AppColor.ink)
                            .padding(.horizontal, AppMetric.m)
                            .padding(.vertical, 8)
                            .overlay(Rectangle().stroke(AppColor.ink, lineWidth: 1))
                    }
                    TapButton {
                        c.requestAccessibility()
                    } label: {
                        Text("GRANT ACCESS")
                            .monoLabel(10, color: AppColor.paper)
                            .padding(.horizontal, AppMetric.m)
                            .padding(.vertical, 8)
                            .background(AppColor.ink)
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
                    Text(phaseLabel(c)).monoLabel(9, color: c.phase == .listening ? AppColor.accent : AppColor.inkSoft)
                    Text("\(c.sessionCount) PASSAGES · SESSION").monoLabel(9, color: AppColor.inkMuted)
                }
            }
            .padding(.horizontal, AppMetric.sheetPadding)
            .padding(.vertical, AppMetric.m)
            Hairline()
        }
    }

    private func phaseLabel(_ c: DictationController) -> String {
        switch c.phase {
        case .idle:          return "READY"
        case .listening:     return c.pendingPasses > 0 ? "LISTENING · WRITING…" : "LISTENING"
        case .transcribing:  return "RECOGNIZING"
        case .inserting:     return "INSERTING"
        case .message(let m): return m.uppercased()
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private func editorBlock(_ c: DictationController, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            EyebrowRow("SCRATCH PAD · TEXT DICTATED WHILE THIS SCREEN IS OPEN LANDS HERE") {
                EmptyView()
            } right: {
                HStack(spacing: AppMetric.m) {
                    EditorialChip(label: "COPY") { copyAll(text.wrappedValue) }
                    EditorialChip(label: "SAVE TO LIBRARY") { saveToLibrary(c, text.wrappedValue) }
                    EditorialChip(label: "CLEAR") { text.wrappedValue = "" }
                }
            }
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(c.settings.hotkey == .off
                         ? "Press DICTATE below and start talking."
                         : "Hold \(c.settings.hotkey.label) and start talking — or press DICTATE below.")
                        .font(AppFont.fraunces(20, italic: true))
                        .foregroundStyle(AppColor.inkSoft)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .font(AppFont.inter(15))
                    .lineSpacing(4)
                    .foregroundStyle(AppColor.ink)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 240)
            }
            .background(AppColor.paperEdge)
            .overlay(Rectangle().stroke(AppColor.hairline, lineWidth: 1))
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
            InverseFooter("Stop & insert", subtitle: c.settings.mode == .toggle ? "FLUSHES ON PAUSES · TAP TO FINISH" : "RELEASE THE KEY OR TAP HERE",
                          action: { c.finish() }) {
                PulseDot()
            } right: {
                TapButton { c.cancel() } label: {
                    Text("CANCEL").monoLabel(10, color: AppColor.paper.opacity(0.7))
                        .padding(.horizontal, AppMetric.m)
                        .padding(.vertical, 8)
                        .overlay(Rectangle().stroke(AppColor.paper.opacity(0.4), lineWidth: 1))
                }
            }
        case .transcribing, .inserting:
            InverseFooter("Recognizing…", subtitle: c.activeMode == .smart ? "PARAKEET → GEMMA FORMATTING" : "PARAKEET ON THE NEURAL ENGINE", left: {
                ProgressView().controlSize(.small).tint(AppColor.paper)
            })
        default:
            InverseFooter("Dictate", subtitle: c.hotkeyArmed
                            ? "OR HOLD \(c.settings.hotkey.glyph) IN ANY APP"
                            : (c.settings.hotkey == .off ? "GLOBAL HOTKEY OFF" : "GRANT ACCESSIBILITY FOR THE GLOBAL HOTKEY"),
                          action: { c.begin(target: .pane) }) {
                PulseDot()
            } right: {
                Rectangle()
                    .fill(AppColor.accent)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppColor.paper)
                    }
            }
        }
    }
}
